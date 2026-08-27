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

// Kilograms of each substance in one cell, keyed by LASubstances id: mol/m^3 times molar mass times the
// cell's own volume. Gas is matter with heat capacity like any other and is counted with the rest.
Dictionary LAFieldCellMass3D::masses_at(Object *p_field, int p_c, double p_cell_m3) {
	Dictionary out;
	if (!p_field || p_c < 0) {
		return out;
	}
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const Dictionary table = LASubstances::table();
	const Array names = rows.keys();
	for (int i = 0; i < names.size(); i++) {
		const String name = names[i];
		const Dictionary row = rows[name];
		const String sub = String(row.get("substance", ""));
		if (sub.is_empty() || String(row.get("unit", "")) != "mol_m3") {
			continue;
		}
		const Variant v = p_field->get("_" + name);
		if (v.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
			continue;
		}
		const PackedFloat32Array arr = v;
		if (p_c >= arr.size() || !(arr[p_c] > 0.0f)) {
			continue;
		}
		const Dictionary srow = table.get(sub, Dictionary());
		const double kg = double(arr[p_c]) * double(srow.get("molar_mass", 0.0)) * p_cell_m3;
		out[sub] = double(out.get(sub, 0.0)) + kg;
	}
	return out;
}

// Moles of gas in one cell: a channel amount is mol/m^3, so it is that times the cell's own volume.
double LAFieldCellMass3D::gas_moles_at(Object *p_field, int p_c, double p_cell_m3) {
	if (!p_field || p_c < 0) {
		return 0.0;
	}
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const Array names = rows.keys();
	double n = 0.0;
	for (int i = 0; i < names.size(); i++) {
		const String name = names[i];
		const Dictionary row = rows[name];
		if (String(row.get("phase", "")) != "gas" || String(row.get("substance", "")).is_empty()) {
			continue;
		}
		const Variant v = p_field->get("_" + name);
		if (v.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
			continue;
		}
		const PackedFloat32Array arr = v;
		if (p_c < arr.size() && arr[p_c] > 0.0f) {
			n += double(arr[p_c]) * p_cell_m3;
		}
	}
	return n;
}

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
	ClassDB::bind_static_method("LAFieldCellMass3D",
			D_METHOD("masses_at", "field", "cell", "cell_m3"), &LAFieldCellMass3D::masses_at);
	ClassDB::bind_static_method("LAFieldCellMass3D",
			D_METHOD("gas_moles_at", "field", "cell", "cell_m3"), &LAFieldCellMass3D::gas_moles_at);
	ClassDB::bind_static_method("LAFieldCellMass3D", D_METHOD("mirrors", "field"),
			&LAFieldCellMass3D::mirrors);
	ClassDB::bind_static_method("LAFieldCellMass3D", D_METHOD("mirror_names", "field"),
			&LAFieldCellMass3D::mirror_names);
	ClassDB::bind_static_method("LAFieldCellMass3D", D_METHOD("gas_mirrors", "field"),
			&LAFieldCellMass3D::gas_mirrors);
	ClassDB::bind_static_method("LAFieldCellMass3D", D_METHOD("kg_m3_at", "mirrors", "c"),
			&LAFieldCellMass3D::kg_m3_at);
}
