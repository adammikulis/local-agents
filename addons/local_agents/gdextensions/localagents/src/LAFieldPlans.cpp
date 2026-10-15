#include "LAFieldDriver.hpp"

#include "LAPhysicalRead.hpp"
#include "LAProcessSet.hpp"
#include "LAScriptCall.hpp"
#include "LASubstances.hpp"

#include <godot_cpp/classes/script.hpp>
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

void LAFieldDriver::_encode_transport(const Dictionary &p_plan) {
	_pipe = plan_rid(p_plan, "pipe");
	_row_sets = p_plan.get("row_sets", Array());
	_args = plan_rid(p_plan, "args");
	_wake_args = plan_rid(p_plan, "wake_args");
	_grain_set = plan_rid(p_plan, "grain_set");
	_list_sets = p_plan.get("list_sets", Array());
	_queue_bin = plan_int(p_plan, "queue_bin", 0);
	_slots = plan_int(p_plan, "slots", 0);

	const int cc = plan_int(p_plan, "cell_count", 0);
	const int total = plan_int(p_plan, "total_count", cc);
	const int bands = plan_int(p_plan, "band_count", 0);
	const Array records = p_plan.get("rows", Array());
	const Dictionary grain = p_plan.get("grain_record", Dictionary());
	const Array lists = p_plan.get("list_records", Array());

	_groups = LAFieldDriver::transport_groups(records);
	_group_count = _groups.size() + 1;
	const int gslot = _groups.size();

	_transport_rows.clear();
	_transport_rows.resize(records.size());
	for (int r = 0; r < records.size(); ++r) {
		_transport_rows[r].group = 0;
	}
	for (int g = 0; g < _groups.size(); ++g) {
		const PackedInt32Array group = _groups[g];
		for (int i = 0; i < group.size(); ++i) {
			_transport_rows[group[i]].group = g;
		}
	}
	for (int r = 0; r < records.size(); ++r) {
		_encode(_transport_rows[r], records[r], cc, total, bands, _transport_rows[r].group);
	}
	// THE HEAD carries its group's face solve, its levels and its activity; every member seeds a level
	// and asks for its own peak; the momentum record closes the group and moves no matter of its own.
	const int mode_radiate = gd_int(TRANSPORT_GD, "RADIATE");
	for (int g = 0; g < _groups.size(); ++g) {
		const PackedInt32Array group = _groups[g];
		Row &head = _transport_rows[group[0]];
		head.slots |= (1u << SLOT_LEVEL_RESET) | (1u << SLOT_ACT_AGE) |
				(1u << SLOT_ACT_WAKE) | (1u << SLOT_ACT_MARK) | (1u << SLOT_LEVEL_SCAN) |
				(1u << SLOT_LEVEL_SORT) | (1u << SLOT_FACE);
		for (int i = 0; i < group.size(); ++i) {
			const Dictionary row = records[group[i]];
			Row &dst = _transport_rows[group[i]];
			dst.slots |= (1u << SLOT_LEVEL_SEED);
			if (!vel_row(row)) {
				dst.slots |= (1u << SLOT_OUTFLOW) | (1u << SLOT_GATHER);
			}
			if (int(row["mode"]) == mode_radiate) {
				dst.slots |= (1u << SLOT_SW);
			}
		}
		const int last = group[group.size() - 1];
		if (vel_row(records[last])) {
			_transport_rows[last].slots |= (1u << SLOT_MOMENTUM) | (1u << SLOT_MOMENTUM_APPLY);
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
		Array channel_args;
		channel_args.append(p_row["channel"]);
		cap = double(entry.get("molar_mass", 0.0))
				* double(la_call_gd(MATTER_GD, "channel_specific_heat", channel_args));
		if (!std::isfinite(cap) || cap < 0.0) {
			_abort = "transport/invalid_heat_capacity";
			UtilityFunctions::push_error(vformat("LAFieldDriver: channel %s has no valid heat capacity", p_row["channel"]));
			return;
		}
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
	p_dst.block = b.take();
	p_dst.slots = 0;
	p_dst.group = p_group;
}

void LAFieldDriver::_stamp_one(Row &p_row, float p_dt, const Vector3 &p_sun, float p_xuv, float p_phi) {
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
}

// THE SCALARS THAT ARE THE STEP'S, not the record's: the interval it integrates, where the star is,
// what it delivers, and the potential's datum.
void LAFieldDriver::_stamp_step(const Dictionary &p_step) {
	const float dt = (float)(double)p_step.get("dt_s", 0.0);
	const Vector3 sun = p_step.get("sun", Vector3());
	const float xuv = (float)(double)p_step.get("xuv_w_m2", 0.0);
	const float phi = (float)(double)p_step.get("phi_datum", 0.0);
	for (Row &r : _transport_rows) {
		_stamp_one(r, dt, sun, xuv, phi);
	}
	_stamp_one(_grain, dt, sun, xuv, phi);
	for (Row &r : _lists) {
		_stamp_one(r, dt, sun, xuv, phi);
	}
}

// A record with no entry in the mask is live: a plan that declares none is a plan with no switches.

Array LAFieldDriver::_table(const Row &p_row) const {
	static constexpr uint32_t tags[SLOT_COUNT] = {0, 1, 6, 7, 8, 14, 15, 16, 11, 12, 10, 9, 2, 18, 17, 3, 4, 5, 19};
	Array table;
	table.resize(SLOT_COUNT);
	for (int slot = 0; slot < SLOT_COUNT; ++slot) {
		PackedByteArray block;
		if ((p_row.slots & (1u << slot)) != 0 && !p_row.block.is_empty()) {
			block = p_row.block.duplicate();
			put_u32(block.ptrw(), _off.pass, tags[slot]);
			if (slot == SLOT_ACT_SEED) { put_u32(block.ptrw(), _off.act_group, uint32_t(_group_count)); }
		}
		table[slot] = block;
	}
	return table;
}

Dictionary LAFieldDriver::transport_blocks(const Dictionary &p_step) {
	_stamp_step(p_step);
	Array rows, lists;
	for (const Row &row : _transport_rows) { rows.append(_table(row)); }
	for (const Row &row : _lists) { lists.append(_table(row)); }
	Dictionary out;
	out["rows"] = rows;
	out["grain"] = _table(_grain);
	out["lists"] = lists;
	return out;
}
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
	_reduce_costs.clear();
	for (int r = 0; r < rows.size(); ++r) {
		const Dictionary row = rows[r];
		const int row_op = int(row["op"]);
		int has_aux = row_str(row, "less") != String() ? 3 : 0;
		if (has_aux == 0 && row_str(row, "aux") != String()) {
			has_aux = row_str(row, "aux2") != String() ? 2 : 1;
		}
		int has_gate = 0;
		if (row_str(row, "gate") != String()) {
			has_gate = row_str(row, "gate_aux") != String() ? 2 : 1;
			has_gate += bool(row.get("gate_strict_lo", false)) ? 4 : 0;
			has_gate += bool(row.get("gate_both_ends", false)) ? 8 : 0;
		}
		const PackedStringArray held = la_gd_const(REDUCE_GD, "HELD_SOURCES");
		if (held.has(row_str(row, "source"))) { has_gate |= 16; }
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
		const PackedByteArray pc = b.take();
		PackedByteArray kind = pc.slice(4, 12);
		kind.append_array(pc.slice(20, 32));
		kind.append_array(pc.slice(40, 44));
		_reduce_costs.append("reduce/" + kind.hex_encode());

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

void LAFieldDriver::run_reduce(const PackedInt32Array &p_rows) {
	ERR_FAIL_COND_MSG(!_open, "LAFieldDriver: run_reduce() outside open() and close().");
	for (int i = 0; i < p_rows.size() && _abort.empty(); ++i) {
		const int row = p_rows[i];
		ERR_FAIL_INDEX(row, _reduce_pc.size());
		const RID uset = _reduce_sets[row];
		const String cost = _reduce_costs[row];
		_plan(std::string(cost.utf8().get_data()), _reduce_pipe, uset, _reduce_pc[row],
				_reduce_groups, RID(), 0, true);
	}
}

Dictionary LAFieldDriver::reduce_plan() const {
	Dictionary out;
	out["pc"] = _reduce_pc;
	out["folds"] = _folds;
	out["keys"] = _keys;
	out["groups"] = _reduce_groups;
	return out;
}


PackedByteArray LAFieldDriver::peak_block(int p_row, int p_group, const Dictionary &p_step) {
	ERR_FAIL_INDEX_V(p_row, int(_transport_rows.size()), PackedByteArray());
	_stamp_step(p_step);
	if (_transport_rows[p_row].block.is_empty()) { return PackedByteArray(); }
	PackedByteArray block = _transport_rows[p_row].block.duplicate();
	put_u32(block.ptrw(), _off.pass, 13u);
	put_u32(block.ptrw(), _off.level, uint32_t(p_group));
	return block;
}
