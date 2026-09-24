#include "Property.hpp"
#include "Rig.hpp"
#include "Rng.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "Generated.hpp"

namespace lasim {
namespace {

constexpr uint32_t kCells = 64;
constexpr uint32_t kEntries = kCells / 2u; // one entry per disjoint pair: no two threads touch a cell
constexpr uint32_t kWords = 8192;
constexpr uint32_t kDraws = 8;
constexpr double kU = 5.9604645e-8;

// sparse_edit.glsl's own op tags.
constexpr int32_t kAdd = 0;
constexpr int32_t kMove = 1;

struct Push {
	uint32_t base;
	uint32_t count;
	uint32_t cell_count;
	uint32_t same;
	// chunk.glsli: the whole dispatch in one submit.
	uint32_t chunk_stride = 1;
	uint32_t chunk_phase = 0;
};

struct Edit {
	std::vector<float> edge;
	std::vector<float> src;
	std::vector<float> dst;
	std::vector<int32_t> idx;
	std::vector<float> val;
	uint32_t same = 0;
};

// GRADED CELLS: the edge varies cell to cell, so a fill fraction crossing from one to another is a
// different fraction on arrival and vol_ratio is asked a real question.
Edit draw(Rng &rng) {
	Edit e;
	e.edge.resize(kCells);
	e.src.resize(kCells);
	e.dst.resize(kCells);
	e.idx.resize(size_t(kEntries) * 3u);
	e.val.resize(size_t(kEntries) * 2u);
	e.same = rng.chance(0.5f) ? 1u : 0u;
	for (uint32_t c = 0; c < kCells; ++c) {
		e.edge[c] = rng.decades(10.0f, 1.0e3f);
		e.src[c] = rng.decades(1.0e-3f, 1.0e3f);
		e.dst[c] = rng.decades(1.0e-3f, 1.0e3f);
	}
	for (uint32_t i = 0; i < kEntries; ++i) {
		const uint32_t s = 2u * i;
		const uint32_t d = 2u * i + 1u;
		e.idx[i * 3u] = int32_t(s);
		e.idx[i * 3u + 1u] = int32_t(d);
		e.idx[i * 3u + 2u] = rng.chance(0.5f) ? kMove : kAdd;
		// Amounts that overrun what the source holds as often as they do not, and a negative one:
		// a debit larger than the stock and a credit that would push a cell down are both real asks.
		e.val[i * 2u] = rng.chance(0.15f) ? -rng.decades(1.0e-3f, 1.0e2f)
										  : rng.decades(1.0e-4f, 1.0e4f);
		// A ceiling that binds about half the time, drawn around what the receiving cell holds.
		const float held = e.same == 1u ? e.src[d] : e.dst[d];
		e.val[i * 2u + 1u] = held * rng.decades(0.1f, 10.0f);
	}
	return e;
}

void load(Rig &rig, const Edit &e) {
	rig.put(LA_BIND_CELL_EDGE, e.edge);
	rig.put(LA_BIND_INJECT_SRC, e.src);
	rig.put(LA_BIND_INJECT_DST, e.dst);
	rig.put(LA_BIND_INJECT_IDX, e.idx);
	rig.put(LA_BIND_INJECT_VAL, e.val);
	rig.zero(LA_BIND_INJECT_APPLIED);
}

double volume(const Edit &e, uint32_t c) {
	const double s = double(e.edge[c]);
	return s * s * s;
}

// A MOVE IS A MOVE: the matter the source loses is the matter the destination gains, whatever the two
// cells' sizes. A fill fraction is not conserved across a size change; the fraction times the volume is.
bool prop_move_conserves_matter(Case &c) {
	std::string err;
	Rig rig(c.dev, "sparse_edit", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(81);
	uint32_t moved = 0;
	for (uint32_t d = 0; d < kDraws; ++d) {
		const Edit e = draw(rng);
		load(rig, e);
		Push p{ 0u, kEntries, kCells, e.same };
		rig.run(&p, sizeof(p), kEntries);
		const std::vector<float> src = rig.get(LA_BIND_INJECT_SRC, kCells);
		const std::vector<float> dst = rig.get(LA_BIND_INJECT_DST, kCells);
		const std::vector<float> applied = rig.get(LA_BIND_INJECT_APPLIED, kEntries);
		for (uint32_t i = 0; i < kEntries; ++i) {
			if (e.idx[i * 3u + 2u] != kMove) { continue; }
			const uint32_t s = uint32_t(e.idx[i * 3u]);
			const uint32_t r = uint32_t(e.idx[i * 3u + 1u]);
			const double vs = volume(e, s);
			const double vr = volume(e, r);
			const double lost = double(e.src[s]) - double(src[s]);
			const double gained = e.same == 1u ? double(src[r]) - double(e.src[r])
											   : double(dst[r]) - double(e.dst[r]);
			const double held_before = e.same == 1u ? double(e.src[r]) : double(e.dst[r]);
			if (lost != 0.0) { ++moved; }
			// Both sides store a stock plus a change in float32, so neither can resolve finer than
			// the last bit of what its own cell already held.
			const double bound = 8.0 * kU
					* (std::fabs(double(e.src[s])) * vs + std::fabs(held_before) * vr
							+ std::fabs(gained) * vr + std::fabs(lost) * vs);
			c.examined += 1;
			if (!(std::fabs(double(shifted(float(lost), c.mutate)) * vs - gained * vr) <= bound)) {
				char buf[224];
				std::snprintf(buf, sizeof(buf),
						"draw %u entry %u: a move credited the destination something other than the "
						"matter it debited the source",
						d, i);
				c.why = buf;
				return false;
			}
			c.examined += 1;
			if (!(std::fabs(double(shifted(applied[i], c.mutate)) - lost)
						<= 8.0 * kU * std::fabs(double(e.src[s])))) {
				char buf[224];
				std::snprintf(buf, sizeof(buf),
						"draw %u entry %u: the amount the device reported applying is not the amount "
						"the source lost",
						d, i);
				c.why = buf;
				return false;
			}
		}
	}
	if (moved == 0) {
		c.why = "no entry moved anything, so the books were never asked to close";
		return false;
	}
	return c.examined > 0;
}

// NOTHING IS TAKEN THAT IS NOT THERE, and nothing is pushed past the ceiling it was given: a stock
// that goes negative is matter borrowed from nowhere, and an add over the ceiling is matter minted.
bool prop_edits_stay_inside_the_stock(Case &c) {
	std::string err;
	Rig rig(c.dev, "sparse_edit", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(82);
	for (uint32_t d = 0; d < kDraws; ++d) {
		const Edit e = draw(rng);
		load(rig, e);
		Push p{ 0u, kEntries, kCells, e.same };
		rig.run(&p, sizeof(p), kEntries);
		const std::vector<float> src = rig.get(LA_BIND_INJECT_SRC, kCells);
		const std::vector<float> dst = rig.get(LA_BIND_INJECT_DST, kCells);
		for (uint32_t i = 0; i < kEntries; ++i) {
			const uint32_t s = uint32_t(e.idx[i * 3u]);
			const uint32_t r = uint32_t(e.idx[i * 3u + 1u]);
			const int32_t op = e.idx[i * 3u + 2u];
			const float ceiling = e.val[i * 2u + 1u];
			c.examined += 1;
			if (!std::isfinite(double(src[s])) || double(shifted(src[s], c.mutate)) < 0.0) {
				char buf[224];
				std::snprintf(buf, sizeof(buf),
						"draw %u entry %u op %d: a cell was debited past what it held "
						"(%.9g asked of %.9g, %.9g left, edges %.9g -> %.9g)",
						d, i, op, double(e.val[i * 2u]), double(e.src[s]), double(src[s]),
						double(e.edge[s]), double(e.edge[r]));
				c.why = buf;
				return false;
			}
			if (op == kAdd) {
				// The headroom is what the ceiling leaves; a cell already over it is left alone.
				const double before = double(e.src[s]);
				const double cap = std::fmax(before, double(ceiling));
				c.examined += 1;
				if (double(shifted(src[s], c.mutate)) > cap + 4.0 * kU * std::fabs(cap)) {
					c.why = "an add filled a cell past the ceiling it was given";
					return false;
				}
				c.examined += 1;
				if (e.val[i * 2u] > 0.0f && double(shifted(src[s], c.mutate)) < before) {
					c.why = "a credit pushed a cell down";
					return false;
				}
				continue;
			}
			const double held_before = e.same == 1u ? double(e.src[r]) : double(e.dst[r]);
			const double held_after = e.same == 1u ? double(src[r]) : double(dst[r]);
			const double cap = std::fmax(held_before, double(ceiling));
			c.examined += 1;
			if (!(double(shifted(float(held_after), c.mutate)) <= cap + 4.0 * kU * std::fabs(cap))) {
				c.why = "a move filled the destination past the ceiling it was given";
				return false;
			}
			c.examined += 1;
			if (double(shifted(float(held_after), c.mutate)) < held_before) {
				c.why = "a move took matter out of the destination";
				return false;
			}
		}
	}
	return c.examined > 0;
}

} // namespace

void add_sparse_properties(std::vector<Property> &out) {
	out.push_back({ "sparse_edit.glsl", "sparse_edit_move_conserves_matter",
			prop_move_conserves_matter });
	out.push_back({ "sparse_edit.glsl", "sparse_edit_stays_inside_the_stock",
			prop_edits_stay_inside_the_stock });
}

} // namespace lasim
