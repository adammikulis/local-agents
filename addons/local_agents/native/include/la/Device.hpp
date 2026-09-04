#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace la {

enum class Backend { Metal, Vulkan };
enum class Usage { Storage, Indirect };

struct BufferId { uint32_t v = 0; };
struct KernelId { uint32_t v = 0; };
struct SetId { uint32_t v = 0; };
struct Fence { uint64_t v = 0; };

// One labelled region of a submitted list, in GPU nanoseconds.
struct TimestampSample {
	std::string label;
	uint64_t gpu_ns = 0;
};

// A compute list under construction. `v` indexes the backend's open list; a list is submitted once.
class List {
public:
	uint32_t v = 0;
};

// The compute device the physics runs on. One-to-one with what the field passes use: buffers, kernels
// loaded from the baked blob, cached binding tables, lists of dispatches, fences, timestamps.
class Device {
public:
	virtual ~Device();
	static std::unique_ptr<Device> create(Backend backend, int index, std::string &err);

	virtual const char *name() const = 0;
	virtual Backend backend() const = 0;
	virtual bool supports_timestamps() const = 0;

	virtual bool load_kernels(const std::string &blob_path, std::string &err) = 0;
	virtual size_t kernel_count() const = 0;
	virtual bool has_kernel(std::string_view name) const = 0;
	// Aborts on an unknown name: a kernel the blob does not carry is a build that did not happen.
	virtual KernelId kernel(std::string_view name) = 0;
	// Translates the baked source and creates the pipeline. False with `err` on a device that refuses it.
	virtual bool build(KernelId, std::string &err) = 0;
	virtual const char *kernel_name(KernelId) const = 0;
	virtual uint32_t push_size(KernelId) const = 0;
	virtual bool declares(KernelId, uint32_t binding) const = 0;
	virtual uint32_t local_size_x(KernelId) const = 0;
	virtual std::vector<uint32_t> bindings_of(KernelId) const = 0;

	virtual BufferId create_buffer(size_t bytes, Usage usage, const void *init) = 0;
	virtual void destroy_buffer(BufferId) = 0;
	virtual void upload(BufferId, size_t off, const void *src, size_t bytes) = 0;
	virtual void download(BufferId, size_t off, void *dst, size_t bytes) = 0;
	virtual void clear(BufferId, size_t off, size_t bytes) = 0;
	virtual void copy(BufferId src, size_t soff, BufferId dst, size_t doff, size_t bytes) = 0;

	// Every binding the kernel declares must appear exactly once, or the call aborts naming the gap.
	virtual SetId make_set(KernelId, std::span<const std::pair<uint32_t, BufferId>> bound) = 0;
	virtual void destroy_set(SetId) = 0;

	virtual List begin() = 0;
	virtual void bind(List &, KernelId, SetId) = 0;
	virtual void push(List &, const void *data, size_t bytes) = 0;
	virtual void dispatch(List &, uint32_t groups_x) = 0;
	virtual void dispatch_indirect(List &, BufferId args, size_t byte_off) = 0;
	virtual void barrier(List &) = 0;
	// Closes the region that has been recorded since the last mark and names it.
	virtual void mark(List &, const char *label) = 0;
	virtual Fence submit(List &&) = 0;
	virtual void wait(Fence) = 0;
	virtual bool poll(Fence) = 0;
	// The labelled regions of the last waited-on list.
	virtual std::span<const TimestampSample> timestamps() const = 0;
};

} // namespace la
