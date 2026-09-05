#include "Selftest.hpp"

#include "la/Device.hpp"

#include <cmath>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

namespace lasim {
namespace {

constexpr uint32_t kLanes = 64;
constexpr float kSentinel = -12345.0f;

// stack_selftest: floats per case, and the residual it writes back into the first of them.
constexpr uint32_t kStackCase = 8;
constexpr float kPMeanPa = 101325.0f;
constexpr float kGMS2 = 9.80665f;
constexpr float kAirKgM3 = 1.225f;

// enthalpy_selftest: h_total, p, room volume, then the two masses.
constexpr uint32_t kEnthalpyCase = 5;

void fail(const char *what) { std::fprintf(stderr, "selftest-kernels: %s\n", what); }

struct StackCase {
	float a;
	float edge;
	float m_cond;
	float m_total;
	float dir[3];
};

// A cube of air `a` scale heights tall, with and without a rock load, under four gravity directions.
std::vector<StackCase> stack_cases() {
	const float dirs[4][3] = {{0.0f, -1.0f, 0.0f}, {1.0f, 0.0f, 0.0f}, {0.141f, -0.984f, 0.112f},
			{1.0f, 1.0f, 1.0f}};
	std::vector<StackCase> out;
	for (float a : {0.1f, 1.0f, 10.0f}) {
		for (float m_cond : {0.0f, 900.0f}) {
			for (const auto &d : dirs) {
				const float n = std::sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
				out.push_back(StackCase{a, 2.0f * a * kPMeanPa / (kAirKgM3 * kGMS2), m_cond,
						kAirKgM3 + m_cond, {d[0] / n, d[1] / n, d[2] / n}});
			}
		}
	}
	return out;
}

int run_probe(la::Device &dev, const char *kernel, std::vector<float> &probe) {
	std::string err;
	la::KernelId k = dev.kernel(kernel);
	if (!dev.build(k, err)) {
		fail(err.c_str());
		return 1;
	}
	int probe_slot = -1;
	int declared = 0;
	for (uint32_t b = 0; b < 256; ++b) {
		if (dev.declares(k, b)) { probe_slot = int(b); ++declared; }
	}
	if (declared != 1) {
		fail("the probe kernel does not declare exactly one buffer");
		return 1;
	}
	la::BufferId buf = dev.create_buffer(probe.size() * sizeof(float), la::Usage::Storage,
			probe.data());
	std::vector<std::pair<uint32_t, la::BufferId>> bound{{uint32_t(probe_slot), buf}};
	la::SetId set = dev.make_set(k, bound);
	la::List list = dev.begin();
	dev.bind(list, k, set);
	dev.dispatch(list, 1);
	dev.mark(list, kernel);
	la::Fence fence = dev.submit(std::move(list));
	dev.wait(fence);
	dev.download(buf, 0, probe.data(), probe.size() * sizeof(float));
	dev.destroy_set(set);
	dev.destroy_buffer(buf);
	return 0;
}

// One cell at rest must get exactly its own weight back from its own six faces, at any scale height and
// any gravity direction. A cell that does not is a cell that accelerates while standing still.
int stack_arm(la::Device &dev) {
	const std::vector<StackCase> cases = stack_cases();
	std::vector<float> probe(kLanes * kStackCase, kSentinel);
	for (size_t i = 0; i < cases.size(); ++i) {
		const size_t b = i * kStackCase;
		probe[b] = cases[i].edge;
		probe[b + 1] = kGMS2;
		probe[b + 2] = cases[i].m_cond;
		probe[b + 3] = cases[i].m_total;
		probe[b + 4] = kPMeanPa;
		probe[b + 5] = cases[i].dir[0];
		probe[b + 6] = cases[i].dir[1];
		probe[b + 7] = cases[i].dir[2];
	}
	const int rc = run_probe(dev, "stack_selftest", probe);
	if (rc != 0) { return rc; }
	int code = 0;
	for (size_t i = 0; i < cases.size(); ++i) {
		const float res = probe[i * kStackCase];
		std::printf("STACK_BALANCE={\"a\":%.1f,\"m_cond\":%.0f,\"dir\":[%.3f,%.3f,%.3f],"
					"\"residual\":%.3e}\n",
				cases[i].a, cases[i].m_cond, cases[i].dir[0], cases[i].dir[1], cases[i].dir[2], res);
		if (!std::isfinite(res) || res == kSentinel || res > kStackResidualBar) {
			fail("a cube at rest does not get its own weight back from its own faces");
			code = 1;
		}
	}
	return code;
}

// Adding energy to a fixed mixture at a fixed pressure may not lower what the mixture reports back.
int enthalpy_arm(la::Device &dev) {
	const uint32_t cases = 24;
	std::vector<float> probe(kLanes * kEnthalpyCase, kSentinel);
	std::vector<float> given(cases, 0.0f);
	for (uint32_t i = 0; i < cases; ++i) {
		given[i] = 1.0e5f * std::pow(1.5f, float(i));
		const size_t b = i * kEnthalpyCase;
		probe[b] = given[i];
		probe[b + 1] = kPMeanPa;
		probe[b + 2] = 1.0f;
		probe[b + 3] = 1.0f;
		probe[b + 4] = 1.0f;
	}
	const int rc = run_probe(dev, "enthalpy_selftest", probe);
	if (rc != 0) { return rc; }
	int code = 0;
	float previous = -std::numeric_limits<float>::infinity();
	for (uint32_t i = 0; i < cases; ++i) {
		const float got = probe[i * kEnthalpyCase];
		std::printf("ENTHALPY_MONOTONE={\"h_j\":%.3e,\"state\":%.6e}\n", given[i], got);
		if (!std::isfinite(got) || got == kSentinel) {
			fail("the enthalpy mixture returned nothing finite for a real mass at a real pressure");
			code = 1;
		} else if (got < previous) {
			fail("adding enthalpy to a fixed mixture at a fixed pressure lowered its state");
			code = 1;
		}
		previous = got;
	}
	if (code == 0 && !(probe[(cases - 1) * kEnthalpyCase] > probe[0])) {
		fail("the whole enthalpy range moved the mixture nowhere");
		code = 1;
	}
	return code;
}

} // namespace

// Every kernel translated and made into a pipeline, then the two probe kernels actually run. Creating
// flux's pipeline is what proves the argument-buffer path carries far more bindings than Metal's 31
// buffer slots.
int selftest_kernels(la::Device &dev, const std::string &blob) {
	std::string err;
	if (!dev.load_kernels(blob, err)) {
		fail(err.c_str());
		return 2;
	}
	int code = 0;
	for (size_t i = 1; i <= dev.kernel_count(); ++i) {
		la::KernelId k{static_cast<uint32_t>(i)};
		const std::vector<uint32_t> bindings = dev.bindings_of(k);
		const bool ok = dev.build(k, err);
		std::printf("NATIVE_PIPELINE={\"name\":\"%s\",\"bindings\":%zu,\"max_binding\":%u,"
					"\"push\":%u,\"ok\":%s}\n",
				dev.kernel_name(k), bindings.size(), bindings.empty() ? 0u : bindings.back(),
				dev.push_size(k), ok ? "true" : "false");
		if (!ok) {
			fail(err.c_str());
			code = 1;
		}
	}
	if (code != 0) { return code; }
	if (!dev.has_kernel("stack_selftest") || !dev.has_kernel("enthalpy_selftest")) {
		fail("the blob carries neither selftest kernel, so nothing was dispatched");
		return 2;
	}
	const int stack = stack_arm(dev);
	const int enthalpy = enthalpy_arm(dev);
	return stack != 0 ? stack : enthalpy;
}

} // namespace lasim
