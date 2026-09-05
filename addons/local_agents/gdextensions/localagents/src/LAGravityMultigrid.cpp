#include "LAGravityMultigrid.hpp"

#include "bindings.glsli"

#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <unordered_map>
#include <vector>

using namespace godot;

namespace {

const uint32_t MODE_LOAD = 0u;
const uint32_t MODE_SMOOTH = 1u;
const uint32_t MODE_RESIDUAL = 2u;
const uint32_t MODE_RESTRICT = 3u;
const uint32_t MODE_PROLONG = 4u;
const uint32_t MODE_NORM = 5u;
const uint32_t MODE_NORM_FOLD = 6u;
const uint32_t MODE_STORE = 7u;

const uint32_t FLAG_RING = 1u;
const uint32_t COLOUR_SHIFT = 1u;
const uint32_t OCTANT_SHIFT = 3u;
const uint32_t FLAG_PASS = 64u;
const uint32_t DEPTH_SHIFT = 7u;

const uint32_t GROUP = 64u;
const uint32_t COLOURS = 4u;
// Pre- and post-smoothing sweeps of all four colours, and the sweeps the coarsest level takes instead
// of a direct solve: it holds at most COARSEST_SPAN^3 cells.
const int NU_PRE = 2;
const int NU_POST = 2;
const int NU_COARSE = 16;

struct Level {
	int count = 0;
	int base = 0;
	std::vector<int> depth;
	std::vector<int> x, y, z;
	std::vector<int> off;
	std::vector<int> nbr;
	std::vector<int> parent;
	std::vector<uint32_t> flags;
	std::vector<int> child_off;
	std::vector<int> child_idx;
};

uint64_t key_of(int d, int x, int y, int z) {
	return (uint64_t(uint32_t(d + 32)) << 57) | (uint64_t(uint32_t(x)) << 38)
			| (uint64_t(uint32_t(y)) << 19) | uint64_t(uint32_t(z));
}

void put_u32(uint8_t *w, int off, uint32_t v) {
	std::memcpy(w + off, &v, sizeof(uint32_t));
}

void put_f32(uint8_t *w, int off, float v) {
	std::memcpy(w + off, &v, sizeof(float));
}

uint32_t groups_for(int n) {
	return uint32_t(n > 0 ? (n + int(GROUP) - 1) / int(GROUP) : 1);
}

} // namespace

namespace {

Dictionary build_hierarchy(Object *p_grid) {
	Dictionary out;
	ERR_FAIL_NULL_V(p_grid, out);
	const int cc = int(p_grid->get("cell_count"));
	const int nx = int(p_grid->get("nx"));
	const int ny = int(p_grid->get("ny"));
	const int nz = int(p_grid->get("nz"));
	const double cell_size = double(p_grid->get("cell_size"));
	const int max_level = int(p_grid->get("max_level"));
	const PackedInt32Array slot_off = p_grid->get("slot_off");
	const PackedInt32Array neighbours = p_grid->get("neighbours");
	const PackedByteArray levels = p_grid->get("levels");
	const PackedInt32Array cell_base = p_grid->get("cell_base");
	const PackedInt32Array cell_local = p_grid->get("cell_local");
	if (cc <= 0 || slot_off.size() < cc * 7 || levels.size() < cc || cell_base.size() < cc
			|| cell_local.size() < cc * 3 || nx <= 0 || ny <= 0 || nz <= 0 || cell_size <= 0.0) {
		return out;
	}
	int span = nx > ny ? nx : ny;
	span = span > nz ? span : nz;
	int agglomerations = 0;
	while (span > 4) {
		span = (span + 1) / 2;
		agglomerations++;
	}
	if (agglomerations == 0) {
		agglomerations = 1;
	}
	ERR_FAIL_COND_V_MSG(max_level + agglomerations > 31, out,
			"LAGravityMultigrid: the hierarchy is deeper than the flag word's depth field.");
	const int n_levels = max_level + agglomerations + 1;

	std::vector<Level> lv;
	lv.resize(size_t(n_levels));
	Level &l0 = lv[0];
	l0.count = cc;
	l0.base = 0;
	l0.depth.resize(size_t(cc));
	l0.x.resize(size_t(cc));
	l0.y.resize(size_t(cc));
	l0.z.resize(size_t(cc));
	l0.parent.assign(size_t(cc), -1);
	l0.flags.assign(size_t(cc), 0u);
	for (int c = 0; c < cc; c++) {
		const int d = int(levels[c]);
		const int b = cell_base[c];
		l0.depth[size_t(c)] = d;
		l0.x[size_t(c)] = ((b % nx) << d) + cell_local[c * 3];
		l0.y[size_t(c)] = (((b / nx) % ny) << d) + cell_local[c * 3 + 1];
		l0.z[size_t(c)] = ((b / (nx * ny)) << d) + cell_local[c * 3 + 2];
	}

	for (int L = 1; L < n_levels; L++) {
		Level &pv = lv[size_t(L - 1)];
		Level &cv = lv[size_t(L)];
		cv.base = pv.base + pv.count;
		const int target = max_level - L;
		std::unordered_map<uint64_t, int> seen;
		seen.reserve(size_t(pv.count));
		std::vector<int> parent_local(size_t(pv.count), 0);
		for (int i = 0; i < pv.count; i++) {
			const int d = pv.depth[size_t(i)];
			const bool pass = d <= target;
			const int pd = pass ? d : d - 1;
			const int px = pass ? pv.x[size_t(i)] : (pv.x[size_t(i)] >> 1);
			const int py = pass ? pv.y[size_t(i)] : (pv.y[size_t(i)] >> 1);
			const int pz = pass ? pv.z[size_t(i)] : (pv.z[size_t(i)] >> 1);
			const uint64_t k = key_of(pd, px, py, pz);
			std::unordered_map<uint64_t, int>::iterator it = seen.find(k);
			int j;
			if (it == seen.end()) {
				j = cv.count++;
				seen.insert(std::make_pair(k, j));
				cv.depth.push_back(pd);
				cv.x.push_back(px);
				cv.y.push_back(py);
				cv.z.push_back(pz);
			} else {
				j = it->second;
			}
			parent_local[size_t(i)] = j;
			pv.parent[size_t(i)] = cv.base + j;
			const uint32_t oct = uint32_t((pv.x[size_t(i)] & 1) | ((pv.y[size_t(i)] & 1) << 1)
					| ((pv.z[size_t(i)] & 1) << 2));
			pv.flags[size_t(i)] |= pass ? FLAG_PASS : (oct << OCTANT_SHIFT);
		}
		cv.parent.assign(size_t(cv.count), -1);
		cv.flags.assign(size_t(cv.count), 0u);
		cv.child_off.assign(size_t(cv.count) + 1, 0);
		for (int i = 0; i < pv.count; i++) {
			cv.child_off[size_t(parent_local[size_t(i)]) + 1]++;
		}
		for (int j = 0; j < cv.count; j++) {
			cv.child_off[size_t(j) + 1] += cv.child_off[size_t(j)];
		}
		cv.child_idx.assign(size_t(pv.count), 0);
		{
			std::vector<int> at(cv.child_off.begin(), cv.child_off.end() - 1);
			for (int i = 0; i < pv.count; i++) {
				cv.child_idx[size_t(at[size_t(parent_local[size_t(i)])]++)] = i;
			}
		}

		const int *poff = L == 1 ? slot_off.ptr() : pv.off.data();
		const int *pnbr = L == 1 ? neighbours.ptr() : pv.nbr.data();
		cv.off.assign(size_t(cv.count) * 7, 0);
		for (int a = 0; a < cv.count; a++) {
			for (int d = 0; d < 6; d++) {
				cv.off[size_t(a) * 7 + size_t(d)] = int(cv.nbr.size());
				for (int k = cv.child_off[size_t(a)]; k < cv.child_off[size_t(a) + 1]; k++) {
					const int c = cv.child_idx[size_t(k)];
					for (int f = poff[c * 7 + d]; f < poff[c * 7 + d + 1]; f++) {
						const int b = pnbr[f];
						const int j = b < 0 ? -1 : parent_local[size_t(b - pv.base)];
						if (j == a) {
							continue;
						}
						const int flat = j < 0 ? -1 : cv.base + j;
						bool dup = false;
						for (size_t q = size_t(cv.off[size_t(a) * 7 + size_t(d)]); q < cv.nbr.size(); q++) {
							if (cv.nbr[q] == flat) {
								dup = true;
								break;
							}
						}
						if (!dup) {
							cv.nbr.push_back(flat);
						}
					}
				}
			}
			cv.off[size_t(a) * 7 + 6] = int(cv.nbr.size());
		}
	}

	// The ring is the cell that touches the outside of the box, at every level; the four colours are
	// the parity of a cell's own coordinates and the parity of its depth, which no face joins.
	const int bias = agglomerations;
	for (int L = 0; L < n_levels; L++) {
		Level &c = lv[size_t(L)];
		const int *coff = L == 0 ? slot_off.ptr() : c.off.data();
		const int *cnbr = L == 0 ? neighbours.ptr() : c.nbr.data();
		for (int i = 0; i < c.count; i++) {
			bool ring = false;
			for (int f = coff[i * 7]; f < coff[i * 7 + 6]; f++) {
				if (cnbr[f] < 0) {
					ring = true;
					break;
				}
			}
			const uint32_t dbits = uint32_t(c.depth[size_t(i)] + bias);
			const uint32_t colour = ((dbits & 1u) << 1)
					| uint32_t((c.x[size_t(i)] + c.y[size_t(i)] + c.z[size_t(i)]) & 1);
			c.flags[size_t(i)] |= (ring ? FLAG_RING : 0u) | (colour << COLOUR_SHIFT)
					| (dbits << DEPTH_SHIFT);
		}
	}

	int total = 0;
	int coarse_faces = 0;
	PackedInt32Array level_off;
	level_off.resize(n_levels + 1);
	for (int L = 0; L < n_levels; L++) {
		level_off.set(L, total);
		total += lv[size_t(L)].count;
		if (L > 0) {
			coarse_faces += int(lv[size_t(L)].nbr.size());
		}
	}
	level_off.set(n_levels, total);

	PackedInt32Array mg_off, mg_nbr, mg_flags, mg_parent, mg_child_off, mg_child_idx;
	mg_off.resize((total - cc) * 7);
	mg_nbr.resize(coarse_faces);
	mg_flags.resize(total);
	mg_parent.resize(total);
	mg_child_off.resize(total + 1);
	mg_child_idx.resize(total - lv[size_t(n_levels - 1)].count);
	int face_at = 0;
	int kid_at = 0;
	for (int L = 0; L < n_levels; L++) {
		const Level &c = lv[size_t(L)];
		for (int i = 0; i < c.count; i++) {
			const int flat = c.base + i;
			mg_flags.set(flat, int(c.flags[size_t(i)]));
			mg_parent.set(flat, c.parent[size_t(i)]);
			mg_child_off.set(flat, kid_at);
			if (L > 0) {
				for (int d = 0; d < 7; d++) {
					mg_off.set((flat - cc) * 7 + d, c.off[size_t(i) * 7 + size_t(d)] + face_at);
				}
				for (int k = c.child_off[size_t(i)]; k < c.child_off[size_t(i) + 1]; k++) {
					mg_child_idx.set(kid_at++, lv[size_t(L - 1)].base + c.child_idx[size_t(k)]);
				}
			}
		}
		if (L > 0) {
			for (size_t f = 0; f < c.nbr.size(); f++) {
				mg_nbr.set(face_at + int(f), c.nbr[f]);
			}
			face_at += int(c.nbr.size());
		}
	}
	mg_child_off.set(total, kid_at);

	out["total"] = total;
	out["levels"] = n_levels;
	out["level_off"] = level_off;
	out["coarse_edge"] = cell_size * std::pow(2.0, double(agglomerations));
	out["slot_off"] = mg_off;
	out["nbr"] = mg_nbr;
	out["flags"] = mg_flags;
	out["parent"] = mg_parent;
	out["child_off"] = mg_child_off;
	out["child_idx"] = mg_child_idx;
	return out;
}

// The slots gravity_multigrid.glsl declares, in Bindings.gd's own numbering. The driver's own buffers
// come by name out of the pass's dictionary; the hierarchy's are made here.
const char *const SHARED[] = { "nbr", "pos", "slot_off", "face_partner", "grav_phi", "grav_density",
	"grav_moments", "grav_partials", nullptr };
const int SHARED_BIND[] = { LA_BIND_NBR, LA_BIND_POS, LA_BIND_SLOT_OFF, LA_BIND_FACE_PARTNER,
	LA_BIND_GRAV_PHI, LA_BIND_GRAV_DENSITY, LA_BIND_GRAV_MOMENTS, LA_BIND_GRAV_PARTIALS };
const char *const TABLE[] = { "slot_off", "nbr", "flags", "parent", "child_off", "child_idx", nullptr };
const int TABLE_BIND[] = { LA_BIND_MG_SLOT_OFF, LA_BIND_MG_NBR, LA_BIND_MG_FLAGS, LA_BIND_MG_PARENT,
	LA_BIND_MG_CHILD_OFF, LA_BIND_MG_CHILD_IDX };
const int FIELD_BIND[] = { LA_BIND_MG_PHI, LA_BIND_MG_RHS, LA_BIND_MG_RES };

void bind_at(TypedArray<RDUniform> &p_set, int p_binding, const RID &p_rid) {
	Ref<RDUniform> u;
	u.instantiate();
	u->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	u->set_binding(p_binding);
	u->add_id(p_rid);
	p_set.push_back(u);
}

} // namespace

bool LAGravityMultigrid::attach(RenderingDevice *p_rd, const RID &p_shader, Object *p_grid,
		const Dictionary &p_bufs) {
	if (set_.is_valid()) {
		return true;
	}
	ERR_FAIL_NULL_V(p_rd, false);
	const Dictionary hier = build_hierarchy(p_grid);
	if (hier.is_empty()) {
		return false;
	}
	level_off_ = hier["level_off"];
	levels_ = int(hier["levels"]);
	coarse_edge_ = double(hier["coarse_edge"]);
	moments_ = p_bufs.get("grav_moments", RID());
	TypedArray<RDUniform> uniforms;
	for (int i = 0; SHARED[i] != nullptr; ++i) {
		const RID r = p_bufs.get(String(SHARED[i]), RID());
		if (!r.is_valid()) {
			ERR_FAIL_V_MSG(false, String("LAGravityMultigrid: the field has no \"") + SHARED[i]
					+ "\" buffer, so the V-cycle would read memory nobody wrote.");
		}
		bind_at(uniforms, SHARED_BIND[i], r);
	}
	for (int i = 0; TABLE[i] != nullptr; ++i) {
		const PackedInt32Array a = hier[TABLE[i]];
		const PackedByteArray bytes = a.to_byte_array();
		const RID r = p_rd->storage_buffer_create(uint32_t(bytes.size()), bytes);
		owned_.push_back(r);
		bind_at(uniforms, TABLE_BIND[i], r);
	}
	PackedFloat32Array zeros;
	zeros.resize(int(hier["total"]));
	const PackedByteArray zbytes = zeros.to_byte_array();
	for (int i = 0; i < 3; ++i) {
		const RID r = p_rd->storage_buffer_create(uint32_t(zbytes.size()), zbytes);
		owned_.push_back(r);
		bind_at(uniforms, FIELD_BIND[i], r);
	}
	set_ = p_rd->uniform_set_create(uniforms, p_shader, 0);
	return set_.is_valid();
}

Dictionary LAGravityMultigrid::solve(RenderingDevice *p_rd, Object *p_pass, const RID &p_pipe, int p_cc,
		int p_groups, double p_g_si, double p_tol_rel, int p_max_cycles) {
	Dictionary out;
	ERR_FAIL_NULL_V(p_rd, out);
	ERR_FAIL_NULL_V(p_pass, out);
	Dictionary ctx;
	for (int phase = 0; phase < 2; ++phase) {
		if (phase == 1) {
			out = cycle(p_rd, p_pipe, p_g_si, p_tol_rel, p_max_cycles);
		}
		ctx["gravity_solve"] = phase == 0 ? String("pre") : String("post");
		const int64_t cl = p_rd->compute_list_begin();
		p_pass->call("dispatch", p_rd, cl, ctx, p_cc, p_groups);
		p_rd->compute_list_end();
		p_rd->submit();
		p_rd->sync();
	}
	return out;
}

void LAGravityMultigrid::dispose(RenderingDevice *p_rd) {
	if (p_rd == nullptr) {
		return;
	}
	if (set_.is_valid()) {
		p_rd->free_rid(set_);
		set_ = RID();
	}
	for (size_t i = 0; i < owned_.size(); ++i) {
		p_rd->free_rid(owned_[i]);
	}
	owned_.clear();
}

Dictionary LAGravityMultigrid::cycle(RenderingDevice *p_rd, const RID &p_pipe, double p_g_si,
		double p_tol_rel, int p_max_cycles) {
	Dictionary out;
	const PackedInt32Array level_off = level_off_;
	const int n_levels = levels_;
	const RID p_uset = set_;
	const RID p_moments = moments_;
	const double p_coarse_edge = coarse_edge_;
	if (n_levels <= 0 || level_off.size() < n_levels + 1 || !p_pipe.is_valid() || !p_uset.is_valid()) {
		return out;
	}
	const int cc = level_off[1];
	const uint32_t groups0 = groups_for(cc);
	PackedByteArray pc;
	pc.resize(32);

	int64_t cl = 0;
	auto dispatch = [&](uint32_t mode, int level, uint32_t colour) {
		const uint32_t base = uint32_t(level_off[level]);
		const uint32_t count = uint32_t(level_off[level + 1] - level_off[level]);
		uint8_t *w = pc.ptrw();
		put_u32(w, 0, uint32_t(cc));
		put_u32(w, 4, base);
		put_u32(w, 8, count);
		put_u32(w, 12, mode);
		put_u32(w, 16, colour);
		put_u32(w, 20, groups0);
		put_f32(w, 24, float(p_g_si));
		put_f32(w, 28, float(p_coarse_edge));
		p_rd->compute_list_set_push_constant(cl, pc, uint32_t(pc.size()));
		p_rd->compute_list_dispatch(cl, mode == MODE_NORM_FOLD ? 1u : groups_for(int(count)), 1, 1);
		p_rd->compute_list_add_barrier(cl);
	};
	auto smooth = [&](int level, int sweeps) {
		for (int s = 0; s < sweeps; s++) {
			for (uint32_t colour = 0u; colour < COLOURS; colour++) {
				dispatch(MODE_SMOOTH, level, colour);
			}
		}
	};
	auto measure = [&]() {
		dispatch(MODE_RESIDUAL, 0, 0u);
		dispatch(MODE_NORM, 0, 0u);
		dispatch(MODE_NORM_FOLD, 0, 0u);
	};
	auto begin = [&]() {
		cl = p_rd->compute_list_begin();
		p_rd->compute_list_bind_compute_pipeline(cl, p_pipe);
		p_rd->compute_list_bind_uniform_set(cl, p_uset, 0);
	};
	auto finish = [&]() {
		p_rd->compute_list_end();
		p_rd->submit();
		p_rd->sync();
	};
	auto residual = [&]() {
		const PackedFloat32Array m = p_rd->buffer_get_data(p_moments, 20, 4).to_float32_array();
		return m.size() > 0 ? double(m[0]) : INFINITY;
	};

	begin();
	dispatch(MODE_LOAD, 0, 0u);
	measure();
	finish();
	const double first = residual();
	double rel = first;
	int cycles = 0;
	while (rel > p_tol_rel && cycles < p_max_cycles && std::isfinite(rel)) {
		begin();
		for (int L = 0; L < n_levels - 1; L++) {
			smooth(L, NU_PRE);
			dispatch(MODE_RESIDUAL, L, 0u);
			dispatch(MODE_RESTRICT, L + 1, 0u);
		}
		smooth(n_levels - 1, NU_COARSE);
		for (int L = n_levels - 2; L >= 0; L--) {
			dispatch(MODE_PROLONG, L, 0u);
			smooth(L, NU_POST);
		}
		measure();
		finish();
		rel = residual();
		cycles++;
	}
	begin();
	dispatch(MODE_STORE, 0, 0u);
	finish();

	out["residual_rel"] = rel;
	out["cycles"] = cycles;
	out["factor"] = cycles > 0 && first > 0.0 ? std::pow(rel / first, 1.0 / double(cycles)) : 1.0;
	return out;
}

void LAGravityMultigrid::_bind_methods() {
	ClassDB::bind_method(D_METHOD("attach", "rd", "shader", "grid", "bufs"),
			&LAGravityMultigrid::attach);
	ClassDB::bind_method(
			D_METHOD("solve", "rd", "pass", "pipe", "cc", "groups", "g_si", "tol_rel", "max_cycles"),
			&LAGravityMultigrid::solve);
	ClassDB::bind_method(D_METHOD("dispose", "rd"), &LAGravityMultigrid::dispose);
}
