#include "Selftest.hpp"

#include "la/Device.hpp"

#include <cmath>
#include <cstdio>
#include <vector>

namespace lasim {
namespace {

constexpr uint32_t kLanes = 64;
constexpr uint32_t kCase = 8;
constexpr float kSentinel = -12345.0f;
// Standard atmosphere and standard gravity, both defined values, and sea-level air at the ISA.
constexpr float kPMeanPa = 101325.0f;
constexpr float kGMS2 = 9.80665f;
constexpr float kAirKgM3 = 1.225f;

void fail(const char *what) { std::fprintf(stderr, "selftest-device: %s\n", what); }

// A labelled region that came back with no duration measured nothing, and a zero is not a duration.
bool region_measured(la::Device &dev) {
	std::span<const la::TimestampSample> ts = dev.timestamps();
	if (ts.empty()) {
		fail("a labelled region came back with no timestamp");
		return false;
	}
	for (const la::TimestampSample &s : ts) {
		std::printf("NATIVE_TIMESTAMP={\"label\":\"%s\",\"gpu_ns\":%llu}\n", s.label.c_str(),
				static_cast<unsigned long long>(s.gpu_ns));
		if (s.gpu_ns == 0) {
			fail("a labelled region took no measurable time, so the clock is not running");
			return false;
		}
	}
	return true;
}

// One cube of sea-level air a metre on a side, in every lane.
std::vector<float> air_cell_cases() {
	std::vector<float> out(kLanes * kCase, 0.0f);
	for (uint32_t i = 0; i < kLanes; ++i) {
		out[i * kCase + 0] = 1.0f;
		out[i * kCase + 1] = kGMS2;
		out[i * kCase + 3] = kAirKgM3;
		out[i * kCase + 4] = kPMeanPa;
		out[i * kCase + 6] = -1.0f;
	}
	return out;
}

int buffer_arm(la::Device &dev) {
	std::vector<float> host(kLanes * kCase, kSentinel);
	la::BufferId a = dev.create_buffer(host.size() * sizeof(float), la::Usage::Storage, host.data());
	la::BufferId b = dev.create_buffer(host.size() * sizeof(float), la::Usage::Storage, nullptr);
	std::vector<float> back(host.size(), 0.0f);
	dev.download(a, 0, back.data(), back.size() * sizeof(float));
	int code = 0;
	for (size_t i = 0; i < host.size() && code == 0; ++i) {
		if (back[i] != host[i]) {
			fail("a buffer did not return what was written into it");
			code = 1;
		}
	}
	const float probe = 7.5f;
	dev.upload(a, 4 * sizeof(float), &probe, sizeof(float));
	dev.download(a, 4 * sizeof(float), back.data(), sizeof(float));
	if (code == 0 && back[0] != probe) {
		fail("an upload at an offset did not land there");
		code = 1;
	}
	dev.copy(a, 0, b, 0, host.size() * sizeof(float));
	dev.download(b, 4 * sizeof(float), back.data(), sizeof(float));
	if (code == 0 && back[0] != probe) {
		fail("a device copy did not carry what the source held");
		code = 1;
	}
	dev.clear(a, 0, host.size() * sizeof(float));
	dev.download(a, 0, back.data(), back.size() * sizeof(float));
	for (float v : back) {
		if (code == 0 && v != 0.0f) {
			fail("a cleared buffer still carries what was in it");
			code = 1;
		}
	}
	dev.destroy_buffer(b);
	dev.destroy_buffer(a);
	return code;
}

} // namespace

// The device's own mechanics, on the smallest kernel the blob carries: a buffer round trip, a dispatch, an
// indirect dispatch ordered behind a barrier, and labelled regions that come back with durations.
int selftest_device(la::Device &dev, const std::string &blob) {
	std::string err;
	if (!dev.load_kernels(blob, err)) {
		fail(err.c_str());
		return 2;
	}
	std::printf("NATIVE_DEVICE={\"name\":\"%s\",\"backend\":\"%s\",\"kernels\":%zu,"
				"\"timestamps\":%s}\n",
			dev.name(), dev.backend() == la::Backend::Metal ? "metal" : "vulkan", dev.kernel_count(),
			dev.supports_timestamps() ? "true" : "false");
	if (!dev.supports_timestamps()) {
		fail("this device reports no GPU counter sampling, so a pass duration cannot be measured");
		return 2;
	}
	const int buffers = buffer_arm(dev);
	if (buffers != 0) { return buffers; }

	if (!dev.has_kernel("stack_selftest")) {
		fail("the blob carries no stack_selftest kernel to dispatch");
		return 2;
	}
	la::KernelId k = dev.kernel("stack_selftest");
	if (!dev.build(k, err)) {
		fail(err.c_str());
		return 1;
	}
	if (!dev.declares(k, 0) || dev.declares(k, 1)) {
		fail("the blob's reflection does not match the one buffer stack_selftest declares");
		return 1;
	}
	const uint32_t groups = (kLanes + dev.local_size_x(k) - 1) / dev.local_size_x(k);

	const std::vector<float> cases = air_cell_cases();
	std::vector<float> once(cases.size(), 0.0f);
	std::vector<float> twice(cases.size(), 0.0f);
	la::BufferId buf = dev.create_buffer(cases.size() * sizeof(float), la::Usage::Storage,
			cases.data());
	std::vector<std::pair<uint32_t, la::BufferId>> bound{{0u, buf}};
	la::SetId set = dev.make_set(k, bound);

	la::List first = dev.begin();
	dev.bind(first, k, set);
	dev.dispatch(first, groups);
	dev.mark(first, "stack_direct");
	la::Fence f1 = dev.submit(std::move(first));
	dev.wait(f1);
	if (!dev.poll(f1)) {
		fail("a fence that was waited on still reports the list unfinished");
		return 1;
	}
	if (!region_measured(dev)) { return 1; }
	dev.download(buf, 0, once.data(), once.size() * sizeof(float));
	for (uint32_t i = 0; i < kLanes; ++i) {
		if (once[i * kCase] == cases[i * kCase]) {
			fail("a dispatched kernel left a lane exactly as it found it");
			return 1;
		}
	}

	la::List second = dev.begin();
	dev.bind(second, k, set);
	dev.dispatch(second, groups);
	dev.mark(second, "stack_again");
	la::Fence f2 = dev.submit(std::move(second));
	dev.wait(f2);
	dev.download(buf, 0, twice.data(), twice.size() * sizeof(float));
	for (uint32_t i = 0; i < kLanes; ++i) {
		if (!std::isfinite(twice[i * kCase])) {
			fail("the probe run twice over its own output left a lane non-finite, so the chained arm "
					"below would compare nothing");
			return 1;
		}
	}

	// The same two dispatches in ONE list, the second reading what the first wrote. An indirect dispatch
	// off an argument buffer must land on the same numbers as the direct one it stands in for.
	const uint32_t args[3] = {groups, 1, 1};
	la::BufferId argbuf = dev.create_buffer(sizeof(args), la::Usage::Indirect, args);
	dev.upload(buf, 0, cases.data(), cases.size() * sizeof(float));
	la::List both = dev.begin();
	dev.bind(both, k, set);
	dev.dispatch(both, groups);
	dev.barrier(both);
	dev.dispatch_indirect(both, argbuf, 0);
	dev.mark(both, "stack_chained");
	la::Fence f3 = dev.submit(std::move(both));
	dev.wait(f3);
	if (!region_measured(dev)) { return 1; }
	std::vector<float> chained(cases.size(), 0.0f);
	dev.download(buf, 0, chained.data(), chained.size() * sizeof(float));
	for (uint32_t i = 0; i < kLanes; ++i) {
		if (chained[i * kCase] != twice[i * kCase]) {
			fail("a barrier did not order two dispatches in one list, or the indirect one read other "
					"arguments");
			return 1;
		}
	}

	dev.destroy_set(set);
	dev.destroy_buffer(argbuf);
	dev.destroy_buffer(buf);
	std::printf("NATIVE_DEVICE_OK={\"roundtrip\":true,\"copy\":true,\"dispatch\":true,"
				"\"indirect\":true,\"barrier\":true}\n");
	return 0;
}

} // namespace lasim
