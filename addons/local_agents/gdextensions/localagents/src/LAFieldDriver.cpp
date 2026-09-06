#include "LAAcousticSolve.hpp"
#include "LAFieldDriver.hpp"

#include "LAProcessSet.hpp"

#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <algorithm>
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

// A pass's own record label: the file its script lives in, which is what the ladder names it by.
static String pass_label(Object *p_pass) {
	const Ref<Script> scr = p_pass->get_script();
	return scr.is_valid() ? scr->get_path().get_file() : String();
}

static bool pass_live(Object *p_pass) {
	return LAProcessSet::is_active("pass", pass_label(p_pass), LAProcessSet::ANY);
}

void LAFieldDriver::pre_step(const Array &p_passes, const Dictionary &p_ctx, int p_cc, int p_groups) {
	for (int i = 0; i < p_passes.size(); ++i) {
		Object *p = p_passes[i];
		if (p != nullptr && p->has_method("pre_step") && pass_live(p)) {
			p->call("pre_step", _rd, p_ctx, p_cc, p_groups);
		}
	}
}

bool LAFieldDriver::moves_state(const Array &p_passes) const {
	for (int i = 0; i < p_passes.size(); ++i) {
		Object *p = p_passes[i];
		if (p != nullptr && (bool)p->get("MOVES_STATE") && pass_live(p)) {
			return true;
		}
	}
	return LAProcessSet::is_active("derive", "lithify", LAProcessSet::ANY);
}

void LAFieldDriver::step(const Array &p_passes, const PackedStringArray &p_names,
		const Dictionary &p_ctx, int p_cc, int p_groups, const Callable &p_probe) {
	if (_rd == nullptr) {
		return;
	}
	const bool probed = p_probe.is_valid();
	if (probed) {
		p_probe.call(-1, String("start"));
	}
	for (int i = 0; i < p_passes.size(); ++i) {
		Object *p = p_passes[i];
		if (p == nullptr) {
			continue;
		}
		// A PASS OUTSIDE THE SET WAS NEVER LOADED; ONE SWITCHED OFF KEEPS ITS BUFFERS AND DOES NOTHING
		// TO THEM. What it published is no longer true, so it is told once, on the way down.
		const String label = pass_label(p);
		if (!pass_live(p)) {
			if (!_off_last.has(label)) {
				_off_last[label] = true;
				if (p->has_method("switched_off")) {
					p->call("switched_off", _rd);
				}
			}
			continue;
		}
		_off_last.erase(label);
		const int64_t cl = _rd->compute_list_begin();
		p->call("dispatch", _rd, cl, p_ctx, p_cc, p_groups);
		_rd->compute_list_end();
		// ONE PASS IS THE MOST A SUBMIT MAY HOLD: the device's fence wait is finite and a whole step in
		// one submit outran it. A submit per pass also orders each pass after the one before it.
		_rd->submit();
		_rd->sync();
		if (probed) {
			p_probe.call(i, i < p_names.size() ? p_names[i] : String());
		}
	}
	// Leave an in-flight submit so the drain's contract is unchanged. An empty list is a legal no-op.
	const int64_t tail = _rd->compute_list_begin();
	_rd->compute_list_end();
	(void)tail;
	_rd->submit();
}

void LAFieldDriver::setup_transport(const Dictionary &p_plan) {
	_pipe = plan_rid(p_plan, "pipe");
	_row_sets = p_plan.get("row_sets", Array());
	_row_group = p_plan.get("row_group", PackedInt32Array());
	_row_radiate = p_plan.get("row_radiate", PackedInt32Array());
	_rows = p_plan.get("rows", Array());
	_groups = p_plan.get("groups", Array());
	_args = plan_rid(p_plan, "args");
	_wake_args = plan_rid(p_plan, "wake_args");
	_grain_set = plan_rid(p_plan, "grain_set");
	_list_sets = p_plan.get("list_sets", Array());
	_hz_pipe = plan_rid(p_plan, "hz_pipe");
	_hz_set = plan_rid(p_plan, "hz_set");
	_hz_comp = plan_rid(p_plan, "hz_comp");
	_hz_cond = plan_rid(p_plan, "hz_cond");
	_hz_rhs = plan_rid(p_plan, "hz_rhs");
	_hz_flux = plan_rid(p_plan, "hz_flux");
	_hz_p = plan_rid(p_plan, "hz_p");
	_slot_off = plan_rid(p_plan, "slot_off");
	_nbr = plan_rid(p_plan, "nbr");
	_cc = plan_int(p_plan, "cell_count", 0);
	_hz_cell_bytes = plan_int(p_plan, "hz_cell_bytes", 0);
	_hz_p_bytes = plan_int(p_plan, "hz_p_bytes", 0);
	_hz_face_bytes = plan_int(p_plan, "hz_face_bytes", 0);
	_hz_tol = p_plan.get("hz_tol", 0.0);
	_hz_max_iter = plan_int(p_plan, "hz_max_iter", 0);
	_slots = plan_int(p_plan, "slots", 0);
	_group_count = plan_int(p_plan, "group_count", 1);
	_flush_every = plan_int(p_plan, "flush_every", 4096);
}

// A record with no entry in the mask is live: a plan that declares none is a plan with no switches.
bool LAFieldDriver::_live(int p_row) const {
	return p_row >= _row_live.size() || _row_live[p_row] != 0;
}

// THE SWITCHES AS THEY STAND THIS STEP, read once before anything reads a row.
void LAFieldDriver::_refresh_live() {
	_row_live.resize(_rows.size());
	for (int i = 0; i < _rows.size(); ++i) {
		const Dictionary row = _rows[i];
		_row_live.set(i, LAProcessSet::is_active("transport", row.get("label", String()),
				LAProcessSet::ANY) ? 1 : 0);
	}
}

int LAFieldDriver::_args_offset(int p_group) const {
	return p_group * _slots * 4;
}

const PackedByteArray &LAFieldDriver::_block(const Array &p_table, int p_slot) {
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
	std::memcpy(_scratch.ptrw(), src.ptr(), (size_t)src.size());
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
void LAFieldDriver::_restate(int64_t p_cl, int p_group) {
	if (!_eos_pipe.is_valid() || !_eos_set.is_valid() || _eos_pc.is_empty()) {
		return;
	}
	const int offset = _args_offset(p_group);
	uint8_t *w = _eos_pc.ptrw();
	put_u32(w, _eos_slot_off, (uint32_t)(offset / 4));
	put_u32(w, _eos_base_off, (uint32_t)(p_group * _eos_total));
	_fire_on(p_cl, _eos_pipe, _eos_set, _eos_pc, _args, offset);
}

void LAFieldDriver::_act(int64_t p_cl, const RID &p_uset, const Array &p_table, int p_slot,
		int p_group) {
	_fire(p_cl, p_uset, _block(p_table, p_slot), _args, _args_offset(p_group));
}

void LAFieldDriver::_rebuild_active(int64_t p_cl, const RID &p_uset, const Array &p_table,
		int p_group, bool p_take_wake) {
	_act(p_cl, p_uset, p_table, SLOT_ACT_AGE, p_group);
	if (p_take_wake) {
		_fire(p_cl, p_uset, _block(p_table, SLOT_ACT_WAKE), _wake_args, 0);
	}
	_act(p_cl, p_uset, p_table, SLOT_ACT_MARK, p_group);
	_fire(p_cl, p_uset, _block(p_table, SLOT_SCAN), RID(), 1);
	_act(p_cl, p_uset, p_table, SLOT_COMPACT, p_group);
}

// ONE SLOT OF ONE RECORD, over its group's active cells: what it costs is what moves.
void LAFieldDriver::_run_slot(int64_t p_cl, int p_row, const Array &p_pc_rows, int p_slot) {
	const RID uset = rid_at(_row_sets, p_row);
	if (!uset.is_valid() || !_args.is_valid()) {
		return;
	}
	const PackedByteArray &pc = _block(p_pc_rows[p_row], p_slot);
	if (pc.is_empty()) {
		return;
	}
	const int group = p_row < _row_group.size() ? _row_group[p_row] : 0;
	_rd->compute_list_bind_compute_pipeline(p_cl, _pipe);
	_rd->compute_list_bind_uniform_set(p_cl, uset, 0);
	_rd->compute_list_set_push_constant(p_cl, pc, pc.size());
	_rd->compute_list_dispatch_indirect(p_cl, _args, (uint32_t)_args_offset(group));
	_rd->compute_list_add_barrier(p_cl);
}

// THE FLUX AND THE APPLY: the record writes what crosses each of its cells' own faces, then reads
// those faces back into the cells. Nothing between the two touches them.
void LAFieldDriver::_run_row(int64_t p_cl, int p_row, const Array &p_pc_rows) {
	if (!_live(p_row)) {
		return;
	}
	_run_slot(p_cl, p_row, p_pc_rows, SLOT_OUTFLOW);
	_run_slot(p_cl, p_row, p_pc_rows, SLOT_GATHER);
	if (p_row < _row_radiate.size() && _row_radiate[p_row] != 0) {
		_run_slot(p_cl, p_row, p_pc_rows, SLOT_SW);
	}
}

// THE STEP'S ACOUSTIC PRESSURE, between the face predictor and the momentum close, with no compute
// list recording: the extension converges the assembled Helmholtz and writes it back to the device.
void LAFieldDriver::_solve_acoustic() {
	_hz_residual = 0.0;
	_hz_iterations = 0;
	if (_rd == nullptr || _cc <= 0 || !_hz_p.is_valid() || !_slot_off.is_valid()) {
		return;
	}
	const Dictionary r = LAAcousticSolve::solve_device(_rd, _slot_off, _nbr, _cc, _hz_comp, _hz_cond,
			_hz_rhs, _hz_p, _hz_dt_s, _hz_tol, _hz_max_iter);
	if (!r.has("residual_rel")) {
		_hz_nonfinite = r.has("nonfinite_cell") ? (int)(int64_t)r["nonfinite_cell"] : -1;
		return;
	}
	_hz_nonfinite = -1;
	_hz_residual = r["residual_rel"];
	_hz_iterations = (int)(int64_t)r["iterations"];
}

double LAFieldDriver::step_seconds(const RID &p_dt_buf, const Array &p_pc_rows,
		const Array &p_pc_grain, int p_seed_workgroups) {
	const int n = _groups.size();
	if (_rd == nullptr || !_pipe.is_valid() || !p_dt_buf.is_valid() || n <= 0) {
		return std::numeric_limits<double>::infinity();
	}
	_refresh_live();
	PackedByteArray unbounded;      // +INF: no cell has asked yet
	unbounded.resize(n * 4);
	for (int i = 0; i < n; ++i) {
		put_u32(unbounded.ptrw(), i * 4, 0x7f800000u);
	}
	_rd->buffer_update(p_dt_buf, 0, n * 4, unbounded);
	// THE ACOUSTIC ROW IS THIS STEP'S. A cell outside the bubble is written by no predictor, so what
	// it held last step would otherwise stand in the operator as a row nobody assembled.
	if (_hz_cell_bytes > 0) {
		_rd->buffer_clear(_hz_comp, 0, (uint32_t)_hz_cell_bytes);
		_rd->buffer_clear(_hz_rhs, 0, (uint32_t)_hz_cell_bytes);
		_rd->buffer_clear(_hz_p, 0, (uint32_t)_hz_p_bytes);
		_rd->buffer_clear(_hz_cond, 0, (uint32_t)_hz_face_bytes);
		_rd->buffer_clear(_hz_flux, 0, (uint32_t)_hz_face_bytes);
	}
	int64_t cl = _rd->compute_list_begin();
	if (p_seed_workgroups > 0) {
		_fire(cl, _grain_set, _block(p_pc_grain, SLOT_ACT_SEED), RID(), p_seed_workgroups);
	}
	for (int g = 0; g < n; ++g) {
		const PackedInt32Array group = _groups[g];
		for (int i = 0; i < group.size(); ++i) {
			// A ROW THAT IS SWITCHED OFF MOVES NOTHING, so it constrains no step.
			if (_live(group[i])) {
				_run_slot(cl, group[i], p_pc_rows, SLOT_STEP_DT);
			}
		}
	}
	_rd->compute_list_end();
	_rd->submit();
	_rd->sync();
	const PackedByteArray asked = _rd->buffer_get_data(p_dt_buf, 0, n * 4);
	double dt = std::numeric_limits<double>::infinity();
	for (int i = 0; i < n; ++i) {
		float v = 0.0f;
		std::memcpy(&v, asked.ptr() + i * 4, sizeof(float));
		dt = std::min(dt, double(v));
	}
	return dt;
}

Dictionary LAFieldDriver::acoustic_reading() const {
	Dictionary out;
	out["residual_rel"] = _hz_residual;
	out["iterations"] = _hz_iterations;
	out["nonfinite_cell"] = _hz_nonfinite;
	return out;
}

int64_t LAFieldDriver::_flush(int64_t p_cl) {
	_rd->compute_list_end();
	_rd->submit();
	_rd->sync();
	_recorded = 0;
	(void)p_cl;
	return _rd->compute_list_begin();
}

int64_t LAFieldDriver::run_transport(int64_t p_cl, const Array &p_pc_rows, const Array &p_pc_grain,
		const Array &p_pc_lists, int p_seed_workgroups, int p_list_workgroups,
		const Dictionary &p_restate, const PackedByteArray &p_hz_pc) {
	if (_rd == nullptr || !_pipe.is_valid()) {
		return p_cl;
	}
	_refresh_live();
	_eos_pipe = plan_rid(p_restate, "pipe");
	_eos_set = plan_rid(p_restate, "set");
	_eos_pc = p_restate.get("pc", PackedByteArray());
	_eos_total = plan_int(p_restate, "total", 0);
	// THE RESTATE'S OWN THREE WORDS ARE THE TAIL of the derive's block: the flag that says this solve is
	// the step's own restate, the args slot it walks, and where its group's list starts.
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
		_fire(cl, _grain_set, _block(p_pc_grain, SLOT_ACT_SEED), RID(), p_seed_workgroups);
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
			const PackedByteArray &pc = _block(table, slots[i]);
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
		_rebuild_active(cl, _grain_set, p_pc_grain, gslot, true);
		_act(cl, _grain_set, p_pc_grain, SLOT_GRAIN, gslot);
	}
	for (int g = 0; g < _groups.size(); ++g) {
		const PackedInt32Array group = _groups[g];
		if (group.is_empty()) {
			continue;
		}
		const int last = group[group.size() - 1];
		const int first = group[0];
		const RID head = rid_at(_row_sets, first);
		const Array head_pc = p_pc_rows[first];
		// THE BUBBLE, rebuilt once a step.
		_rebuild_active(cl, head, head_pc, g, true);
		// EVERY FACE STATES ITSELF ONCE, before any record reads one: the pair's shared pressure and
		// the velocity the predictor gives each band, off the state this step starts in.
		_run_slot(cl, first, p_pc_rows, SLOT_FACE);
		// THE ACOUSTIC PRESSURE, SOLVED, on the group that closes with momentum: assemble the rows on
		// the device, then converge them outside any compute list before the close reads one.
		const bool closes = _live(last) && !_block(p_pc_rows[last], SLOT_MOMENTUM).is_empty();
		if (closes && _hz_pipe.is_valid() && _hz_set.is_valid() && p_hz_pc.size() >= 12) {
			std::memcpy(&_hz_dt_s_f, p_hz_pc.ptr() + 8, sizeof(float));
			_hz_dt_s = double(_hz_dt_s_f);
			// EVERY CELL, not the bubble: a row the predictor left cleared is a row with no equation,
			// and the solve has to see that rather than skip the cell.
			_fire_on(cl, _hz_pipe, _hz_set, p_hz_pc, RID(), (_cc + 63) / 64);
			_rd->compute_list_end();
			_rd->submit();
			_rd->sync();
			_solve_acoustic();
			cl = _rd->compute_list_begin();
			_recorded = 0;
		}
		// THE PRESSURE AND THE BODY IMPULSE NEXT, on the mass the faces were solved over, so what
		// the records then move carries its share of the momentum and leaves none behind.
		if (_live(last)) {
			_run_slot(cl, last, p_pc_rows, SLOT_MOMENTUM);
		}
		for (int i = 0; i < group.size(); ++i) {
			_run_row(cl, group[i], p_pc_rows);
			// ONE RECORD IS THE MOST A SUBMIT MAY HOLD: the device's fence wait is finite, and a
			// whole-grid step in one submit outran it.
			cl = _flush(cl);
		}
		_restate(cl, g);
		_recorded += group.size() + 5;
		if (_recorded > _flush_every) {
			cl = _flush(cl);
		}
	}
	// The wake queue is consumed; what the reactions write after this pass is next step's business.
	if (_grain_set.is_valid()) {
		_fire(cl, _grain_set, _block(p_pc_grain, SLOT_ACT_WAKE_RESET), RID(), 1);
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

void LAFieldDriver::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_device", "rd"), &LAFieldDriver::set_device);
	ClassDB::bind_method(D_METHOD("clear_buffers", "buffers", "bytes"), &LAFieldDriver::clear_buffers);
	ClassDB::bind_method(D_METHOD("run", "compute_list", "pipeline", "uniform_sets", "push_constants",
								  "workgroups", "args", "offsets", "barrier"),
			&LAFieldDriver::run);
	ClassDB::bind_method(D_METHOD("step", "passes", "names", "ctx", "cell_count", "groups", "probe"),
			&LAFieldDriver::step);
	ClassDB::bind_method(D_METHOD("pre_step", "passes", "ctx", "cc", "groups"),
			&LAFieldDriver::pre_step);
	ClassDB::bind_method(D_METHOD("moves_state", "passes"), &LAFieldDriver::moves_state);
	ClassDB::bind_method(D_METHOD("setup_transport", "plan"), &LAFieldDriver::setup_transport);
	ClassDB::bind_method(D_METHOD("run_transport", "compute_list", "pc_rows", "pc_grain",
								  "pc_lists", "seed_workgroups", "list_workgroups", "restate", "hz_pc"),
			&LAFieldDriver::run_transport);
	ClassDB::bind_method(D_METHOD("acoustic_reading"), &LAFieldDriver::acoustic_reading);
	ClassDB::bind_method(D_METHOD("step_seconds", "dt_buf", "pc_rows", "pc_grain", "seed_workgroups"),
			&LAFieldDriver::step_seconds);
	ClassDB::bind_method(D_METHOD("fold_reduce", "partials", "folds", "keys", "groups"),
			&LAFieldDriver::fold_reduce);

	BIND_ENUM_CONSTANT(SLOT_OUTFLOW);
	BIND_ENUM_CONSTANT(SLOT_GATHER);
	BIND_ENUM_CONSTANT(SLOT_SW);
	BIND_ENUM_CONSTANT(SLOT_FACE);
	BIND_ENUM_CONSTANT(SLOT_MOMENTUM);
	BIND_ENUM_CONSTANT(SLOT_ACT_AGE);
	BIND_ENUM_CONSTANT(SLOT_ACT_WAKE);
	BIND_ENUM_CONSTANT(SLOT_ACT_MARK);
	BIND_ENUM_CONSTANT(SLOT_SCAN);
	BIND_ENUM_CONSTANT(SLOT_COMPACT);
	BIND_ENUM_CONSTANT(SLOT_GRAIN);
	BIND_ENUM_CONSTANT(SLOT_ACT_SEED);
	BIND_ENUM_CONSTANT(SLOT_ACT_WAKE_RESET);
	BIND_ENUM_CONSTANT(SLOT_LIST_RESET);
	BIND_ENUM_CONSTANT(SLOT_LIST_APPEND);
	BIND_ENUM_CONSTANT(SLOT_LIST_ARGS);
	BIND_ENUM_CONSTANT(SLOT_STEP_DT);
	BIND_ENUM_CONSTANT(SLOT_COUNT);
	BIND_ENUM_CONSTANT(FOLD_SUM);
	BIND_ENUM_CONSTANT(FOLD_MIN);
	BIND_ENUM_CONSTANT(FOLD_MAX);
	BIND_ENUM_CONSTANT(FOLD_SKIP);
}
