#pragma once

#include <cmath>
#include <cstdint>

namespace lasim {

// COUNTER-BASED: draw n depends only on (seed, stream, n), so a case replays from the printed seed.
class Rng {
public:
	explicit Rng(uint64_t p_seed) :
			seed_(p_seed) {}

	void stream(uint64_t p_stream) { ctr_ = p_stream << 40; }

	uint64_t bits() { return hash(seed_ ^ hash(ctr_++)); }
	float unit() { return float(double(bits() >> 11) * 0x1.0p-53); }
	float range(float lo, float hi) { return lo + (hi - lo) * unit(); }
	// Uniform in the exponent: a physical magnitude spans decades, not an interval.
	float decades(float lo, float hi) { return lo * std::pow(hi / lo, unit()); }
	bool chance(float p) { return unit() < p; }
	uint32_t below(uint32_t n) { return n == 0 ? 0u : uint32_t(bits() % n); }
	float sign() { return chance(0.5f) ? 1.0f : -1.0f; }

private:
	static uint64_t hash(uint64_t x) {
		x += 0x9E3779B97F4A7C15ull;
		x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ull;
		x = (x ^ (x >> 27)) * 0x94D049BB133111EBull;
		return x ^ (x >> 31);
	}

	uint64_t seed_;
	uint64_t ctr_ = 0;
};

} // namespace lasim
