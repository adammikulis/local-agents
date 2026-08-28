#include "LAFieldDriver.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <cmath>
#include <cstring>
#include <limits>

using namespace godot;

namespace {

RID rid_at(const Array &a, int i) {
	if (i < 0 || i >= a.size()) {
		return RID();
	}
	const RID r = a[i];
	return r;
}

int plan_int(const Dictionary &d, const char *key, int fallback) {
	const int64_t v = d.get(key, fallback);
	return (int)v;
}

RID plan_rid(const Dictionary &d, const char *key) {
	const RID r = d.get(key, RID());
	return r;
}

// The coarsest level advancing on substep k of a 2^levels axis: level L steps when k is a multiple of
// 2^(levels-L), so the coarsest is levels minus k's trailing zeros.
int coarsest_at(int k, int levels) {
	if (k <= 0) {
		return 0;
	}
	int l = levels;
	while (k > 0 && (k & 1) == 0) {
		k >>= 1;
		--l;
	}
	return l > 0 ? l : 0;
}

void put_u32(uint8_t *w, int off, uint32_t v) {
	std::memcpy(w + off, &v, sizeof(uint32_t));
}

} // namespace

void LAFieldDriver::set_device(RenderingDevice *p_rd) {
	_rd = p_rd;
}

void LAFieldDriver::clear_buffers(const Array &p_bufs, int p_bytes) {
	if (_rd == nullptr || p_bytes <= 0) {
		return;
	}
	bool any = false;
	for (int i = 0; i < p_bufs.size(); ++i) {
		const RID r = rid_at(p_bufs, i);
		if (r.is_valid()) {
			_rd->buffer_clear(r, 0, (uint32_t)p_bytes);
			any = true;
		}
	}
	// A clear outside a list is not ordered ahead of the lists submitted after it: the device ran it
	// mid-step and wiped most of a step's books. Its own submit puts it before anything that follows.
	if (any) {
		_rd->submit();
		_rd->sync();
	}
}

void LAFieldDriver::run(int64_t p_cl, const RID &p_pipe, const Array &p_usets, const Array &p_pcs,
		const PackedInt32Array &p_workgroups, const Array &p_args, const PackedInt32Array &p_offsets,
		bool p_barrier) {
	if (_rd == nullptr || !p_pipe.is_valid() || p_pcs.is_empty()) {
		return;
	}
	const bool one_set = p_usets.size() == 1;
	_rd->compute_list_bind_compute_pipeline(p_cl, p_pipe);
	if (one_set) {
		const RID s = rid_at(p_usets, 0);
		if (!s.is_valid()) {
			return;
		}
		_rd->compute_list_bind_uniform_set(p_cl, s, 0);
	}
	for (int i = 0; i < p_pcs.size(); ++i) {
		if (!one_set) {
			const RID s = rid_at(p_usets, i);
			if (!s.is_valid()) {
				continue;
			}
			_rd->compute_list_bind_uniform_set(p_cl, s, 0);
		}
		const PackedByteArray pc = p_pcs[i];
		_rd->compute_list_set_push_constant(p_cl, pc, pc.size());
		const RID args = rid_at(p_args, i);
		if (args.is_valid()) {
			_rd->compute_list_dispatch_indirect(p_cl, args,
					(uint32_t)(i < p_offsets.size() ? p_offsets[i] : 0));
		} else {
			_rd->compute_list_dispatch(p_cl,
					(uint32_t)(i < p_workgroups.size() ? p_workgroups[i] : 0), 1, 1);
		}
		if (p_barrier) {
			_rd->compute_list_add_barrier(p_cl);
		}
	}
}

void LAFieldDriver::step(const Array &p_passes, const PackedStringArray &p_names,
		const Dictionary &p_ctx, int p_cc, int p_groups, const Callable &p_probe) {
	if (_rd == nullptr) {
		return;
	}
	const bool probed = p_probe.is_valid();
	if (probed) {
		p_probe.call(-1, String("start"));
	} else {
		_rd->capture_timestamp("field_start");
	}
	for (int i = 0; i < p_passes.size(); ++i) {
		Object *p = p_passes[i];
		if (p == nullptr) {
			continue;
		}
		const int64_t cl = _rd->compute_list_begin();
		p->call("dispatch", _rd, cl, p_ctx, p_cc, p_groups);
		// EVERY PASS READS WHAT THE PREVIOUS ONE WROTE, and one submit does not order them against
		// each other. The probed path submits between passes, which orders them already.
		if (!probed) {
			_rd->compute_list_add_barrier(cl);
		}
		_rd->compute_list_end();
		if (probed) {
			_rd->submit();
			_rd->sync();
			p_probe.call(i, i < p_names.size() ? p_names[i] : String());
		} else {
			_rd->capture_timestamp(i < p_names.size() ? p_names[i] : String());
		}
	}
	if (probed) {
		// Leave an in-flight submit so the drain's contract is unchanged. An empty list is a legal no-op.
		const int64_t tail = _rd->compute_list_begin();
		_rd->compute_list_end();
		(void)tail;
	}
	_rd->submit();
}

void LAFieldDriver::setup_transport(const Dictionary &p_plan) {
	_pipe = plan_rid(p_plan, "pipe");
	_row_sets = p_plan.get("row_sets", Array());
	_row_group = p_plan.get("row_group", PackedInt32Array());
	_row_radiate = p_plan.get("row_radiate", PackedInt32Array());
	_groups = p_plan.get("groups", Array());
	_args = plan_rid(p_plan, "args");
	_wake_args = plan_rid(p_plan, "wake_args");
	_grain_set = plan_rid(p_plan, "grain_set");
	_list_sets = p_plan.get("list_sets", Array());
	_queue_bin = plan_int(p_plan, "queue_bin", 0);
	_slots = plan_int(p_plan, "slots", 0);
	_group_count = plan_int(p_plan, "group_count", 1);
	_flush_every = plan_int(p_plan, "flush_every", 4096);
	_level_off = plan_int(p_plan, "level_off", 0);
	_k_off = plan_int(p_plan, "k_off", 0);
	_n_off = plan_int(p_plan, "n_off", 0);
}

int LAFieldDriver::_args_offset(int p_group, int p_bin) const {
	return (p_group * (_queue_bin + 1) + p_bin) * _slots * 4;
}

const PackedByteArray &LAFieldDriver::_block(const Array &p_table, int p_slot, int p_level, int p_k,
		int p_n) {
	if (p_slot < 0 || p_slot >= p_table.size()) {
		_scratch.resize(0);
		return _scratch;
	}
	const PackedByteArray src = p_table[p_slot];
	if (src.is_empty()) {
		_scratch.resize(0);
		return _scratch;
	}
	if (_scratch.size() != src.size()) {
		_scratch.resize(src.size());
	}
	uint8_t *w = _scratch.ptrw();
	std::memcpy(w, src.ptr(), (size_t)src.size());
	const int room = src.size() - 4;
	if (_level_off <= room && _k_off <= room && _n_off <= room) {
		put_u32(w, _level_off, (uint32_t)p_level);
		put_u32(w, _k_off, (uint32_t)p_k);
		put_u32(w, _n_off, (uint32_t)p_n);
	}
	return _scratch;
}

void LAFieldDriver::_fire_on(int64_t p_cl, const RID &p_pipe, const RID &p_uset,
		const PackedByteArray &p_pc, const RID &p_args, int p_offset) {
	if (!p_pipe.is_valid() || !p_uset.is_valid() || p_pc.is_empty()) {
		return;
	}
	_rd->compute_list_bind_compute_pipeline(p_cl, p_pipe);
	_rd->compute_list_bind_uniform_set(p_cl, p_uset, 0);
	_rd->compute_list_set_push_constant(p_cl, p_pc, p_pc.size());
	if (p_args.is_valid()) {
		_rd->compute_list_dispatch_indirect(p_cl, p_args, (uint32_t)p_offset);
	} else {
		_rd->compute_list_dispatch(p_cl, (uint32_t)p_offset, 1, 1);
	}
	_rd->compute_list_add_barrier(p_cl);
}

void LAFieldDriver::_fire(int64_t p_cl, const RID &p_uset, const PackedByteArray &p_pc,
		const RID &p_args, int p_offset) {
	_fire_on(p_cl, _pipe, p_uset, p_pc, p_args, p_offset);
}

// THE MATTER THIS SUBSTEP MOVED IS AT A NEW PRESSURE. The derive's own kernel says what pressure, over
// the same cells the substep walked, before the next substep's faces read one.
void LAFieldDriver::_restate(int64_t p_cl, int p_group, int p_level) {
	if (!_eos_pipe.is_valid() || !_eos_set.is_valid() || _eos_pc.is_empty()) {
		return;
	}
	const int offset = _args_offset(p_group, p_level);
	uint8_t *w = _eos_pc.ptrw();
	put_u32(w, _eos_slot_off, (uint32_t)(offset / 4));
	put_u32(w, _eos_base_off, (uint32_t)(p_group * _eos_total));
	_fire_on(p_cl, _eos_pipe, _eos_set, _eos_pc, _args, offset);
}

void LAFieldDriver::_act(int64_t p_cl, const RID &p_uset, const Array &p_table, int p_slot,
		int p_group, int p_level, int p_bin) {
	_fire(p_cl, p_uset, _block(p_table, p_slot, p_level, 0, 1), _args, _args_offset(p_group, p_bin));
}

void LAFieldDriver::_rebuild_active(int64_t p_cl, const RID &p_uset, const Array &p_table,
		int p_group, int p_level, bool p_take_wake) {
	_act(p_cl, p_uset, p_table, SLOT_ACT_AGE, p_group, p_level, 0);
	if (p_take_wake) {
		_fire(p_cl, p_uset, _block(p_table, SLOT_ACT_WAKE, p_level, 0, 1), _wake_args, 0);
	}
	_act(p_cl, p_uset, p_table, SLOT_ACT_MARK, p_group, p_level, 0);
	_fire(p_cl, p_uset, _block(p_table, SLOT_LEVEL_SCAN, p_level, 0, 1), RID(), 1);
	_act(p_cl, p_uset, p_table, SLOT_LEVEL_SORT, p_group, p_level, _queue_bin);
}

void LAFieldDriver::build_levels(int64_t p_cl, int p_group, const Array &p_pc_rows, int p_levels) {
	if (_rd == nullptr || p_group < 0 || p_group >= _groups.size()) {
		return;
	}
	const PackedInt32Array group = _groups[p_group];
	if (group.is_empty()) {
		return;
	}
	const int first = group[0];
	const RID head = rid_at(_row_sets, first);
	const Array head_pc = p_pc_rows[first];
	_act(p_cl, head, head_pc, SLOT_LEVEL_RESET, p_group, 0, 0);
	if (p_levels <= 0) {
		return;
	}
	for (int i = 0; i < group.size(); ++i) {
		const int gi = group[i];
		_act(p_cl, rid_at(_row_sets, gi), p_pc_rows[gi], SLOT_LEVEL_SEED, p_group, 0, 0);
	}
	// The fixed point of "no neighbour is more than one level finer" is `levels` sweeps away at most.
	for (int i = 0; i < p_levels; ++i) {
		_act(p_cl, head, head_pc, SLOT_LEVEL_RELAX, p_group, 0, 0);
	}
}

// ONE SLOT OF ONE RECORD, over its group's active cells at this level: what it costs is what moves.
void LAFieldDriver::_run_slot(int64_t p_cl, int p_row, const Array &p_pc_rows, int p_slot,
		int p_level, int p_k, int p_n) {
	const RID uset = rid_at(_row_sets, p_row);
	if (!uset.is_valid() || !_args.is_valid()) {
		return;
	}
	const PackedByteArray &pc = _block(p_pc_rows[p_row], p_slot, p_level, p_k, p_n);
	if (pc.is_empty()) {
		return;
	}
	const int group = p_row < _row_group.size() ? _row_group[p_row] : 0;
	_rd->compute_list_bind_compute_pipeline(p_cl, _pipe);
	_rd->compute_list_bind_uniform_set(p_cl, uset, 0);
	_rd->compute_list_set_push_constant(p_cl, pc, pc.size());
	_rd->compute_list_dispatch_indirect(p_cl, _args, (uint32_t)_args_offset(group, p_level));
	_rd->compute_list_add_barrier(p_cl);
}

// THE FLUX AND THE APPLY: the record writes what crosses each of its cells' own faces, then reads
// those faces back into the cells. Nothing between the two touches them.
void LAFieldDriver::_run_row(int64_t p_cl, int p_row, const Array &p_pc_rows, int p_level, int p_k,
		int p_n) {
	_run_slot(p_cl, p_row, p_pc_rows, SLOT_OUTFLOW, p_level, p_k, p_n);
	_run_slot(p_cl, p_row, p_pc_rows, SLOT_GATHER, p_level, p_k, p_n);
	if (p_row < _row_radiate.size() && _row_radiate[p_row] != 0) {
		_run_slot(p_cl, p_row, p_pc_rows, SLOT_SW, p_level, p_k, p_n);
	}
}

int64_t LAFieldDriver::_flush(int64_t p_cl) {
	_rd->compute_list_end();
	_rd->submit();
	_rd->sync();
	_recorded = 0;
	(void)p_cl;
	return _rd->compute_list_begin();
}

int64_t LAFieldDriver::run_transport(int64_t p_cl, const PackedInt32Array &p_peaks,
		const Array &p_pc_rows, const Array &p_pc_grain, const Array &p_pc_lists,
		int p_seed_workgroups, int p_list_workgroups, const Dictionary &p_restate) {
	if (_rd == nullptr || !_pipe.is_valid()) {
		return p_cl;
	}
	_eos_pipe = plan_rid(p_restate, "pipe");
	_eos_set = plan_rid(p_restate, "set");
	_eos_pc = p_restate.get("pc", PackedByteArray());
	_eos_total = plan_int(p_restate, "total", 0);
	// THE RESTATE'S OWN THREE WORDS ARE THE TAIL of the derive's block: the flag that says this solve is
	// the substep's, the level-args slot it walks, and where its group's sorted list starts.
	const int n = _eos_pc.size();
	if (n < 12) {
		_eos_pipe = RID();
	} else {
		put_u32(_eos_pc.ptrw(), n - 12, 1u);
		_eos_slot_off = n - 8;
		_eos_base_off = n - 4;
	}
	int64_t cl = p_cl;
	_recorded = 0;
	// THE LISTS, before anything reads one: every cell of a world nobody has stepped yet.
	if (p_seed_workgroups > 0) {
		_fire(cl, _grain_set, _block(p_pc_grain, SLOT_ACT_SEED, 0, 0, 1), RID(), p_seed_workgroups);
	}
	// THE DETECTOR LISTS: a detector looks everywhere, because a value it has never seen can sit anywhere.
	for (int r = 0; r < _list_sets.size(); ++r) {
		const RID lset = rid_at(_list_sets, r);
		if (!lset.is_valid()) {
			continue;
		}
		const Array table = p_pc_lists[r];
		const int slots[3] = { SLOT_LIST_RESET, SLOT_LIST_APPEND, SLOT_LIST_ARGS };
		const int wgs[3] = { 1, p_list_workgroups, 1 };
		_rd->compute_list_bind_compute_pipeline(cl, _pipe);
		_rd->compute_list_bind_uniform_set(cl, lset, 0);
		for (int i = 0; i < 3; ++i) {
			const PackedByteArray &pc = _block(table, slots[i], 0, 0, 1);
			if (pc.is_empty()) {
				continue;
			}
			_rd->compute_list_set_push_constant(cl, pc, pc.size());
			_rd->compute_list_dispatch(cl, (uint32_t)wgs[i], 1, 1);
			_rd->compute_list_add_barrier(cl);
		}
	}
	// PROLOGUE: the suspension shares its silicate rows before anything donates.
	if (_grain_set.is_valid()) {
		const int gslot = _group_count - 1;
		_act(cl, _grain_set, p_pc_grain, SLOT_LEVEL_RESET, gslot, 0, 0);
		_rebuild_active(cl, _grain_set, p_pc_grain, gslot, 0, true);
		_act(cl, _grain_set, p_pc_grain, SLOT_GRAIN, gslot, 0, 0);
	}
	// EACH GROUP ON ITS OWN TIME AXIS.
	for (int g = 0; g < _groups.size(); ++g) {
		const PackedInt32Array group = _groups[g];
		if (group.is_empty()) {
			continue;
		}
		const int levels = g < p_peaks.size() ? p_peaks[g] : 0;
		if (levels < 0) {
			continue;
		}
		build_levels(cl, g, p_pc_rows, levels);
		const int n = 1 << levels;
		const int last = group[group.size() - 1];
		const int first = group[0];
		const RID head = rid_at(_row_sets, first);
		const Array head_pc = p_pc_rows[first];
		for (int k = 0; k < n; ++k) {
			const int lk = coarsest_at(k, levels);
			// THE BUBBLE, one substep at a time.
			_rebuild_active(cl, head, head_pc, g, lk, k == 0);
			// EVERY FACE STATES ITSELF ONCE, before any record reads one: the pair's interface
			// pressure and velocity, off the state this substep starts in.
			_run_slot(cl, first, p_pc_rows, SLOT_FACE, lk, k, n);
			// THE PRESSURE AND THE BODY IMPULSE NEXT, on the mass the faces were solved over, so what
			// the records then move carries its share of the momentum and leaves none behind.
			_run_slot(cl, last, p_pc_rows, SLOT_MOMENTUM, lk, k, n);
			for (int i = 0; i < group.size(); ++i) {
				_run_row(cl, group[i], p_pc_rows, lk, k, n);
				// THE COARSEST SUBSTEP WALKS EVERY CELL: one record of it is the most a submit may hold,
				// because the device's fence wait is finite and a whole-grid substep outran it.
				if (lk == 0) {
					cl = _flush(cl);
				}
			}
			_restate(cl, g, lk);
			_recorded += group.size() + 5;
			if (_recorded > _flush_every) {
				cl = _flush(cl);
			}
		}
	}
	// The wake queue is consumed; what the reactions write after this pass is next step's business.
	if (_grain_set.is_valid()) {
		_fire(cl, _grain_set, _block(p_pc_grain, SLOT_ACT_WAKE_RESET, 0, 0, 1), RID(), 1);
	}
	return cl;
}

Dictionary LAFieldDriver::fold_reduce(const RID &p_partials, const PackedInt32Array &p_folds,
		const PackedStringArray &p_keys, int p_groups) {
	Dictionary out;
	if (_rd == nullptr || !p_partials.is_valid() || p_groups <= 0) {
		return out;
	}
	const PackedByteArray raw = _rd->buffer_get_data(p_partials, 0, 0);
	const int n = raw.size() / 4;
	const float *v = (const float *)raw.ptr();
	const int rows = p_folds.size() < p_keys.size() ? p_folds.size() : p_keys.size();
	for (int r = 0; r < rows; ++r) {
		const int fold = p_folds[r];
		if (fold == FOLD_SKIP) {
			continue;
		}
		const int base = r * p_groups;
		if (base + p_groups > n) {
			continue;
		}
		double acc = fold == FOLD_MIN ? std::numeric_limits<double>::infinity()
									  : (fold == FOLD_MAX ? -std::numeric_limits<double>::infinity() : 0.0);
		for (int g = 0; g < p_groups; ++g) {
			const double x = (double)v[base + g];
			if (fold == FOLD_MIN) {
				acc = x < acc ? x : acc;
			} else if (fold == FOLD_MAX) {
				acc = x > acc ? x : acc;
			} else {
				acc += x;
			}
		}
		// A MIN/MAX lane that kept no cell returns its INFINITE identity, and no cell anywhere means no
		// measurement. An infinity at the other end is a reading: the field went non-finite.
		if (fold == FOLD_MIN && acc == std::numeric_limits<double>::infinity()) {
			continue;
		}
		if (fold == FOLD_MAX && acc == -std::numeric_limits<double>::infinity()) {
			continue;
		}
		out[p_keys[r]] = acc;
	}
	return out;
}

Dictionary LAFieldDriver::gather_read(const RID &p_staging, const Array &p_sources,
		const PackedStringArray &p_names, int p_elements) {
	Dictionary out;
	if (_rd == nullptr || !p_staging.is_valid() || p_elements <= 0) {
		return out;
	}
	const int count = p_sources.size() < p_names.size() ? p_sources.size() : p_names.size();
	if (count <= 0) {
		return out;
	}
	const uint32_t span = (uint32_t)p_elements * 4u;
	for (int i = 0; i < count; ++i) {
		const RID src = rid_at(p_sources, i);
		if (!src.is_valid()) {
			return out;
		}
		_rd->buffer_copy(src, p_staging, 0, (uint32_t)i * span, span);
	}
	// ONE ROUND TRIP. The device copies into one buffer and the CPU reads that buffer once; a readback
	// per channel pays the same wait over again for every one of them.
	const PackedByteArray raw = _rd->buffer_get_data(p_staging, 0, (uint32_t)count * span);
	if (raw.size() < (int64_t)count * (int64_t)span) {
		return out;
	}
	for (int i = 0; i < count; ++i) {
		PackedFloat32Array vals;
		vals.resize(p_elements);
		std::memcpy(vals.ptrw(), raw.ptr() + (int64_t)i * (int64_t)span, (size_t)span);
		out[p_names[i]] = vals;
	}
	return out;
}

void LAFieldDriver::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_device", "rd"), &LAFieldDriver::set_device);
	ClassDB::bind_method(D_METHOD("clear_buffers", "buffers", "bytes"), &LAFieldDriver::clear_buffers);
	ClassDB::bind_method(D_METHOD("run", "compute_list", "pipeline", "uniform_sets", "push_constants",
								  "workgroups", "args", "offsets", "barrier"),
			&LAFieldDriver::run);
	ClassDB::bind_method(D_METHOD("step", "passes", "names", "ctx", "cell_count", "groups", "probe"),
			&LAFieldDriver::step);
	ClassDB::bind_method(D_METHOD("setup_transport", "plan"), &LAFieldDriver::setup_transport);
	ClassDB::bind_method(D_METHOD("run_transport", "compute_list", "peaks", "pc_rows", "pc_grain",
								  "pc_lists", "seed_workgroups", "list_workgroups", "restate"),
			&LAFieldDriver::run_transport);
	ClassDB::bind_method(D_METHOD("build_levels", "compute_list", "group", "pc_rows", "levels"),
			&LAFieldDriver::build_levels);
	ClassDB::bind_method(D_METHOD("fold_reduce", "partials", "folds", "keys", "groups"),
			&LAFieldDriver::fold_reduce);
	ClassDB::bind_method(D_METHOD("gather_read", "staging", "sources", "names", "elements"),
			&LAFieldDriver::gather_read);

	BIND_ENUM_CONSTANT(SLOT_OUTFLOW);
	BIND_ENUM_CONSTANT(SLOT_GATHER);
	BIND_ENUM_CONSTANT(SLOT_SW);
	BIND_ENUM_CONSTANT(SLOT_FACE);
	BIND_ENUM_CONSTANT(SLOT_MOMENTUM);
	BIND_ENUM_CONSTANT(SLOT_ACT_AGE);
	BIND_ENUM_CONSTANT(SLOT_ACT_WAKE);
	BIND_ENUM_CONSTANT(SLOT_ACT_MARK);
	BIND_ENUM_CONSTANT(SLOT_LEVEL_SCAN);
	BIND_ENUM_CONSTANT(SLOT_LEVEL_SORT);
	BIND_ENUM_CONSTANT(SLOT_LEVEL_RESET);
	BIND_ENUM_CONSTANT(SLOT_LEVEL_SEED);
	BIND_ENUM_CONSTANT(SLOT_LEVEL_RELAX);
	BIND_ENUM_CONSTANT(SLOT_GRAIN);
	BIND_ENUM_CONSTANT(SLOT_ACT_SEED);
	BIND_ENUM_CONSTANT(SLOT_ACT_WAKE_RESET);
	BIND_ENUM_CONSTANT(SLOT_LIST_RESET);
	BIND_ENUM_CONSTANT(SLOT_LIST_APPEND);
	BIND_ENUM_CONSTANT(SLOT_LIST_ARGS);
	BIND_ENUM_CONSTANT(SLOT_COUNT);
	BIND_ENUM_CONSTANT(FOLD_SUM);
	BIND_ENUM_CONSTANT(FOLD_MIN);
	BIND_ENUM_CONSTANT(FOLD_MAX);
	BIND_ENUM_CONSTANT(FOLD_SKIP);
}
