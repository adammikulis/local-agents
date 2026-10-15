#include "Lattice.hpp"
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

constexpr uint32_t kNx = 6;
constexpr uint32_t kNy = 6;
constexpr uint32_t kNz = 6;
constexpr float kEdgeM = 100.0f;
constexpr uint32_t kWords = 8192;
constexpr uint32_t kDraws = 8;
// float32 unit roundoff. A pairwise fold of n terms departs from the exact sum by at most k u sum|x|,
// k the depth of the tree; the factor two covers the rounding of each term's own weighting.
constexpr double kU = 5.9604645e-8;

struct Push {
	uint32_t cell_count;
	uint32_t op;
	uint32_t mask;
	uint32_t base;
	float threshold;
	uint32_t weight;
	uint32_t has_aux;
	uint32_t has_gate;
	float gate_lo;
	float gate_hi;
	uint32_t nbr;
	// chunk.glsli: the whole dispatch in one submit.
	uint32_t chunk_stride = 1;
	uint32_t chunk_phase = 0;
};

struct Row {
	uint32_t op;
	uint32_t mask;
	uint32_t weight;
	float threshold;
};

double fold_partials(Rig &rig, uint32_t groups, uint32_t op) {
	const std::vector<float> parts = rig.get(LA_BIND_REDUCE_PARTIALS, groups);
	if (op == OP_MIN) {
		double m = INFINITY;
		for (float v : parts) { m = std::fmin(m, double(v)); }
		return m;
	}
	if (op == OP_MAX) {
		double m = -INFINITY;
		for (float v : parts) { m = std::fmax(m, double(v)); }
		return m;
	}
	double s = 0.0;
	for (float v : parts) { s += double(v); }
	return s;
}

// The same fold the kernel is asked for, in float64 over the same float32 inputs.
double cpu_fold(const Row &row, const std::vector<float> &src, const std::vector<float> &solid,
		float edge, double &sum_abs) {
	sum_abs = 0.0;
	const float vol = edge * edge * edge;
	double acc = row.op == OP_MIN ? INFINITY : (row.op == OP_MAX ? -INFINITY : 0.0);
	for (size_t i = 0; i < src.size(); ++i) {
		const bool open = solid[i] == 0.0f;
		if (row.mask == MASK_OPEN && !open) { continue; }
		if (row.mask == MASK_SOLID && open) { continue; }
		float v = src[i];
		if (row.op == OP_SUM_ABS) { v = std::fabs(v); }
		switch (row.op) {
			case OP_COUNT_GT: acc += (v > row.threshold) ? 1.0 : 0.0; break;
			case OP_COUNT_GE: acc += (v >= row.threshold) ? 1.0 : 0.0; break;
			case OP_COUNT_LT: acc += (v < row.threshold) ? 1.0 : 0.0; break;
			case OP_COUNT: acc += 1.0; break;
			case OP_MIN: acc = std::fmin(acc, double(v)); break;
			case OP_MAX: acc = std::fmax(acc, double(v)); break;
			default: {
				const float term = row.weight != 0u ? v * vol : v;
				acc += double(term);
				sum_abs += std::fabs(double(term));
			} break;
		}
	}
	return acc;
}

struct Field {
	Lattice lat = Lattice::box(kNx, kNy, kNz, kEdgeM, 0.0f, 0.0f, 0.0f);
	std::vector<float> src;
	std::vector<float> solid;
};

Field draw(Rng &rng) {
	Field f;
	const uint32_t n = f.lat.cells();
	f.src.resize(n);
	f.solid.resize(n);
	for (uint32_t i = 0; i < n; ++i) {
		f.src[i] = rng.sign() * rng.decades(1.0e-3f, 1.0e6f);
		f.solid[i] = rng.chance(0.4f) ? 1.0f : 0.0f;
	}
	return f;
}

void load(Rig &rig, const Field &f) {
	rig.put(LA_BIND_NBR, f.lat.nbr);
	rig.put(LA_BIND_FACE_PARTNER, f.lat.partner);
	rig.put(LA_BIND_SLOT_OFF, f.lat.slot_off);
	rig.put(LA_BIND_CELL_EDGE, f.lat.cell_edge);
	rig.put(LA_BIND_VERT_UP, f.lat.vert_up);
	rig.put(LA_BIND_VERT_DOWN, f.lat.vert_down);
	rig.put(LA_BIND_REDUCE_SRC, f.src);
	rig.put(LA_BIND_SOLID, f.solid);
}

double run_row(Rig &rig, const Field &f, const Row &row) {
	const uint32_t n = f.lat.cells();
	Push p{};
	p.cell_count = n;
	p.op = row.op;
	p.mask = row.mask;
	p.base = 0;
	p.threshold = row.threshold;
	p.weight = row.weight;
	p.nbr = NBR_NONE;
	rig.zero(LA_BIND_REDUCE_PARTIALS);
	rig.run(&p, sizeof(p), n);
	return fold_partials(rig, rig.groups_for(n), row.op);
}

// The tree's depth: six halvings of the workgroup's 64 lanes, each lane holding one cell.
double fold_bound(double sum_abs) {
	return 2.0 * 6.0 * kU * sum_abs;
}

// SUM, SUM_ABS, MIN, MAX and the COUNT rows are the float64 fold of the same buffer.
bool prop_fold_matches_cpu(Case &c) {
	std::string err;
	Rig rig(c.dev, "reduce", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	const Row rows[] = {
		{ OP_SUM, MASK_ALL, 0u, 0.0f },
		{ OP_SUM, MASK_OPEN, 1u, 0.0f },
		{ OP_SUM_ABS, MASK_ALL, 0u, 0.0f },
		{ OP_MIN, MASK_ALL, 0u, 0.0f },
		{ OP_MAX, MASK_SOLID, 0u, 0.0f },
		{ OP_COUNT, MASK_OPEN, 0u, 0.0f },
		{ OP_COUNT_GT, MASK_ALL, 0u, 0.0f },
		{ OP_COUNT_LT, MASK_ALL, 0u, 1.0f },
	};
	Rng rng(c.seed);
	rng.stream(11);
	for (uint32_t d = 0; d < kDraws; ++d) {
		const Field f = draw(rng);
		load(rig, f);
		for (const Row &row : rows) {
			const double got = run_row(rig, f, row);
			double sum_abs = 0.0;
			const double want = shifted(float(cpu_fold(row, f.src, f.solid, kEdgeM, sum_abs)),
					c.mutate);
			const bool exact = row.op != OP_SUM && row.op != OP_SUM_ABS;
			const double bound = exact ? 0.0 : fold_bound(sum_abs);
			c.examined += 1;
			if (!std::isfinite(got) && !std::isfinite(want)) { continue; }
			if (!(std::fabs(got - want) <= bound)) {
				char buf[256];
				std::snprintf(buf, sizeof(buf),
						"op %u mask %u weight %u: the row and the float64 fold of the same buffer "
						"disagree past the tree's own bound",
						row.op, row.mask, row.weight);
				c.why = buf;
				return false;
			}
		}
	}
	return c.examined > 0;
}

// Open and solid partition the box: the two rows sum to the row over all of it.
bool prop_mask_partition(Case &c) {
	std::string err;
	Rig rig(c.dev, "reduce", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(12);
	for (uint32_t d = 0; d < kDraws; ++d) {
		const Field f = draw(rng);
		load(rig, f);
		const double all = run_row(rig, f, { OP_SUM, MASK_ALL, 1u, 0.0f });
		const double open = run_row(rig, f, { OP_SUM, MASK_OPEN, 1u, 0.0f });
		const double solid = run_row(rig, f, { OP_SUM, MASK_SOLID, 1u, 0.0f });
		double sum_abs = 0.0;
		cpu_fold({ OP_SUM, MASK_ALL, 1u, 0.0f }, f.src, f.solid, kEdgeM, sum_abs);
		const double bound = 3.0 * fold_bound(sum_abs);
		c.examined += 1;
		if (!(std::fabs(double(shifted(float(open + solid), c.mutate)) - all) <= bound)) {
			c.why = "the open row plus the solid row is not the row over the whole box";
			return false;
		}
	}
	return c.examined > 0;
}

} // namespace

void add_reduce_properties(std::vector<Property> &out) {
	out.push_back({ "reduce.glsl", "reduce_fold_matches_cpu", prop_fold_matches_cpu });
	out.push_back({ "reduce.glsl", "reduce_masks_partition_the_box", prop_mask_partition });
}

} // namespace lasim
