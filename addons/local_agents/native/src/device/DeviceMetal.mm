#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "la/Device.hpp"
#include "la/KernelBlob.hpp"

#include <mach/mach_time.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <unordered_map>

namespace la {
namespace {

// Bytes per member of a Tier-2 argument buffer whose members are all device pointers. lakc holds every
// kernel's argument buffer to dense ascending ids, so member `slot` sits at `slot * 8`.
constexpr size_t kArgStride = 8;
// Labelled regions one list may carry. Each takes two GPU counter samples.
constexpr uint32_t kMaxMarks = 64;

[[noreturn]] void fatal(const char *what, const std::string &detail) {
	std::fprintf(stderr, "la::Device: %s: %s\n", what, detail.c_str());
	std::abort();
}

struct MetalBuffer {
	id<MTLBuffer> buf = nil;
	size_t bytes = 0;
	Usage usage = Usage::Storage;
};

struct MetalKernel {
	BlobKernel meta;
	id<MTLComputePipelineState> pso = nil;
};

struct MetalSet {
	id<MTLBuffer> arg = nil;
	std::vector<id<MTLResource>> used;
	uint32_t kernel = 0;
};

struct MetalList {
	id<MTLCommandBuffer> cb = nil;
	id<MTLComputeCommandEncoder> enc = nil;
	id<MTLCounterSampleBuffer> counters = nil;
	std::vector<std::string> labels;
	uint32_t region = 0;
	uint32_t local_x = 1;
	uint32_t push_slot = 1;
};

class DeviceMetal final : public Device {
public:
	bool init(int index, std::string &err);

	const char *name() const override { return name_.c_str(); }
	Backend backend() const override { return Backend::Metal; }
	bool supports_timestamps() const override { return ns_per_tick_ > 0.0; }

	DeviceResources retained_resources() const override {
		return {buffers_.size(), sets_.size(), lists_.size(), fences_.size()};
	}

	bool load_kernels(const std::string &path, std::string &err) override;
	size_t kernel_count() const override { return kernels_.size(); }
	uint64_t kernel_blob_hash() const override { return blob_hash_; }
	bool has_kernel(std::string_view n) const override;
	KernelId kernel(std::string_view n) override;
	bool build(KernelId k, std::string &err) override;
	const char *kernel_name(KernelId k) const override { return at(k).meta.name.c_str(); }
	uint32_t push_size(KernelId k) const override { return at(k).meta.push_size; }
	bool declares(KernelId k, uint32_t binding) const override;
	uint32_t local_size_x(KernelId k) const override { return at(k).meta.local[0]; }
	std::vector<uint32_t> bindings_of(KernelId k) const override;

	BufferId create_buffer(size_t bytes, Usage usage, const void *init) override;
	void destroy_buffer(BufferId b) override;
	void upload(BufferId b, size_t off, const void *src, size_t bytes) override;
	void download(BufferId b, size_t off, void *dst, size_t bytes) override;
	void clear(BufferId b, size_t off, size_t bytes) override;
	void copy(BufferId s, size_t soff, BufferId d, size_t doff, size_t bytes) override;

	SetId make_set(KernelId k, std::span<const std::pair<uint32_t, BufferId>> bound) override;
	void destroy_set(SetId s) override;

	List begin() override;
	void bind(List &l, KernelId k, SetId s) override;
	void push(List &l, const void *data, size_t bytes) override;
	void dispatch(List &l, uint32_t groups_x) override;
	void dispatch_indirect(List &l, BufferId args, size_t off) override;
	void barrier(List &l) override;
	void mark(List &l, const char *label) override;
	Fence submit(List &&l) override;
	void wait(Fence f) override;
	bool poll(Fence f) override;
	std::span<const TimestampSample> timestamps() const override { return samples_; }

private:
	uint64_t blob_hash_ = 0;
	const MetalKernel &at(KernelId k) const;
	MetalKernel &at_mut(KernelId k);
	MetalBuffer &buffer_at(BufferId b);
	MetalList &list_at(List &l);
	void open_region(MetalList &ml);
	void close_region(MetalList &ml, const char *label);
	void require_idle(const char *op);
	void calibrate();

	id<MTLDevice> dev_ = nil;
	id<MTLCommandQueue> queue_ = nil;
	std::string name_;
	double ns_per_tick_ = 0.0;

	std::unordered_map<uint32_t, MetalBuffer> buffers_;
	uint32_t next_buffer_ = 1, next_set_ = 1, next_list_ = 1;
	uint64_t next_fence_ = 1;
	std::vector<MetalKernel> kernels_;
	std::unordered_map<std::string, uint32_t> by_name_;
	std::unordered_map<uint32_t, MetalSet> sets_;
	std::unordered_map<uint32_t, MetalList> lists_;
	std::unordered_map<uint64_t, MetalList> fences_;
	std::vector<TimestampSample> samples_;
};

bool DeviceMetal::init(int index, std::string &err) {
	NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
	if (all.count == 0) {
		err = "this machine reports no Metal device";
		return false;
	}
	if (index < 0 || static_cast<NSUInteger>(index) >= all.count) {
		err = "no Metal device at index " + std::to_string(index) + "; this machine has "
				+ std::to_string(all.count);
		return false;
	}
	dev_ = all[static_cast<NSUInteger>(index)];
	queue_ = [dev_ newCommandQueue];
	if (queue_ == nil) {
		err = "the Metal device gave out no command queue";
		return false;
	}
	name_ = dev_.name.UTF8String;
	if (dev_.argumentBuffersSupport != MTLArgumentBuffersTier2) {
		err = name_ + " supports only tier-1 argument buffers; the flux kernel binds far past Metal's "
				"31 buffer slots and needs GPU addresses written directly";
		return false;
	}
	calibrate();
	return true;
}

// GPU counter ticks to nanoseconds, read off the device's own correlated clock pair rather than assumed.
// A GPU clock that does not move over the window leaves ns_per_tick_ at zero, and supports_timestamps()
// then says so instead of reporting a made-up duration.
void DeviceMetal::calibrate() {
	if (![dev_ supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) { return; }
	MTLTimestamp cpu0 = 0, gpu0 = 0, cpu1 = 0, gpu1 = 0;
	[dev_ sampleTimestamps:&cpu0 gpuTimestamp:&gpu0];
	usleep(2000);
	[dev_ sampleTimestamps:&cpu1 gpuTimestamp:&gpu1];
	if (gpu1 <= gpu0 || cpu1 <= cpu0) { return; }
	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	const double cpu_ns = double(cpu1 - cpu0) * double(tb.numer) / double(tb.denom);
	ns_per_tick_ = cpu_ns / double(gpu1 - gpu0);
}

bool DeviceMetal::load_kernels(const std::string &path, std::string &err) {
	KernelBlob blob;
	if (!KernelBlob::read(path, blob, err)) { return false; }
	kernels_.clear();
	by_name_.clear();
	for (BlobKernel &k : blob.kernels) {
		by_name_[k.name] = static_cast<uint32_t>(kernels_.size());
		MetalKernel mk;
		mk.meta = std::move(k);
		kernels_.push_back(std::move(mk));
	}
	blob_hash_ = blob.content_hash;
	return true;
}

bool DeviceMetal::has_kernel(std::string_view n) const {
	return by_name_.find(std::string(n)) != by_name_.end();
}

KernelId DeviceMetal::kernel(std::string_view n) {
	auto it = by_name_.find(std::string(n));
	if (it == by_name_.end()) { fatal("no such kernel in the blob", std::string(n)); }
	return KernelId{it->second + 1};
}

const MetalKernel &DeviceMetal::at(KernelId k) const {
	if (k.v == 0 || k.v > kernels_.size()) { fatal("kernel id out of range", std::to_string(k.v)); }
	return kernels_[k.v - 1];
}

MetalKernel &DeviceMetal::at_mut(KernelId k) {
	if (k.v == 0 || k.v > kernels_.size()) { fatal("kernel id out of range", std::to_string(k.v)); }
	return kernels_[k.v - 1];
}

bool DeviceMetal::build(KernelId k, std::string &err) {
	MetalKernel &mk = at_mut(k);
	if (mk.pso != nil) { return true; }
	NSError *nserr = nil;
	MTLCompileOptions *opts = [MTLCompileOptions new];
	opts.languageVersion = MTLLanguageVersion3_0;
	// SAFE MATH, NOT METAL'S DEFAULT FAST MATH. The books close because both sides of a face evaluate
	// the same expression on the same operands; a compiler free to reassociate and contract inlines the
	// two instances differently, and matter appears at every face.
	if (@available(macOS 15.0, *)) {
		opts.mathMode = MTLMathModeSafe;
	}
	NSString *src = [NSString stringWithUTF8String:mk.meta.msl.c_str()];
	id<MTLLibrary> lib = [dev_ newLibraryWithSource:src options:opts error:&nserr];
	if (lib == nil) {
		err = mk.meta.name + ": Metal refused the translated source: "
				+ (nserr != nil ? nserr.localizedDescription.UTF8String : "no message");
		return false;
	}
	id<MTLFunction> fn = [lib newFunctionWithName:[NSString stringWithUTF8String:mk.meta.entry.c_str()]];
	if (fn == nil) {
		err = mk.meta.name + ": the translated library carries no entry point '" + mk.meta.entry + "'";
		return false;
	}
	mk.pso = [dev_ newComputePipelineStateWithFunction:fn error:&nserr];
	if (mk.pso == nil) {
		err = mk.meta.name + ": no compute pipeline: "
				+ (nserr != nil ? nserr.localizedDescription.UTF8String : "no message");
		return false;
	}
	return true;
}

bool DeviceMetal::declares(KernelId k, uint32_t binding) const {
	for (const BlobBinding &b : at(k).meta.bindings) {
		if (b.binding == binding) { return true; }
	}
	return false;
}

std::vector<uint32_t> DeviceMetal::bindings_of(KernelId k) const {
	std::vector<uint32_t> out;
	for (const BlobBinding &b : at(k).meta.bindings) { out.push_back(b.binding); }
	return out;
}

BufferId DeviceMetal::create_buffer(size_t bytes, Usage usage, const void *init) {
	if (bytes == 0) { fatal("a zero-byte buffer", "nothing reads or writes it"); }
	MetalBuffer mb;
	mb.bytes = bytes;
	mb.usage = usage;
	mb.buf = init != nullptr
			? [dev_ newBufferWithBytes:init length:bytes options:MTLResourceStorageModeShared]
			: [dev_ newBufferWithLength:bytes options:MTLResourceStorageModeShared];
	if (mb.buf == nil) { fatal("the device gave out no buffer of", std::to_string(bytes) + " bytes"); }
	const BufferId id{next_buffer_++};
	buffers_.emplace(id.v, std::move(mb));
	return id;
}

MetalBuffer &DeviceMetal::buffer_at(BufferId b) {
	auto it = buffers_.find(b.v);
	if (it == buffers_.end()) { fatal("buffer id absent", std::to_string(b.v)); }
	return it->second;
}

void DeviceMetal::destroy_buffer(BufferId b) {
	require_idle("destroy_buffer");
	buffer_at(b);
	buffers_.erase(b.v);
}

// The device holds no queue of pending host copies: a host read or write while a submitted list is still
// running is a race, and a race that reports plausible numbers is worse than a stop.
void DeviceMetal::require_idle(const char *op) {
	for (auto it = fences_.begin(); it != fences_.end(); ++it) {
		id<MTLCommandBuffer> cb = it->second.cb;
		if (cb == nil) { continue; }
		if (cb.status != MTLCommandBufferStatusCompleted && cb.status != MTLCommandBufferStatusError) {
			fatal(op, "a submitted list has not been waited on");
		}
	}
}

void DeviceMetal::upload(BufferId b, size_t off, const void *src, size_t bytes) {
	require_idle("upload");
	MetalBuffer &mb = buffer_at(b);
	if (off + bytes > mb.bytes) { fatal("upload past the end of a buffer", std::to_string(b.v)); }
	std::memcpy(static_cast<uint8_t *>(mb.buf.contents) + off, src, bytes);
}

void DeviceMetal::download(BufferId b, size_t off, void *dst, size_t bytes) {
	require_idle("download");
	MetalBuffer &mb = buffer_at(b);
	if (off + bytes > mb.bytes) { fatal("download past the end of a buffer", std::to_string(b.v)); }
	std::memcpy(dst, static_cast<const uint8_t *>(mb.buf.contents) + off, bytes);
}

void DeviceMetal::clear(BufferId b, size_t off, size_t bytes) {
	require_idle("clear");
	MetalBuffer &mb = buffer_at(b);
	if (off + bytes > mb.bytes) { fatal("clear past the end of a buffer", std::to_string(b.v)); }
	std::memset(static_cast<uint8_t *>(mb.buf.contents) + off, 0, bytes);
}

void DeviceMetal::copy(BufferId s, size_t soff, BufferId d, size_t doff, size_t bytes) {
	require_idle("copy");
	MetalBuffer &ms = buffer_at(s);
	MetalBuffer &md = buffer_at(d);
	if (soff + bytes > ms.bytes || doff + bytes > md.bytes) {
		fatal("copy past the end of a buffer", std::to_string(s.v) + " -> " + std::to_string(d.v));
	}
	std::memcpy(static_cast<uint8_t *>(md.buf.contents) + doff,
			static_cast<const uint8_t *>(ms.buf.contents) + soff, bytes);
}

SetId DeviceMetal::make_set(KernelId k, std::span<const std::pair<uint32_t, BufferId>> bound) {
	const MetalKernel &mk = at(k);
	MetalSet set;
	set.kernel = k.v;
	const size_t slots = mk.meta.bindings.size();
	set.arg = [dev_ newBufferWithLength:slots * kArgStride options:MTLResourceStorageModeShared];
	set.used.reserve(slots);
	std::vector<bool> filled(slots, false);
	for (const auto &pair : bound) {
		const BlobBinding *decl = nullptr;
		for (const BlobBinding &b : mk.meta.bindings) {
			if (b.binding == pair.first) { decl = &b; break; }
		}
		if (decl == nullptr) {
			fatal("a set binds a slot the kernel does not declare",
					mk.meta.name + " binding " + std::to_string(pair.first));
		}
		if (filled[decl->slot]) {
			fatal("a set binds one slot twice",
					mk.meta.name + " binding " + std::to_string(pair.first));
		}
		MetalBuffer &mb = buffer_at(pair.second);
		uint64_t address = mb.buf.gpuAddress;
		std::memcpy(static_cast<uint8_t *>(set.arg.contents) + decl->slot * kArgStride, &address, 8);
		set.used.push_back(mb.buf);
		filled[decl->slot] = true;
	}
	for (size_t i = 0; i < slots; ++i) {
		if (!filled[i]) {
			fatal("a set leaves a declared binding empty",
					mk.meta.name + " binding " + std::to_string(mk.meta.bindings[i].binding) + " ("
							+ mk.meta.bindings[i].name + ")");
		}
	}
	const SetId id{next_set_++};
	sets_.emplace(id.v, std::move(set));
	return id;
}

void DeviceMetal::destroy_set(SetId s) {
	require_idle("destroy_set");
	if (sets_.erase(s.v) != 1) { fatal("set id absent", std::to_string(s.v)); }
}

List DeviceMetal::begin() {
	MetalList ml;
	ml.cb = [queue_ commandBuffer];
	if (supports_timestamps()) {
		MTLCounterSampleBufferDescriptor *desc = [MTLCounterSampleBufferDescriptor new];
		desc.storageMode = MTLStorageModeShared;
		desc.sampleCount = kMaxMarks * 2;
		for (id<MTLCounterSet> cs in dev_.counterSets) {
			if ([cs.name isEqualToString:MTLCommonCounterSetTimestamp]) { desc.counterSet = cs; }
		}
		NSError *err = nil;
		if (desc.counterSet != nil) {
			ml.counters = [dev_ newCounterSampleBufferWithDescriptor:desc error:&err];
		}
	}
	List l;
	l.v = next_list_++;
	lists_.emplace(l.v, std::move(ml));
	open_region(list_at(l));
	return l;
}

MetalList &DeviceMetal::list_at(List &l) {
	auto it = lists_.find(l.v);
	if (it == lists_.end()) { fatal("list id absent", std::to_string(l.v)); }
	return it->second;
}

void DeviceMetal::open_region(MetalList &ml) {
	MTLComputePassDescriptor *pass = [MTLComputePassDescriptor computePassDescriptor];
	if (ml.counters != nil && ml.region < kMaxMarks) {
		pass.sampleBufferAttachments[0].sampleBuffer = ml.counters;
		pass.sampleBufferAttachments[0].startOfEncoderSampleIndex = ml.region * 2;
		pass.sampleBufferAttachments[0].endOfEncoderSampleIndex = ml.region * 2 + 1;
	}
	ml.enc = [ml.cb computeCommandEncoderWithDescriptor:pass];
}

void DeviceMetal::close_region(MetalList &ml, const char *label) {
	[ml.enc endEncoding];
	ml.enc = nil;
	ml.labels.push_back(label == nullptr ? std::string() : std::string(label));
	++ml.region;
}

void DeviceMetal::bind(List &l, KernelId k, SetId s) {
	MetalList &ml = list_at(l);
	const MetalKernel &mk = at(k);
	if (mk.pso == nil) { fatal("bind before build", mk.meta.name); }
	auto it = sets_.find(s.v);
	if (it == sets_.end()) { fatal("set id absent", std::to_string(s.v)); }
	MetalSet &set = it->second;
	if (set.kernel != k.v) {
		fatal("a set built for another kernel", mk.meta.name);
	}
	[ml.enc setComputePipelineState:mk.pso];
	[ml.enc setBuffer:set.arg offset:0 atIndex:mk.meta.arg_slot];
	// Tier-2 argument buffers carry raw GPU addresses, so the buffers they point at must be made
	// resident on this encoder before the dispatch reads them.
	if (!set.used.empty()) {
		[ml.enc useResources:reinterpret_cast<__unsafe_unretained id<MTLResource> *>(set.used.data())
				count:set.used.size()
				usage:MTLResourceUsageRead | MTLResourceUsageWrite];
	}
	ml.local_x = mk.meta.local[0];
	ml.push_slot = mk.meta.push_slot;
}

void DeviceMetal::push(List &l, const void *data, size_t bytes) {
	MetalList &ml = list_at(l);
	[ml.enc setBytes:data length:bytes atIndex:ml.push_slot];
}

void DeviceMetal::dispatch(List &l, uint32_t groups_x) {
	MetalList &ml = list_at(l);
	[ml.enc dispatchThreadgroups:MTLSizeMake(groups_x, 1, 1)
			threadsPerThreadgroup:MTLSizeMake(ml.local_x, 1, 1)];
}

void DeviceMetal::dispatch_indirect(List &l, BufferId args, size_t off) {
	MetalList &ml = list_at(l);
	MetalBuffer &mb = buffer_at(args);
	if (mb.usage != Usage::Indirect) {
		fatal("an indirect dispatch reads a buffer not created for it", std::to_string(args.v));
	}
	[ml.enc dispatchThreadgroupsWithIndirectBuffer:mb.buf
			indirectBufferOffset:off
			threadsPerThreadgroup:MTLSizeMake(ml.local_x, 1, 1)];
}

void DeviceMetal::barrier(List &l) {
	[list_at(l).enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
}

void DeviceMetal::mark(List &l, const char *label) {
	MetalList &ml = list_at(l);
	close_region(ml, label);
	open_region(ml);
}

Fence DeviceMetal::submit(List &&l) {
	MetalList &ml = list_at(l);
	close_region(ml, nullptr);
	[ml.cb commit];
	Fence f{next_fence_++};
	fences_.emplace(f.v, std::move(ml));
	lists_.erase(l.v);
	l.v = 0;
	return f;
}

void DeviceMetal::wait(Fence f) {
	if (f.v == 0 || f.v >= next_fence_) { fatal("fence out of range", std::to_string(f.v)); }
	auto it = fences_.find(f.v);
	if (it == fences_.end()) { return; }
	MetalList &ml = it->second;
	[ml.cb waitUntilCompleted];
	if (ml.cb.status != MTLCommandBufferStatusCompleted) {
		const std::string error = ml.cb.error.localizedDescription.UTF8String ?: "Metal command failed";
		fences_.erase(it);
		throw DeviceFailure(error);
	}
	samples_.clear();
	if (ml.counters != nil && ml.region != 0) {
		const uint32_t regions = ml.region < kMaxMarks ? ml.region : kMaxMarks;
		NSData *data = [ml.counters resolveCounterRange:NSMakeRange(0, regions * 2)];
		if (data != nil) {
			const auto *ts = static_cast<const MTLCounterResultTimestamp *>(data.bytes);
			for (uint32_t r = 0; r < regions; ++r) {
				if (ml.labels[r].empty()) { continue; }
				const uint64_t a = ts[r * 2].timestamp;
				const uint64_t b = ts[r * 2 + 1].timestamp;
				const uint64_t ticks = b > a ? b - a : 0;
				samples_.push_back({ml.labels[r], static_cast<uint64_t>(double(ticks) * ns_per_tick_)});
			}
		}
	}
	fences_.erase(it);
}

bool DeviceMetal::poll(Fence f) {
	if (f.v == 0 || f.v >= next_fence_) { fatal("fence out of range", std::to_string(f.v)); }
	auto it = fences_.find(f.v);
	if (it == fences_.end()) { return true; }
	const MTLCommandBufferStatus s = it->second.cb.status;
	if (s == MTLCommandBufferStatusError) {
		const std::string error = it->second.cb.error.localizedDescription.UTF8String ?: "Metal command failed";
		fences_.erase(it);
		throw DeviceFailure(error);
	}
	return s == MTLCommandBufferStatusCompleted;
}

} // namespace

std::unique_ptr<Device> create_metal_device(int index, std::string &err) {
	auto dev = std::make_unique<DeviceMetal>();
	if (!dev->init(index, err)) { return nullptr; }
	return dev;
}

} // namespace la
