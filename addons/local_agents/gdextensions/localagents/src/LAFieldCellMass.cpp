#include "LAFieldCellMass.hpp"

#include "LAScriptCall.hpp"
#include "LASubstances.hpp"
#include "LAMixtureEnthalpy.hpp"
#include "LAPhysicalRead.hpp"

#include <algorithm>
#include <cmath>
#include <vector>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

using namespace godot;

namespace {

const char *CHANNELS_GD = "res://addons/local_agents/sim/material/Channels.gd";
const char *TRANSPORT_PASS_GD = "res://addons/local_agents/sim/material/sphere_passes/TransportPass.gd";

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
// cell's own volume. Gas is matter with heat capacity like any other and is counted with the rest. EMPTY
// for a cell under the bulk-density floor state_derive.glsl empties on: it holds no bulk state at all.
Dictionary LAFieldCellMass3D::masses_at(Object *p_field, int p_c, double p_cell_m3) {
	Dictionary out;
	if (!p_field || p_c < 0) {
		return out;
	}
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const Dictionary table = LASubstances::table();
	const Array names = rows.keys();
	double total_kg = 0.0;
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
		total_kg += kg;
	}
	if (!(total_kg > 0.0)) {
		return Dictionary();
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

Dictionary LAFieldCellMass3D::seed_enthalpy(Object *p_field, Object *p_grid,
		const PackedFloat32Array &p_profile, double p_r_body, double p_t_surface_c,
		const PackedFloat32Array &p_p_pa) {
	Dictionary out;
	if (!p_field || !p_grid) {
		return out;
	}
	const int cc = int(p_field->get("_cell_count"));
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const Dictionary table = LASubstances::table();
	const char *MATTER_GD = "res://addons/local_agents/sim/material/MatterChannels.gd";
	// Every matter channel once: its mirror, substance, molar mass, entry, sensible capacity, gas flag.
	struct Chan { PackedFloat32Array arr; String sub; double molar; int entry; double cap; bool gas; };
	std::vector<Chan> chans;
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
		Chan ch;
		ch.arr = v;
		if (ch.arr.size() != cc) {
			continue;
		}
		ch.sub = sub;
		ch.molar = double(Dictionary(table.get(sub, Dictionary())).get("molar_mass", 0.0));
		Array a1;
		a1.append(sub);
		ch.entry = int(la_call_gd(MATTER_GD, "entry_of", a1));
		ch.cap = double(la_call_gd(MATTER_GD, "specific_heat", a1));
		ch.gas = String(row.get("phase", "")) == "gas";
		chans.push_back(ch);
	}
	const PackedVector3Array centres = p_grid->get("centres");
	const PackedFloat32Array vol = p_grid->call("cell_volumes");
	const Vector3 centre = p_field->call("centre");
	const double kelvin = la_physical("KELVIN_OFFSET");
	const int samples = p_profile.size();
	PackedFloat32Array h;
	h.resize(cc);
	float *hw = h.ptrw();
	double total_j = 0.0;
	for (int c = 0; c < cc; c++) {
		hw[c] = 0.0f;
		const double cell_m3 = c < vol.size() ? double(vol[c]) : 0.0;
		if (!(cell_m3 > 0.0) || c >= p_p_pa.size() || c >= centres.size()) {
			continue;
		}
		const double r = double((centres[c] - centre).length());
		double t_c = p_t_surface_c;
		if (samples >= 2 && p_r_body > 0.0 && r < p_r_body) {
			const double x = r / p_r_body * double(samples - 1);
			int i = int(std::floor(x));
			i = std::min(std::max(i, 0), samples - 2);
			t_c = double(p_profile[i]) + (double(p_profile[i + 1]) - double(p_profile[i])) * (x - double(i)) - kelvin;
		}
		const double p_pa = std::max(double(p_p_pa[c]), 0.0);
		double n_gas = 0.0, m_h2o = 0.0, m_sil = 0.0, mc = 0.0, total_kg = 0.0;
		for (const Chan &ch : chans) {
			const double a = double(ch.arr[c]);
			if (!(a > 0.0)) {
				continue;
			}
			const double m = a * ch.molar * cell_m3;
			total_kg += m;
			if (ch.gas) {
				n_gas += a * cell_m3;
			}
			if (ch.entry == 0) {
				m_h2o += m;
			} else if (ch.entry == 1) {
				m_sil += m;
			} else {
				mc += m * ch.cap;
			}
		}
		if (!(total_kg > 0.0)) {
			continue;   // no matter, no joules to hold
		}
		double h_j = mc * (t_c + kelvin);
		if (m_h2o > 0.0) {
			h_j += m_h2o * LAMixtureEnthalpy::specific_enthalpy("h2o", t_c, p_pa, m_h2o, n_gas);
		}
		if (m_sil > 0.0) {
			h_j += m_sil * LAMixtureEnthalpy::specific_enthalpy("silicate", t_c, p_pa, m_sil, n_gas);
		}
		hw[c] = float(h_j / cell_m3);
		total_j += h_j;
	}
	out["h"] = h;
	out["total_j"] = total_j;
	return out;
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
	ClassDB::bind_static_method("LAFieldCellMass3D",
			D_METHOD("seed_enthalpy", "field", "grid", "profile", "r_body", "t_surface_c", "p_pa"),
			&LAFieldCellMass3D::seed_enthalpy);
	ClassDB::bind_static_method("LAFieldCellMass3D", D_METHOD("mirrors", "field"),
			&LAFieldCellMass3D::mirrors);
	ClassDB::bind_static_method("LAFieldCellMass3D", D_METHOD("mirror_names", "field"),
			&LAFieldCellMass3D::mirror_names);
	ClassDB::bind_static_method("LAFieldCellMass3D", D_METHOD("gas_mirrors", "field"),
			&LAFieldCellMass3D::gas_mirrors);
	ClassDB::bind_static_method("LAFieldCellMass3D", D_METHOD("kg_m3_at", "mirrors", "c"),
			&LAFieldCellMass3D::kg_m3_at);
}
