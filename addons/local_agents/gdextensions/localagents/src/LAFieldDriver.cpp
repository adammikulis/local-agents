#include "LAFieldDriver.hpp"

#include "LAPhysicalRead.hpp"
#include "LAScriptCall.hpp"
#include "LASubstances.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cmath>
#include <cstring>
#include <limits>

using namespace godot;

namespace {

const char *TRANSPORT_GD = "res://addons/local_agents/sim/material/TransportRecords.gd";
const char *MATTER_GD = "res://addons/local_agents/sim/material/MatterChannels.gd";
const char *REDUCE_GD = "res://addons/local_agents/sim/material/ReduceRecords.gd";

// active_levels.glsli's ACT_NO_GROUP: this record's crossings wake no second group.
const uint32_t NO_GROUP = 0xffffffffu;

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

void put_f32(uint8_t *w, int off, float v) {
	std::memcpy(w + off, &v, sizeof(float));
}

// A push-constant block written in the kernel's declared field order; each write returns its offset,
// so no byte position is spelled out anywhere.
class Block {
public:
	int u32(uint32_t v) {
		const int at = _grow();
		put_u32(_b.ptrw(), at, v);
		return at;
	}
	int f32(double v) {
		const int at = _grow();
		put_f32(_b.ptrw(), at, (float)v);
		return at;
	}
	const PackedByteArray &take() const { return _b; }

private:
	PackedByteArray _b;
	int _grow() {
		const int at = _b.size();
		_b.resize(at + 4);
		return at;
	}
};

// A GDScript enum, as its name -> value dictionary.
Dictionary gd_enum(const char *p_path, const char *p_name) {
	const Dictionary d = la_gd_const(p_path, p_name);
	ERR_FAIL_COND_V_MSG(d.is_empty(), d, String(p_path) + " declares no " + p_name + " values.");
	return d;
}

uint32_t enum_bit(const Dictionary &p_enum, const char *p_name) {
	ERR_FAIL_COND_V_MSG(!p_enum.has(p_name), 0u, String("no such flag: ") + p_name);
	return (uint32_t)(int64_t)p_enum[p_name];
}

int gd_int(const char *p_path, const char *p_name) {
	return (int)(int64_t)la_gd_const(p_path, p_name);
}

// The record key that raises each per-record switch, against the flag LATransportRecords declares.
struct FlagKey {
	const char *key;
	const char *flag;
	bool named;
};
const FlagKey FLAG_KEYS[] = {
	{ "settle", "SETTLE", false },
	{ "efield", "EFIELD", false },
	{ "dilute", "DILUTE", false },
	{ "relax", "RELAX", false },
	{ "radiogenic", "RADIOGENIC", false },
	{ "lattice", "LATTICE", false },
	{ "frac", "FRACTION", true },
};

// A record closes its group with the interface pressure and the body impulse.
bool vel_row(const Dictionary &p_row) {
	return bool(p_row.get("momentum", false));
}

// A record of the acoustic substep group: the momentum close, or compressible matter flagged into it.
bool group_row(const Dictionary &p_row) {
	return vel_row(p_row) || bool(p_row.get("acoustic", false));
}

String row_str(const Dictionary &p_row, const char *p_key) {
	const String s = p_row.get(p_key, String());
	return s;
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
	}
	for (int i = 0; i < p_passes.size(); ++i) {
		Object *p = p_passes[i];
		if (p == nullptr) {
			continue;
		}
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

// --- the transport plan -------------------------------------------------------------------------------

// Consecutive records that advance on ONE time axis: the acoustic set and the momentum that closes it.
Array LAFieldDriver::transport_groups(const Array &p_records) {
	Array out;
	for (int r = 0; r < p_records.size(); ++r) {
		const Dictionary row = p_records[r];
		if (r > 0 && group_row(row) && group_row(p_records[r - 1])) {
			PackedInt32Array tail = out[out.size() - 1];
			tail.append(r);
			out[out.size() - 1] = tail;
			continue;
		}
		PackedInt32Array one;
		one.append(r);
		out.append(one);
	}
	return out;
}

int LAFieldDriver::transport_group_count(const Array &p_records) {
	// One slot per record group, plus the grain prologue's own LAST: it derives where a cell's loose
	// mineral sits, so it is awake wherever silicate moved rather than wherever anything did.
	return LAFieldDriver::transport_groups(p_records).size() + 1;
}

void LAFieldDriver::plan_transport(const Dictionary &p_plan) {
	_pipe = plan_rid(p_plan, "pipe");
	_row_sets = p_plan.get("row_sets", Array());
	_args = plan_rid(p_plan, "args");
	_wake_args = plan_rid(p_plan, "wake_args");
	_grain_set = plan_rid(p_plan, "grain_set");
	_list_sets = p_plan.get("list_sets", Array());
	_queue_bin = plan_int(p_plan, "queue_bin", 0);
	_slots = plan_int(p_plan, "slots", 0);
	_flush_every = plan_int(p_plan, "flush_every", 4096);

	const int cc = plan_int(p_plan, "cell_count", 0);
	const int total = plan_int(p_plan, "total_count", cc);
	const int bands = plan_int(p_plan, "band_count", 0);
	const Array records = p_plan.get("records", Array());
	const Dictionary grain = p_plan.get("grain_record", Dictionary());
	const Array lists = p_plan.get("list_records", Array());

	_groups = LAFieldDriver::transport_groups(records);
	_group_count = _groups.size() + 1;
	const int gslot = _groups.size();

	_rows.clear();
	_rows.resize(records.size());
	for (int r = 0; r < records.size(); ++r) {
		_rows[r].group = 0;
	}
	for (int g = 0; g < _groups.size(); ++g) {
		const PackedInt32Array group = _groups[g];
		for (int i = 0; i < group.size(); ++i) {
			_rows[group[i]].group = g;
		}
	}
	for (int r = 0; r < records.size(); ++r) {
		_encode(_rows[r], records[r], cc, total, bands, _rows[r].group);
	}
	// THE HEAD carries its group's face solve, its levels and its activity; every member seeds a level
	// and asks for its own peak; the momentum record closes the group and moves no matter of its own.
	const int mode_radiate = gd_int(TRANSPORT_GD, "RADIATE");
	for (int g = 0; g < _groups.size(); ++g) {
		const PackedInt32Array group = _groups[g];
		Row &head = _rows[group[0]];
		head.slots |= (1u << SLOT_LEVEL_RESET) | (1u << SLOT_LEVEL_RELAX) | (1u << SLOT_ACT_AGE) |
				(1u << SLOT_ACT_WAKE) | (1u << SLOT_ACT_MARK) | (1u << SLOT_LEVEL_SCAN) |
				(1u << SLOT_LEVEL_SORT) | (1u << SLOT_FACE);
		for (int i = 0; i < group.size(); ++i) {
			const Dictionary row = records[group[i]];
			Row &dst = _rows[group[i]];
			dst.slots |= (1u << SLOT_LEVEL_SEED) | (1u << SLOT_LEVEL_PEAK);
			if (!vel_row(row)) {
				dst.slots |= (1u << SLOT_OUTFLOW) | (1u << SLOT_GATHER);
			}
			if (int(row["mode"]) == mode_radiate) {
				dst.slots |= (1u << SLOT_SW);
			}
		}
		const int last = group[group.size() - 1];
		if (vel_row(records[last])) {
			_rows[last].slots |= (1u << SLOT_MOMENTUM);
		}
	}

	_grain = Row();
	if (_grain_set.is_valid() && !grain.is_empty()) {
		_encode(_grain, grain, cc, total, bands, gslot);
		_grain.slots = (1u << SLOT_LEVEL_RESET) | (1u << SLOT_ACT_AGE) | (1u << SLOT_ACT_WAKE) |
				(1u << SLOT_ACT_MARK) | (1u << SLOT_LEVEL_SCAN) | (1u << SLOT_LEVEL_SORT) |
				(1u << SLOT_GRAIN) | (1u << SLOT_ACT_SEED) | (1u << SLOT_ACT_WAKE_RESET);
	}

	_lists.clear();
	_lists.resize(lists.size());
	for (int r = 0; r < lists.size(); ++r) {
		_encode(_lists[r], lists[r], cc, total, bands, 0);
		_lists[r].slots = (1u << SLOT_LIST_RESET) | (1u << SLOT_LIST_APPEND) | (1u << SLOT_LIST_ARGS);
	}
}

// ONE RECORD'S BLOCK, in flux.glsl's declared field order. Everything here is a property of the record
// or of the grid; the step's own scalars are stamped in before each dispatch.
void LAFieldDriver::_encode(Row &p_dst, const Dictionary &p_row, int p_cc, int p_total, int p_bands,
		int p_group) {
	const Dictionary flag = gd_enum(TRANSPORT_GD, "Flag");
	const Dictionary fluid_enum = gd_enum(TRANSPORT_GD, "Fluid");
	const int mode_conduct = gd_int(TRANSPORT_GD, "CONDUCT");
	const int mode_radiate = gd_int(TRANSPORT_GD, "RADIATE");
	const int law_none = (int)(int64_t)gd_enum(TRANSPORT_GD, "Law")["NONE"];
	const int fluid_vacuum = (int)(int64_t)fluid_enum["VACUUM"];
	const int fluid_water = (int)(int64_t)fluid_enum["WATER"];

	const String substance = row_str(p_row, "substance");
	const int mode = int(p_row["mode"]);
	const int law = (int)(int64_t)p_row.get("law", law_none);
	const int fluid = (int)(int64_t)p_row.get("fluid", fluid_vacuum);

	// EVERY RECORD PASS WALKS A LIST NOW, so the level remap is unconditional.
	uint32_t flags = enum_bit(flag, "LEVEL");
	if (vel_row(p_row)) {
		flags |= enum_bit(flag, "VEL");
	}
	for (const FlagKey &fk : FLAG_KEYS) {
		const bool on = fk.named ? row_str(p_row, fk.key) != String() : bool(p_row.get(fk.key, false));
		if (on) {
			flags |= enum_bit(flag, fk.flag);
		}
	}
	// The record whose amount IS enthalpy books joules on both boundary legs.
	if (mode == mode_conduct || mode == mode_radiate) {
		flags |= enum_bit(flag, "ENERGY");
	}
	if (fluid == fluid_water) {
		flags |= enum_bit(flag, "WATER");
	}

	Array one;
	one.append(fluid);
	const Vector2 fl = la_call_gd(TRANSPORT_GD, "fluid_properties", one);
	Array water_arg;
	water_arg.append(fluid_water);
	const Vector2 water = la_call_gd(TRANSPORT_GD, "fluid_properties", water_arg);
	Array air_arg;
	air_arg.append((int)(int64_t)fluid_enum["AIR"]);
	const Vector2 air = la_call_gd(TRANSPORT_GD, "fluid_properties", air_arg);

	const Dictionary entry = LASubstances::table().get(substance, Dictionary());
	double max_fill = std::numeric_limits<double>::infinity();
	double cap = 0.0;
	if (substance != String()) {
		Array sub;
		sub.append(substance);
		max_fill = double(la_call_gd(TRANSPORT_GD, "max_fill", sub));
		// J/m^3/K one mol/m^3 of the substance adds to the sensible entry (molar mass times specific
		// heat); 0 for a substance on a phase ladder, whose entry is the channel itself.
		cap = double(entry.get("molar_mass", 0.0)) * double(la_call_gd(MATTER_GD, "specific_heat", sub));
	}

	Block b;
	b.u32((uint32_t)p_cc);
	_off.pass = b.u32(0u);
	b.u32((uint32_t)mode);
	b.u32((uint32_t)law);
	b.u32((uint32_t)p_bands);
	b.u32(flags);
	_off.dt = b.f32(0.0);
	b.f32(double(p_row.get("repose_tan", 0.0)));
	b.f32(double(entry.get("density", 0.0)));
	b.f32(max_fill);
	b.f32(fl.x);
	b.f32(fl.y);
	// Seed diameter for cells whose own grain field is unset; the cell's value wins wherever it has one.
	b.f32(la_physical("GRAIN_D_UPLAND_M"));
	_off.sun = b.f32(0.0);
	b.f32(0.0);
	b.f32(0.0);
	b.f32(water.x);
	b.f32(water.y);
	b.f32(air.x);
	b.f32(air.y);
	b.f32(cap);
	b.u32((uint32_t)p_total);
	_off.xuv = b.f32(0.0);
	_off.level = b.u32(0u);
	_off.k = b.u32(0u);
	_off.n = b.u32(1u);
	_off.act_group = b.u32((uint32_t)p_group);
	// A record carrying silicate also wakes the prologue that derives where that mineral sits.
	b.u32(row_str(p_row, "channel") == String("silicate") ? (uint32_t)(_group_count - 1) : NO_GROUP);
	_off.phi = b.f32(0.0);
	_off.grav = b.f32(0.0);
	p_dst.block = b.take();
	p_dst.slots = 0;
	p_dst.group = p_group;
}

void LAFieldDriver::_stamp_one(Row &p_row, float p_dt, const Vector3 &p_sun, float p_xuv, float p_phi,
		float p_grav) {
	if (p_row.block.is_empty()) {
		return;
	}
	uint8_t *w = p_row.block.ptrw();
	put_f32(w, _off.dt, p_dt);
	put_f32(w, _off.sun, (float)p_sun.x);
	put_f32(w, _off.sun + 4, (float)p_sun.y);
	put_f32(w, _off.sun + 8, (float)p_sun.z);
	put_f32(w, _off.xuv, p_xuv);
	put_f32(w, _off.phi, p_phi);
	put_f32(w, _off.grav, p_grav);
}

// THE SCALARS THAT ARE THE STEP'S, not the record's: the interval it integrates, where the star is,
// what it delivers, and the potential's datum.
void LAFieldDriver::_stamp_step(const Dictionary &p_step) {
	const float dt = (float)(double)p_step.get("dt_s", 0.0);
	const Vector3 sun = p_step.get("sun", Vector3());
	const float xuv = (float)(double)p_step.get("xuv_w_m2", 0.0);
	const float phi = (float)(double)p_step.get("phi_datum", 0.0);
	const float grav = (float)(double)p_step.get("gravity_self", 0.0);
	for (Row &r : _rows) {
		_stamp_one(r, dt, sun, xuv, phi, grav);
	}
	_stamp_one(_grain, dt, sun, xuv, phi, grav);
	for (Row &r : _lists) {
		_stamp_one(r, dt, sun, xuv, phi, grav);
	}
}

int LAFieldDriver::_args_offset(int p_group, int p_bin) const {
	return (p_group * (_queue_bin + 1) + p_bin) * _slots * 4;
}

const PackedByteArray &LAFieldDriver::_block(const Row &p_row, int p_slot, int p_level, int p_k,
		int p_n) {
	if ((p_row.slots & (1u << p_slot)) == 0u || p_row.block.is_empty()) {
		_scratch.resize(0);
		return _scratch;
	}
	if (_scratch.size() != p_row.block.size()) {
		_scratch.resize(p_row.block.size());
	}
	uint8_t *w = _scratch.ptrw();
	std::memcpy(w, p_row.block.ptr(), (size_t)p_row.block.size());
	put_u32(w, _off.pass, (uint32_t)p_slot);
	put_u32(w, _off.level, (uint32_t)p_level);
	put_u32(w, _off.k, (uint32_t)p_k);
	put_u32(w, _off.n, (uint32_t)p_n);
	// The seed is the one pass that walks the whole box, and it reads act_group as the group COUNT.
	if (p_slot == SLOT_ACT_SEED) {
		put_u32(w, _off.act_group, (uint32_t)_group_count);
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

void LAFieldDriver::_act(int64_t p_cl, const RID &p_uset, const Row &p_row, int p_slot, int p_group,
		int p_bin, int p_level) {
	_fire(p_cl, p_uset, _block(p_row, p_slot, p_level, 0, 1), _args, _args_offset(p_group, p_bin));
}

void LAFieldDriver::_rebuild_active(int64_t p_cl, const RID &p_uset, const Row &p_row, int p_group,
		int p_level, bool p_take_wake) {
	_act(p_cl, p_uset, p_row, SLOT_ACT_AGE, p_group, 0, p_level);
	if (p_take_wake) {
		_fire(p_cl, p_uset, _block(p_row, SLOT_ACT_WAKE, p_level, 0, 1), _wake_args, 0);
	}
	_act(p_cl, p_uset, p_row, SLOT_ACT_MARK, p_group, 0, p_level);
	_fire(p_cl, p_uset, _block(p_row, SLOT_LEVEL_SCAN, p_level, 0, 1), RID(), 1);
	_act(p_cl, p_uset, p_row, SLOT_LEVEL_SORT, p_group, _queue_bin, p_level);
}

void LAFieldDriver::build_levels(int64_t p_cl, int p_group, int p_levels, const Dictionary &p_step) {
	if (_rd == nullptr || p_group < 0 || p_group >= _groups.size()) {
		return;
	}
	_stamp_step(p_step);
	_build_levels(p_cl, p_group, p_levels);
}

void LAFieldDriver::_build_levels(int64_t p_cl, int p_group, int p_levels) {
	const PackedInt32Array group = _groups[p_group];
	if (group.is_empty()) {
		return;
	}
	const int first = group[0];
	const RID head = rid_at(_row_sets, first);
	_act(p_cl, head, _rows[first], SLOT_LEVEL_RESET, p_group, 0, 0);
	if (p_levels <= 0) {
		return;
	}
	for (int i = 0; i < group.size(); ++i) {
		const int gi = group[i];
		_act(p_cl, rid_at(_row_sets, gi), _rows[gi], SLOT_LEVEL_SEED, p_group, 0, 0);
	}
	// One outward sweep: every neighbour of a listed cell takes at least that cell's level.
	_act(p_cl, head, _rows[first], SLOT_LEVEL_RELAX, p_group, 0, 0);
}

// ONE SLOT OF ONE RECORD, over its group's active cells at this level: what it costs is what moves.
void LAFieldDriver::_run_slot(int64_t p_cl, int p_row, int p_slot, int p_level, int p_k, int p_n) {
	const RID uset = rid_at(_row_sets, p_row);
	if (!uset.is_valid() || !_args.is_valid()) {
		return;
	}
	const PackedByteArray &pc = _block(_rows[p_row], p_slot, p_level, p_k, p_n);
	if (pc.is_empty()) {
		return;
	}
	_rd->compute_list_bind_compute_pipeline(p_cl, _pipe);
	_rd->compute_list_bind_uniform_set(p_cl, uset, 0);
	_rd->compute_list_set_push_constant(p_cl, pc, pc.size());
	_rd->compute_list_dispatch_indirect(p_cl, _args,
			(uint32_t)_args_offset(_rows[p_row].group, p_level));
	_rd->compute_list_add_barrier(p_cl);
}

// THE FLUX AND THE APPLY: the record writes what crosses each of its cells' own faces, then reads
// those faces back into the cells. Nothing between the two touches them.
void LAFieldDriver::_run_row(int64_t p_cl, int p_row, int p_level, int p_k, int p_n) {
	_run_slot(p_cl, p_row, SLOT_OUTFLOW, p_level, p_k, p_n);
	_run_slot(p_cl, p_row, SLOT_GATHER, p_level, p_k, p_n);
	_run_slot(p_cl, p_row, SLOT_SW, p_level, p_k, p_n);
}

int64_t LAFieldDriver::_flush(int64_t p_cl) {
	_rd->compute_list_end();
	_rd->submit();
	_rd->sync();
	_recorded = 0;
	(void)p_cl;
	return _rd->compute_list_begin();
}

// THE PEAK LEVEL PER GROUP: every record asks its own cells what clock they need, off the state this
// step starts in. The seed goes first, because a world nobody has stepped yet has no list to ask.
void LAFieldDriver::run_peak(int64_t p_cl, int p_seed_workgroups, const Dictionary &p_step) {
	if (_rd == nullptr || !_pipe.is_valid()) {
		return;
	}
	_stamp_step(p_step);
	if (p_seed_workgroups > 0) {
		_fire(p_cl, _grain_set, _block(_grain, SLOT_ACT_SEED, 0, 0, 1), RID(), p_seed_workgroups);
	}
	for (int g = 0; g < _groups.size(); ++g) {
		const PackedInt32Array group = _groups[g];
		for (int i = 0; i < group.size(); ++i) {
			const int gi = group[i];
			// PASS_LEVEL_PEAK reads `level` as the group slot its peak lands in.
			_fire(p_cl, rid_at(_row_sets, gi), _block(_rows[gi], SLOT_LEVEL_PEAK, g, 0, 1), _args,
					_args_offset(g, 0));
		}
	}
}

int64_t LAFieldDriver::run_transport(int64_t p_cl, const PackedInt32Array &p_peaks,
		const Dictionary &p_step, int p_seed_workgroups, int p_list_workgroups) {
	if (_rd == nullptr || !_pipe.is_valid()) {
		return p_cl;
	}
	_stamp_step(p_step);
	const Dictionary restate = p_step.get("restate", Dictionary());
	_eos_pipe = plan_rid(restate, "pipe");
	_eos_set = plan_rid(restate, "set");
	_eos_pc = restate.get("pc", PackedByteArray());
	_eos_total = plan_int(restate, "total", 0);
	// THE RESTATE'S OWN THREE WORDS ARE THE TAIL of the derive's block: the flag that says this solve is
	// the substep's, the level-args slot it walks, and where its group's sorted list starts.
	const int words = _eos_pc.size();
	if (words < 12) {
		_eos_pipe = RID();
	} else {
		put_u32(_eos_pc.ptrw(), words - 12, 1u);
		_eos_slot_off = words - 8;
		_eos_base_off = words - 4;
	}
	int64_t cl = p_cl;
	_recorded = 0;
	// THE LISTS, before anything reads one: every cell of a world nobody has stepped yet.
	if (p_seed_workgroups > 0) {
		_fire(cl, _grain_set, _block(_grain, SLOT_ACT_SEED, 0, 0, 1), RID(), p_seed_workgroups);
	}
	// THE DETECTOR LISTS: a detector looks everywhere, because a value it has never seen can sit anywhere.
	for (int r = 0; r < _list_sets.size() && r < (int)_lists.size(); ++r) {
		const RID lset = rid_at(_list_sets, r);
		if (!lset.is_valid()) {
			continue;
		}
		const int slots[3] = { SLOT_LIST_RESET, SLOT_LIST_APPEND, SLOT_LIST_ARGS };
		const int wgs[3] = { 1, p_list_workgroups, 1 };
		_rd->compute_list_bind_compute_pipeline(cl, _pipe);
		_rd->compute_list_bind_uniform_set(cl, lset, 0);
		for (int i = 0; i < 3; ++i) {
			const PackedByteArray &pc = _block(_lists[r], slots[i], 0, 0, 1);
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
		_act(cl, _grain_set, _grain, SLOT_LEVEL_RESET, gslot, 0, 0);
		_rebuild_active(cl, _grain_set, _grain, gslot, 0, true);
		_act(cl, _grain_set, _grain, SLOT_GRAIN, gslot, 0, 0);
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
		_build_levels(cl, g, levels);
		const int n = 1 << levels;
		const int last = group[group.size() - 1];
		const int first = group[0];
		const RID head = rid_at(_row_sets, first);
		for (int k = 0; k < n; ++k) {
			const int lk = coarsest_at(k, levels);
			// THE BUBBLE, one substep at a time.
			_rebuild_active(cl, head, _rows[first], g, lk, k == 0);
			// EVERY FACE STATES ITSELF ONCE, before any record reads one: the pair's interface
			// pressure and velocity, off the state this substep starts in.
			_run_slot(cl, first, SLOT_FACE, lk, k, n);
			// THE PRESSURE AND THE BODY IMPULSE NEXT, on the mass the faces were solved over, so what
			// the records then move carries its share of the momentum and leaves none behind.
			_run_slot(cl, last, SLOT_MOMENTUM, lk, k, n);
			for (int i = 0; i < group.size(); ++i) {
				_run_row(cl, group[i], lk, k, n);
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
		_fire(cl, _grain_set, _block(_grain, SLOT_ACT_WAKE_RESET, 0, 0, 1), RID(), 1);
	}
	return cl;
}

// --- the reduce plan ----------------------------------------------------------------------------------

void LAFieldDriver::plan_reduce(const Dictionary &p_plan) {
	_reduce_pipe = plan_rid(p_plan, "pipe");
	_reduce_sets = p_plan.get("sets", Array());
	_reduce_groups = plan_int(p_plan, "groups", 0);
	const int cc = plan_int(p_plan, "cell_count", 0);
	const Array rows = p_plan.get("rows", Array());

	const Dictionary op = gd_enum(REDUCE_GD, "Op");
	const Dictionary mask = gd_enum(REDUCE_GD, "Mask");
	const Dictionary nbr = gd_enum(REDUCE_GD, "Nbr");
	const int op_latch = (int)(int64_t)op["LATCH"];
	const int op_min = (int)(int64_t)op["MIN"];
	const int op_max = (int)(int64_t)op["MAX"];
	const int op_max_rel = (int)(int64_t)op["MAX_REL_DIFF"];

	_reduce_pc.clear();
	_folds.clear();
	_keys.clear();
	for (int r = 0; r < rows.size(); ++r) {
		const Dictionary row = rows[r];
		const int row_op = int(row["op"]);
		int has_aux = 0;
		if (row_str(row, "aux") != String()) {
			has_aux = row_str(row, "aux2") != String() ? 2 : 1;
		}
		int has_gate = 0;
		if (row_str(row, "gate") != String()) {
			has_gate = row_str(row, "gate_aux") != String() ? 2 : 1;
			has_gate += bool(row.get("gate_strict_lo", false)) ? 4 : 0;
			has_gate += bool(row.get("gate_both_ends", false)) ? 8 : 0;
		}
		// reduce.glsl's Params, in its declared field order.
		Block b;
		b.u32((uint32_t)cc);
		b.u32((uint32_t)row_op);
		b.u32((uint32_t)(int64_t)row.get("mask", mask["ALL"]));
		b.u32((uint32_t)(r * _reduce_groups));
		b.f32(double(row.get("threshold", 0.0)));
		// The kernel weighs each cell by ITS OWN volume; a graded grid has no one cell volume to bake in.
		b.u32(bool(row.get("weight", false)) ? 1u : 0u);
		b.u32((uint32_t)has_aux);
		b.u32((uint32_t)has_gate);
		b.f32(double(row.get("gate_lo", -std::numeric_limits<double>::infinity())));
		b.f32(double(row.get("gate_hi", std::numeric_limits<double>::infinity())));
		b.u32((uint32_t)(int64_t)row.get("nbr", nbr["NONE"]));
		_reduce_pc.append(b.take());

		int fold = FOLD_SUM;
		if (row_op == op_latch) {
			fold = FOLD_SKIP;
		} else if (row_op == op_min) {
			fold = FOLD_MIN;
		} else if (row_op == op_max || row_op == op_max_rel) {
			fold = FOLD_MAX;
		}
		_folds.append(fold);
		_keys.append(row_str(row, "key"));
	}
}

void LAFieldDriver::run_reduce(int64_t p_cl, const PackedInt32Array &p_rows) {
	if (_rd == nullptr || !_reduce_pipe.is_valid() || p_rows.is_empty()) {
		return;
	}
	_rd->compute_list_bind_compute_pipeline(p_cl, _reduce_pipe);
	for (int i = 0; i < p_rows.size(); ++i) {
		const int r = p_rows[i];
		if (r < 0 || r >= _reduce_pc.size()) {
			continue;
		}
		const RID uset = rid_at(_reduce_sets, r);
		if (!uset.is_valid()) {
			continue;
		}
		const PackedByteArray pc = _reduce_pc[r];
		_rd->compute_list_bind_uniform_set(p_cl, uset, 0);
		_rd->compute_list_set_push_constant(p_cl, pc, pc.size());
		_rd->compute_list_dispatch(p_cl, (uint32_t)_reduce_groups, 1, 1);
		_rd->compute_list_add_barrier(p_cl);
	}
}

Dictionary LAFieldDriver::fold_reduce(const RID &p_partials) {
	Dictionary out;
	if (_rd == nullptr || !p_partials.is_valid() || _reduce_groups <= 0) {
		return out;
	}
	const PackedByteArray raw = _rd->buffer_get_data(p_partials, 0, 0);
	const int n = raw.size() / 4;
	const float *v = (const float *)raw.ptr();
	const int rows = _folds.size() < _keys.size() ? _folds.size() : _keys.size();
	for (int r = 0; r < rows; ++r) {
		const int fold = _folds[r];
		if (fold == FOLD_SKIP) {
			continue;
		}
		const int base = r * _reduce_groups;
		if (base + _reduce_groups > n) {
			continue;
		}
		double acc = fold == FOLD_MIN ? std::numeric_limits<double>::infinity()
									  : (fold == FOLD_MAX ? -std::numeric_limits<double>::infinity() : 0.0);
		for (int g = 0; g < _reduce_groups; ++g) {
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
		out[_keys[r]] = acc;
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
	ClassDB::bind_static_method("LAFieldDriver", D_METHOD("transport_groups", "records"),
			&LAFieldDriver::transport_groups);
	ClassDB::bind_static_method("LAFieldDriver", D_METHOD("transport_group_count", "records"),
			&LAFieldDriver::transport_group_count);
	ClassDB::bind_method(D_METHOD("plan_transport", "plan"), &LAFieldDriver::plan_transport);
	ClassDB::bind_method(D_METHOD("run_peak", "compute_list", "seed_workgroups", "step"),
			&LAFieldDriver::run_peak);
	ClassDB::bind_method(D_METHOD("run_transport", "compute_list", "peaks", "step",
								  "seed_workgroups", "list_workgroups"),
			&LAFieldDriver::run_transport);
	ClassDB::bind_method(D_METHOD("build_levels", "compute_list", "group", "levels", "step"),
			&LAFieldDriver::build_levels);
	ClassDB::bind_method(D_METHOD("plan_reduce", "plan"), &LAFieldDriver::plan_reduce);
	ClassDB::bind_method(D_METHOD("run_reduce", "compute_list", "rows"), &LAFieldDriver::run_reduce);
	ClassDB::bind_method(D_METHOD("fold_reduce", "partials"), &LAFieldDriver::fold_reduce);
}
