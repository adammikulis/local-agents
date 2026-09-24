#include "LAFieldDriver.hpp"

#include "LAProcessSet.hpp"

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <deque>
#include <limits>
#include <utility>

using namespace godot;

namespace {

using Clock = std::chrono::steady_clock;

const std::string RESTATE_KEY = "transport/restate";

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

// Workgroups w in [0, total) with w = phase (mod stride).
int64_t class_groups(int64_t total, int64_t stride, int64_t phase) {
	return phase >= total ? 0 : (total - 1 - phase) / stride + 1;
}

std::string key_of(const String &s) {
	return std::string(s.utf8().get_data());
}

} // namespace

Ref<LAFieldDriver> LAFieldDriver::on(RenderingDevice *p_rd) {
	Ref<LAFieldDriver> d;
	d.instantiate();
	d->_rd = p_rd;
	RenderingServer *rs = RenderingServer::get_singleton();
	const bool metal = rs != nullptr && rs->get_current_rendering_driver_name() == "metal";
	d->set_wait_usec(metal ? double(METAL_FENCE_WAIT_MS) * 1000.0 : std::numeric_limits<double>::infinity());
	return d;
}

void LAFieldDriver::set_wait_usec(double p_usec) {
	_wait_usec = p_usec;
}

double LAFieldDriver::wait_usec() const {
	return _wait_usec;
}

bool LAFieldDriver::_bounded() const {
	return std::isfinite(_wait_usec);
}

double LAFieldDriver::_target(const Cost &p_cost) const {
	return std::sqrt(p_cost.latency_usec * _wait_usec);
}

// No piece of a dispatch finishes sooner than its latency floor; past it, it costs what the last submit that
// carried it alone cost per workgroup.
double LAFieldDriver::_pred(const Cost &p_cost, double p_groups) const {
	return std::max(p_cost.latency_usec, p_cost.last_usec * p_groups / p_cost.last_groups);
}

void LAFieldDriver::_load(const std::string &p_key, double p_more, double &r_pred, double &r_target) const {
	std::vector<std::pair<const std::string *, double>> per;
	auto add = [&per](const std::string &k, double g) {
		for (std::pair<const std::string *, double> &e : per) {
			if (*e.first == k) {
				e.second += g;
				return;
			}
		}
		per.emplace_back(&k, g);
	};
	for (const Carried &c : _carried) {
		add(c.key, c.groups);
	}
	if (p_more > 0.0) {
		add(p_key, p_more);
	}
	r_pred = 0.0;
	r_target = std::numeric_limits<double>::infinity();
	for (const std::pair<const std::string *, double> &e : per) {
		const auto it = _costs.find(*e.first);
		if (it == _costs.end() || !it->second.known) {
			continue;
		}
		r_pred += _pred(it->second, e.second);
		r_target = std::min(r_target, _target(it->second));
	}
}

bool LAFieldDriver::_fits(const std::string &p_key, double p_groups) const {
	const auto it = _costs.find(p_key);
	return it != _costs.end() && it->second.known
			&& _pred(it->second, p_groups) <= _target(it->second);
}

void LAFieldDriver::open() {
	ERR_FAIL_NULL(_rd);
	ERR_FAIL_COND_MSG(_open, "LAFieldDriver: open() while a list is already open.");
	_cl = _rd->compute_list_begin();
	_open = true;
}

void LAFieldDriver::close() {
	ERR_FAIL_COND_MSG(!_open, "LAFieldDriver: close() with no list open.");
	_submit();
	_open = false;
}

void LAFieldDriver::restart() {
	ERR_FAIL_NULL(_rd);
	ERR_FAIL_COND_MSG(_open, "LAFieldDriver: restart() while a list is open.");
	_costs.clear();
	// What the CPU wrote reaches the device in its own submit, so the next measurement is the kernels' alone.
	_rd->submit();
	_rd->sync();
}

// End the list, submit it and wait: the wall time it took is what the device spent on what it carried.
void LAFieldDriver::_submit() {
	_rd->compute_list_end();
	double predicted = 0.0;
	double target = 0.0;
	_load(std::string(), 0.0, predicted, target);
	bool probe = false;
	for (const Carried &c : _carried) {
		const auto it = _costs.find(c.key);
		probe = probe || it == _costs.end() || !it->second.known;
	}
	const bool unit = _carried.size() == 1 && (_carried[0].groups == 1.0 || _costs[_carried[0].key].indirect);
	const Clock::time_point t0 = Clock::now();
	_rd->submit();
	_rd->sync();
	const double usec = std::chrono::duration<double, std::micro>(Clock::now() - t0).count();
	++_submits;
	_worst_usec = std::max(_worst_usec, usec);
	if (_bounded() && !probe && !unit && predicted > target) {
		++_over_target;
	}
	_learn(usec);
	_carried.clear();
}

void LAFieldDriver::_flush() {
	_submit();
	_cl = _rd->compute_list_begin();
}

// A submit that carried ONE dispatch measures it; one shared by several measures none of them.
void LAFieldDriver::_learn(double p_usec) {
	if (_carried.empty() || !_bounded()) {
		return;
	}
	const std::string &key = _carried.front().key;
	double groups = 0.0;
	for (const Carried &c : _carried) {
		if (c.key != key) {
			return;
		}
		groups += c.groups;
	}
	Cost &cost = _costs[key];
	// An indirect dispatch is its whole list every time, so a shorter list never lowers what it is priced at.
	if (cost.indirect) {
		cost.last_usec = cost.known ? std::max(cost.last_usec, p_usec) : p_usec;
		cost.latency_usec = cost.last_usec;
	} else {
		cost.last_usec = p_usec;
		if (groups == 1.0) {
			cost.latency_usec = cost.known ? std::max(cost.latency_usec, p_usec) : p_usec;
		}
	}
	cost.last_groups = groups;
	cost.known = true;
}

// A piece of a dispatch joins the open submit while the submit stays inside its target, else the submit goes
// first. An unmeasured dispatch goes alone. A piece that cannot split and is predicted past the wait on its
// own is refused before it is submitted.
bool LAFieldDriver::_admit(const std::string &p_key, double p_groups, bool p_indirect) {
	Cost &cost = _costs[p_key];
	cost.indirect = p_indirect;
	if (_bounded()) {
		if (!cost.known) {
			if (!_carried.empty()) {
				_flush();
			}
		} else {
			const double alone = _pred(cost, p_groups);
			if ((p_indirect || p_groups == 1.0) && alone > _wait_usec) {
				++_refused;
				UtilityFunctions::push_error(vformat("LAFieldDriver: \"%s\" is predicted at %.1f ms in the smallest "
						"submit it splits into, past the device's %.1f ms fence wait, so it was NOT submitted.",
						String(p_key.c_str()), alone / 1000.0, _wait_usec / 1000.0));
				return false;
			}
			double pred = 0.0;
			double target = 0.0;
			_load(p_key, p_groups, pred, target);
			if (!_carried.empty() && pred > target) {
				_flush();
			}
		}
	}
	_carried.push_back(Carried{ p_key, p_groups });
	return true;
}

PackedByteArray LAFieldDriver::dispatched_block(const PackedByteArray &p_pc, int64_t p_stride, int64_t p_phase) {
	PackedByteArray out;
	out.resize(p_pc.size() + 8);
	uint8_t *w = out.ptrw();
	if (p_pc.size() > 0) {
		std::memcpy(w, p_pc.ptr(), (size_t)p_pc.size());
	}
	put_u32(w, p_pc.size(), (uint32_t)p_stride);
	put_u32(w, p_pc.size() + 4, (uint32_t)p_phase);
	return out;
}

void LAFieldDriver::_emit(const RID &p_pipe, const RID &p_uset, const PackedByteArray &p_pc, int64_t p_stride,
		int64_t p_phase, int64_t p_groups, const RID &p_args, int p_offset) {
	const int n = p_pc.size();
	if (_out.size() != n + 8) {
		_out.resize(n + 8);
	}
	uint8_t *w = _out.ptrw();
	std::memcpy(w, p_pc.ptr(), (size_t)n);
	put_u32(w, n, (uint32_t)p_stride);
	put_u32(w, n + 4, (uint32_t)p_phase);
	_rd->compute_list_bind_compute_pipeline(_cl, p_pipe);
	_rd->compute_list_bind_uniform_set(_cl, p_uset, 0);
	_rd->compute_list_set_push_constant(_cl, _out, _out.size());
	if (p_args.is_valid()) {
		_rd->compute_list_dispatch_indirect(_cl, p_args, (uint32_t)p_offset);
	} else {
		_rd->compute_list_dispatch(_cl, (uint32_t)p_groups, 1, 1);
	}
	++_classes;
}

// ONE DIRECT DISPATCH, in residue classes of its workgroups: a class that does not fit its target alone splits
// into its two halves at twice the stride, so every submit is an even sample of the grid. An unmeasured
// dispatch first sends its middle workgroup alone, then the rest from one workgroup up, doubling.
void LAFieldDriver::_plan(const std::string &p_key, const RID &p_pipe, const RID &p_uset,
		const PackedByteArray &p_pc, int64_t p_groups, bool p_barrier) {
	if (!p_pipe.is_valid() || !p_uset.is_valid() || p_pc.is_empty() || p_groups <= 0) {
		return;
	}
	++_dispatches;
	std::deque<std::pair<int64_t, int64_t>> todo;
	int64_t span = 1;
	while (span < p_groups) {
		span <<= 1;
	}
	if (_bounded() && !_costs[p_key].known && span > 1) {
		todo.emplace_back(span, span / 2);
		for (int64_t s = span; s >= 2; s >>= 1) {
			todo.emplace_back(s, s == span ? 0 : s / 2);
		}
	} else {
		todo.emplace_back(1, 0);
	}
	bool emitted = false;
	while (!todo.empty()) {
		const int64_t stride = todo.front().first;
		const int64_t phase = todo.front().second;
		todo.pop_front();
		const int64_t n = class_groups(p_groups, stride, phase);
		if (n <= 0) {
			continue;
		}
		if (_bounded() && n > 1 && !_fits(p_key, double(n))) {
			todo.emplace_front(stride * 2, phase + stride);
			todo.emplace_front(stride * 2, phase);
			continue;
		}
		const bool probe = _bounded() && !_costs[p_key].known;
		if (!_admit(p_key, double(n), false)) {
			continue;
		}
		_emit(p_pipe, p_uset, p_pc, stride, phase, n, RID(), 0);
		emitted = true;
		if (probe) {
			_flush();
		}
	}
	if (emitted && p_barrier) {
		_rd->compute_list_add_barrier(_cl);
	}
}

// ONE INDIRECT DISPATCH: the device holds its count, so it goes whole, priced at the longest it has taken.
void LAFieldDriver::_plan_indirect(const std::string &p_key, const RID &p_pipe, const RID &p_uset,
		const PackedByteArray &p_pc, const RID &p_args, int p_offset, int64_t p_capacity, bool p_barrier) {
	if (!p_pipe.is_valid() || !p_uset.is_valid() || p_pc.is_empty() || !p_args.is_valid()) {
		return;
	}
	ERR_FAIL_COND_MSG(p_capacity <= 0, vformat("LAFieldDriver: indirect \"%s\" names no capacity.",
			String(p_key.c_str())));
	++_dispatches;
	const bool probe = _bounded() && !_costs[p_key].known;
	if (!_admit(p_key, double(p_capacity), true)) {
		return;
	}
	_emit(p_pipe, p_uset, p_pc, 1, 0, 0, p_args, p_offset);
	if (probe) {
		_flush();
	}
	if (p_barrier) {
		_rd->compute_list_add_barrier(_cl);
	}
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

void LAFieldDriver::run(const RID &p_pipe, const Array &p_usets, const Array &p_pcs,
		const PackedInt32Array &p_workgroups, const Array &p_args, const PackedInt32Array &p_offsets,
		bool p_barrier, const PackedStringArray &p_keys) {
	ERR_FAIL_COND_MSG(!_open, "LAFieldDriver: run() outside open() and close().");
	const bool one_key = p_keys.size() == 1;
	ERR_FAIL_COND_MSG(!one_key && p_keys.size() != p_pcs.size(),
			"LAFieldDriver: run() takes one cost key, or one per block.");
	if (_rd == nullptr || !p_pipe.is_valid() || p_pcs.is_empty()) {
		return;
	}
	const bool one_set = p_usets.size() == 1;
	for (int i = 0; i < p_pcs.size(); ++i) {
		const RID uset = rid_at(p_usets, one_set ? 0 : i);
		if (!uset.is_valid()) {
			continue;
		}
		const PackedByteArray pc = p_pcs[i];
		const std::string key = key_of(p_keys[one_key ? 0 : i]);
		const int64_t groups = i < p_workgroups.size() ? p_workgroups[i] : 0;
		const RID args = rid_at(p_args, i);
		if (args.is_valid()) {
			_plan_indirect(key, p_pipe, uset, pc, args, i < p_offsets.size() ? p_offsets[i] : 0, groups, p_barrier);
		} else {
			_plan(key, p_pipe, uset, pc, groups, p_barrier);
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
		// A pass ends in its own submit, which orders it after the pass before it.
		open();
		p->call("dispatch", _rd, p_ctx, p_cc, p_groups);
		close();
		if (probed) {
			p_probe.call(i, i < p_names.size() ? p_names[i] : String());
		}
	}
	// Leave an in-flight submit so the drain's contract is unchanged. An empty list is a legal no-op.
	_rd->compute_list_begin();
	_rd->compute_list_end();
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
	_queue_bin = plan_int(p_plan, "queue_bin", 0);
	_slots = plan_int(p_plan, "slots", 0);
	_group_count = plan_int(p_plan, "group_count", 1);
	_capacity = plan_int(p_plan, "capacity", 0);
	_level_off = plan_int(p_plan, "level_off", 0);
	_k_off = plan_int(p_plan, "k_off", 0);
	_n_off = plan_int(p_plan, "n_off", 0);
	const int rows = _rows.size();
	const int owners = rows + 1 + _list_sets.size();
	_slot_keys.assign((size_t)owners * SLOT_COUNT, std::string());
	for (int o = 0; o < owners; ++o) {
		String base;
		if (o < rows) {
			const Dictionary row = _rows[o];
			base = vformat("transport/%s/%d", String(row.get("label", String())), o);
		} else if (o == rows) {
			base = "transport/grain";
		} else {
			base = vformat("transport/list/%d", o - rows - 1);
		}
		for (int s = 0; s < SLOT_COUNT; ++s) {
			_slot_keys[(size_t)o * SLOT_COUNT + s] = key_of(vformat("%s#%d", base, s));
		}
	}
}

const std::string &LAFieldDriver::_key(int p_owner, int p_slot) const {
	return _slot_keys[(size_t)p_owner * SLOT_COUNT + p_slot];
}

// A record with no entry in the mask is live: a plan that declares none is a plan with no switches.
bool LAFieldDriver::_live(int p_row) const {
	return p_row >= _row_live.size() || _row_live[p_row] != 0;
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

// THE MATTER THIS SUBSTEP MOVED IS AT A NEW PRESSURE. The derive's own kernel says what pressure, over
// the same cells the substep walked, before the next substep's faces read one.
void LAFieldDriver::_restate(int p_group, int p_level) {
	if (!_eos_pipe.is_valid() || !_eos_set.is_valid() || _eos_pc.is_empty()) {
		return;
	}
	const int offset = _args_offset(p_group, p_level);
	uint8_t *w = _eos_pc.ptrw();
	put_u32(w, _eos_slot_off, (uint32_t)(offset / 4));
	put_u32(w, _eos_base_off, (uint32_t)(p_group * _eos_total));
	_plan_indirect(RESTATE_KEY, _eos_pipe, _eos_set, _eos_pc, _args, offset, _capacity, true);
}

void LAFieldDriver::_act(int p_owner, const RID &p_uset, const Array &p_table, int p_slot, int p_group,
		int p_level, int p_bin) {
	_plan_indirect(_key(p_owner, p_slot), _pipe, p_uset, _block(p_table, p_slot, p_level, 0, 1), _args,
			_args_offset(p_group, p_bin), _capacity, true);
}

void LAFieldDriver::_rebuild_active(int p_owner, const RID &p_uset, const Array &p_table, int p_group,
		int p_level, bool p_take_wake) {
	_act(p_owner, p_uset, p_table, SLOT_ACT_AGE, p_group, p_level, 0);
	if (p_take_wake) {
		_plan_indirect(_key(p_owner, SLOT_ACT_WAKE), _pipe, p_uset, _block(p_table, SLOT_ACT_WAKE, p_level, 0, 1),
				_wake_args, 0, _capacity, true);
	}
	_act(p_owner, p_uset, p_table, SLOT_ACT_MARK, p_group, p_level, 0);
	_plan(_key(p_owner, SLOT_LEVEL_SCAN), _pipe, p_uset, _block(p_table, SLOT_LEVEL_SCAN, p_level, 0, 1), 1, true);
	_act(p_owner, p_uset, p_table, SLOT_LEVEL_SORT, p_group, p_level, _queue_bin);
}

void LAFieldDriver::build_levels(int p_group, const Array &p_pc_rows, int p_levels) {
	ERR_FAIL_COND_MSG(!_open, "LAFieldDriver: build_levels() outside open() and close().");
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
	_act(first, head, head_pc, SLOT_LEVEL_RESET, p_group, 0, 0);
	if (p_levels <= 0) {
		return;
	}
	for (int i = 0; i < group.size(); ++i) {
		const int gi = group[i];
		_act(gi, rid_at(_row_sets, gi), p_pc_rows[gi], SLOT_LEVEL_SEED, p_group, 0, 0);
	}
	// One outward sweep: every neighbour of a listed cell takes at least that cell's level.
	_act(first, head, head_pc, SLOT_LEVEL_RELAX, p_group, 0, 0);
}

// ONE SLOT OF ONE RECORD, over its group's active cells at this level: what it costs is what moves.
void LAFieldDriver::_run_slot(int p_row, const Array &p_pc_rows, int p_slot, int p_level, int p_k, int p_n) {
	const RID uset = rid_at(_row_sets, p_row);
	if (!uset.is_valid() || !_args.is_valid()) {
		return;
	}
	const int group = p_row < _row_group.size() ? _row_group[p_row] : 0;
	_plan_indirect(_key(p_row, p_slot), _pipe, uset, _block(p_pc_rows[p_row], p_slot, p_level, p_k, p_n), _args,
			_args_offset(group, p_level), _capacity, true);
}

// THE FLUX AND THE APPLY: the record writes what crosses each of its cells' own faces, then reads
// those faces back into the cells. Nothing between the two touches them.
void LAFieldDriver::_run_row(int p_row, const Array &p_pc_rows, int p_level, int p_k, int p_n) {
	if (!_live(p_row)) {
		return;
	}
	_run_slot(p_row, p_pc_rows, SLOT_OUTFLOW, p_level, p_k, p_n);
	_run_slot(p_row, p_pc_rows, SLOT_GATHER, p_level, p_k, p_n);
	if (p_row < _row_radiate.size() && _row_radiate[p_row] != 0) {
		_run_slot(p_row, p_pc_rows, SLOT_SW, p_level, p_k, p_n);
	}
}

void LAFieldDriver::run_transport(const PackedInt32Array &p_peaks, const Array &p_pc_rows,
		const Array &p_pc_grain, const Array &p_pc_lists, int p_seed_workgroups, int p_list_workgroups,
		const Dictionary &p_restate) {
	ERR_FAIL_COND_MSG(!_open, "LAFieldDriver: run_transport() outside open() and close().");
	if (_rd == nullptr || !_pipe.is_valid()) {
		return;
	}
	_row_live.resize(_rows.size());
	for (int i = 0; i < _rows.size(); ++i) {
		const Dictionary row = _rows[i];
		_row_live.set(i, LAProcessSet::is_active("transport", row.get("label", String()),
				LAProcessSet::ANY) ? 1 : 0);
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
	const int grain = _rows.size();
	// THE LISTS, before anything reads one: every cell of a world nobody has stepped yet.
	if (p_seed_workgroups > 0) {
		_plan(_key(grain, SLOT_ACT_SEED), _pipe, _grain_set, _block(p_pc_grain, SLOT_ACT_SEED, 0, 0, 1),
				p_seed_workgroups, true);
	}
	// THE DETECTOR LISTS: a detector looks everywhere, because a value it has never seen can sit anywhere.
	for (int r = 0; r < _list_sets.size(); ++r) {
		const RID lset = rid_at(_list_sets, r);
		if (!lset.is_valid()) {
			continue;
		}
		const Array table = p_pc_lists[r];
		const int slots[3] = { SLOT_LIST_RESET, SLOT_LIST_APPEND, SLOT_LIST_ARGS };
		const int64_t wgs[3] = { 1, p_list_workgroups, 1 };
		for (int i = 0; i < 3; ++i) {
			_plan(_key(grain + 1 + r, slots[i]), _pipe, lset, _block(table, slots[i], 0, 0, 1), wgs[i], true);
		}
	}
	// PROLOGUE: the suspension shares its silicate rows before anything donates.
	if (_grain_set.is_valid()) {
		const int gslot = _group_count - 1;
		_act(grain, _grain_set, p_pc_grain, SLOT_LEVEL_RESET, gslot, 0, 0);
		_rebuild_active(grain, _grain_set, p_pc_grain, gslot, 0, true);
		_act(grain, _grain_set, p_pc_grain, SLOT_GRAIN, gslot, 0, 0);
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
		build_levels(g, p_pc_rows, levels);
		const int steps = 1 << levels;
		const int last = group[group.size() - 1];
		const int first = group[0];
		const RID head = rid_at(_row_sets, first);
		const Array head_pc = p_pc_rows[first];
		for (int k = 0; k < steps; ++k) {
			const int lk = coarsest_at(k, levels);
			// THE BUBBLE, one substep at a time.
			_rebuild_active(first, head, head_pc, g, lk, k == 0);
			// EVERY FACE STATES ITSELF ONCE, before any record reads one: the pair's interface
			// pressure and velocity, off the state this substep starts in.
			_run_slot(first, p_pc_rows, SLOT_FACE, lk, k, steps);
			// THE PRESSURE AND THE BODY IMPULSE NEXT, on the mass the faces were solved over, so what
			// the records then move carries its share of the momentum and leaves none behind.
			if (_live(last)) {
				_run_slot(last, p_pc_rows, SLOT_MOMENTUM, lk, k, steps);
			}
			for (int i = 0; i < group.size(); ++i) {
				_run_row(group[i], p_pc_rows, lk, k, steps);
			}
			_restate(g, lk);
		}
	}
	// The wake queue is consumed; what the reactions write after this pass is next step's business.
	if (_grain_set.is_valid()) {
		_plan(_key(grain, SLOT_ACT_WAKE_RESET), _pipe, _grain_set,
				_block(p_pc_grain, SLOT_ACT_WAKE_RESET, 0, 0, 1), 1, true);
	}
}

Dictionary LAFieldDriver::ledger() const {
	Dictionary out;
	out["submits"] = _submits;
	out["dispatches"] = _dispatches;
	out["classes"] = _classes;
	out["refused"] = _refused;
	out["over_target"] = _over_target;
	out["worst_usec"] = _worst_usec;
	out["wait_usec"] = _wait_usec;
	return out;
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
	ClassDB::bind_static_method("LAFieldDriver", D_METHOD("on", "rd"), &LAFieldDriver::on);
	ClassDB::bind_method(D_METHOD("set_wait_usec", "usec"), &LAFieldDriver::set_wait_usec);
	ClassDB::bind_method(D_METHOD("wait_usec"), &LAFieldDriver::wait_usec);
	ClassDB::bind_method(D_METHOD("open"), &LAFieldDriver::open);
	ClassDB::bind_method(D_METHOD("close"), &LAFieldDriver::close);
	ClassDB::bind_method(D_METHOD("restart"), &LAFieldDriver::restart);
	ClassDB::bind_method(D_METHOD("clear_buffers", "buffers", "bytes"), &LAFieldDriver::clear_buffers);
	ClassDB::bind_method(D_METHOD("run", "pipeline", "uniform_sets", "push_constants", "workgroups", "args",
								  "offsets", "barrier", "keys"),
			&LAFieldDriver::run);
	ClassDB::bind_method(D_METHOD("step", "passes", "names", "ctx", "cell_count", "groups", "probe"),
			&LAFieldDriver::step);
	ClassDB::bind_method(D_METHOD("pre_step", "passes", "ctx", "cc", "groups"),
			&LAFieldDriver::pre_step);
	ClassDB::bind_method(D_METHOD("moves_state", "passes"), &LAFieldDriver::moves_state);
	ClassDB::bind_method(D_METHOD("setup_transport", "plan"), &LAFieldDriver::setup_transport);
	ClassDB::bind_method(D_METHOD("run_transport", "peaks", "pc_rows", "pc_grain", "pc_lists",
								  "seed_workgroups", "list_workgroups", "restate"),
			&LAFieldDriver::run_transport);
	ClassDB::bind_method(D_METHOD("build_levels", "group", "pc_rows", "levels"),
			&LAFieldDriver::build_levels);
	ClassDB::bind_method(D_METHOD("fold_reduce", "partials", "folds", "keys", "groups"),
			&LAFieldDriver::fold_reduce);
	ClassDB::bind_method(D_METHOD("ledger"), &LAFieldDriver::ledger);
	ClassDB::bind_static_method("LAFieldDriver", D_METHOD("dispatched_block", "pc", "stride", "phase"),
			&LAFieldDriver::dispatched_block);

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
