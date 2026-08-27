#include "LAFieldCellMass.hpp"

#include "LAScriptCall.hpp"
#include "LASubstances.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

using namespace godot;

namespace {

const char *CHANNELS_GD = "res://addons/local_agents/sim/material/Channels.gd";

// The mirrors of every channel whose row passes `p_want`, paired with the molar mass of its substance.
Array walk(Object *p_field, const String &p_key, const String &p_value, bool p_names_only,
		PackedStringArray *r_names) {
	Array out;
	if (!p_field) {
		return out;
	}
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const Dictionary table = LASubstances::table();
	const int cc = int(p_field->get("_cell_count"));
	const Array names = rows.keys();
	for (int i = 0; i < names.size(); i++) {
		const String name = names[i];
		const Dictionary row = rows[name];
		if (String(row.get(p_key, "")) != p_value) {
			continue;
		}
		const Variant v = p_field->get("_" + name);
		if (v.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
			continue;
		}
		const PackedFloat32Array arr = v;
		if (arr.size() != cc) {
			continue;
		}
		if (p_names_only) {
			r_names->append(name);
			continue;
		}
		const Dictionary s = table.get(String(row.get("substance", "")), Dictionary());
		Array pair;
		pair.append(arr);
		pair.append(double(s.get("molar_mass", 0.0)));
		out.append(pair);
	}
	return out;
}

} // namespace

Array LAFieldCellMass3D::mirrors(Object *p_field) {
	return walk(p_field, "unit", "mol_m3", false, nullptr);
}

PackedStringArray LAFieldCellMass3D::mirror_names(Object *p_field) {
	PackedStringArray out;
	walk(p_field, "unit", "mol_m3", true, &out);
	return out;
}

Array LAFieldCellMass3D::gas_mirrors(Object *p_field) {
	return walk(p_field, "phase", "gas", false, nullptr);
}

double LAFieldCellMass3D::kg_m3_at(const Array &p_mirrors, int p_c) {
	double m = 0.0;
	for (int i = 0; i < p_mirrors.size(); i++) {
		const Array pair = p_mirrors[i];
		const PackedFloat32Array arr = pair[0];
		m += MAX(double(arr[p_c]), 0.0) * double(pair[1]);
	}
	return m;
}

void LAFieldCellMass3D::_bind_methods() {
	ClassDB::bind_static_method("LAFieldCellMass3D", D_METHOD("mirrors", "field"),
			&LAFieldCellMass3D::mirrors);
	ClassDB::bind_static_method("LAFieldCellMass3D", D_METHOD("mirror_names", "field"),
			&LAFieldCellMass3D::mirror_names);
	ClassDB::bind_static_method("LAFieldCellMass3D", D_METHOD("gas_mirrors", "field"),
			&LAFieldCellMass3D::gas_mirrors);
	ClassDB::bind_static_method("LAFieldCellMass3D", D_METHOD("kg_m3_at", "mirrors", "c"),
			&LAFieldCellMass3D::kg_m3_at);
}
