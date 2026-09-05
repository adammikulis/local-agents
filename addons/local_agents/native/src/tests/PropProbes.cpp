#include "Property.hpp"
#include "Rig.hpp"
#include "Rng.hpp"
#include "cli/Selftest.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "Generated.hpp"

namespace lasim {
namespace {

constexpr uint32_t kWords = 8192;
constexpr uint32_t kCases = 512;
constexpr uint32_t kStackCase = 8;     // stack_selftest.glsl LA_CASE
constexpr uint32_t kEnthalpyCase = 5;  // enthalpy_selftest.glsl's stride

// A CUBE AT REST gets exactly its own weight back from its own six faces, at any scale height, any
// condensed load and any direction of the pull. A cell that does not accelerates while standing still.
bool prop_stack_returns_the_cells_weight(Case &c) {
	std::string err;
	Rig rig(c.dev, "stack_selftest", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(61);
	std::vector<float> probe(size_t(kCases) * kStackCase, 0.0f);
	for (uint32_t i = 0; i < kCases; ++i) {
		const float p_mean = rng.decades(1.0e-2f, 1.0e9f);
		const float g = rng.range(0.5f, 30.0f);
		const float m_gas = rng.decades(1.0e-4f, 50.0f);
		const float a = rng.decades(0.05f, 20.0f); // the cube's height in scale heights
		const float m_cond = rng.chance(0.5f) ? 0.0f : rng.decades(1.0f, 5.0e3f);
		float dx = rng.range(-1.0f, 1.0f);
		float dy = rng.range(-1.0f, 1.0f);
		float dz = rng.range(-1.0f, 1.0f);
		const float len = std::sqrt(dx * dx + dy * dy + dz * dz);
		if (!(len > 0.0f)) {
			dx = 0.0f;
			dy = -1.0f;
			dz = 0.0f;
		} else {
			dx /= len;
			dy /= len;
			dz /= len;
		}
		const size_t b = size_t(i) * kStackCase;
		probe[b] = 2.0f * a * p_mean / (m_gas * g);
		probe[b + 1] = g;
		probe[b + 2] = m_cond;
		probe[b + 3] = m_gas + m_cond;
		probe[b + 4] = p_mean;
		probe[b + 5] = dx;
		probe[b + 6] = dy;
		probe[b + 7] = dz;
	}
	rig.put(LA_BIND_STACK_PROBE, probe);
	rig.run(nullptr, 0, kCases);
	const std::vector<float> got = rig.get(LA_BIND_STACK_PROBE, probe.size());
	for (uint32_t i = 0; i < kCases; ++i) {
		const float res = got[size_t(i) * kStackCase];
		c.examined += 1;
		if (!std::isfinite(res)) {
			c.why = "a cube at rest returned a non-finite residual";
			return false;
		}
		if (shifted(res, c.mutate) > kStackResidualBar) {
			c.why = "a cube at rest does not get its own weight back from its own faces";
			return false;
		}
	}
	return c.examined > 0;
}

// THE MIXTURE LADDER answers for any enthalpy, at any pressure, over any room, for any masses it is
// handed. A cell whose state comes back non-finite is a cell the whole step then reads.
bool prop_enthalpy_ladder_is_finite(Case &c) {
	std::string err;
	Rig rig(c.dev, "enthalpy_selftest", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(62);
	std::vector<float> probe(size_t(kCases) * kEnthalpyCase, 0.0f);
	for (uint32_t i = 0; i < kCases; ++i) {
		const size_t b = size_t(i) * kEnthalpyCase;
		probe[b] = rng.sign() * rng.decades(1.0e2f, 1.0e10f);
		probe[b + 1] = rng.decades(1.0f, 1.0e11f);
		probe[b + 2] = rng.decades(1.0e-6f, 1.0e3f);
		probe[b + 3] = rng.decades(1.0e-6f, 1.0e4f);
		probe[b + 4] = rng.decades(1.0e-6f, 1.0e4f);
	}
	rig.put(LA_BIND_ENTHALPY_PROBE, probe);
	rig.run(nullptr, 0, kCases);
	const std::vector<float> got = rig.get(LA_BIND_ENTHALPY_PROBE, probe.size());
	for (uint32_t i = 0; i < kCases; ++i) {
		const float v = got[size_t(i) * kEnthalpyCase];
		c.examined += 1;
		if (!std::isfinite(c.mutate ? (v * 0.0f + std::nanf("")) : v)) {
			c.why = "the mixture ladder returned nothing finite for a real mass at a real pressure";
			return false;
		}
	}
	return c.examined > 0;
}

} // namespace

void add_probe_properties(std::vector<Property> &out) {
	out.push_back({ "stack_selftest.glsl", "stack_returns_the_cells_own_weight",
			prop_stack_returns_the_cells_weight });
	out.push_back({ "enthalpy_selftest.glsl", "enthalpy_ladder_is_finite",
			prop_enthalpy_ladder_is_finite });
}

} // namespace lasim
