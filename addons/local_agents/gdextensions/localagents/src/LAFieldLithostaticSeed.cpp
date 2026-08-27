#include "LAFieldLithostaticSeed.hpp"

#include "LABodySystem.hpp"
#include "LAFieldCellMass.hpp"
#include "LAPhysicalRead.hpp"
#include "LAScriptCall.hpp"
#include "LASubstances.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cmath>
#include <vector>

using namespace godot;

namespace {

const char *CHANNELS_GD = "res://addons/local_agents/sim/material/Channels.gd";
const char *GEOMETRY_GD = "res://addons/local_agents/sim/material/FieldGeometry3D.gd";
const char *FIELD_GD = "res://addons/local_agents/sim/material/MaterialField3D.gd";

Vector3 field_centre(Object *p_field) {
	Array args;
	args.append(p_field);
	return la_call_gd(GEOMETRY_GD, "centre", args);
}

// A channel mirror, held by NAME so it can be written back: a godot-cpp Packed array is copy-on-write, so
// mutating the local never reaches the field on its own.
struct Mirror {
	String name;
	String substance;
	PackedFloat32Array arr;
};

// Every channel whose row answers `p_value` under `p_key` and whose mirror is the right size. `p_value`
// empty means the row's flag is a bool that must be true.
std::vector<Mirror> channel_mirrors(Object *p_field, const String &p_key, const String &p_value) {
	std::vector<Mirror> out;
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const int cc = int(p_field->get("_cell_count"));
	const Array names = rows.keys();
	for (int i = 0; i < names.size(); i++) {
		const String name = names[i];
		const Dictionary row = rows[name];
		const bool wanted = p_value.is_empty() ? bool(row.get(p_key, false))
											 : String(row.get(p_key, "")) == p_value;
		if (!wanted) {
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
		out.push_back({ name, String(row.get("substance", "")), arr });
	}
	return out;
}

// Scale every gas channel by a per-cell factor. ONE walk: three hand-written subsets of the gas list left
// h2, co, so2, h2s and ch4 at their seeded density inside the stone and out through the vacuum.
void scale_gases(Object *p_field, const PackedFloat32Array &p_factor) {
	std::vector<Mirror> gases = channel_mirrors(p_field, "phase", "gas");
	const int cc = p_factor.size();
	for (Mirror &m : gases) {
		float *w = m.arr.ptrw();
		for (int c = 0; c < cc; c++) {
			w[c] *= p_factor[c];
		}
		p_field->set("_" + m.name, m.arr);
	}
}

PackedFloat32Array unit_factor(int p_cc) {
	PackedFloat32Array f;
	f.resize(p_cc);
	f.fill(1.0f);
	return f;
}

} // namespace

double LAFieldLithostaticSeed::compress(Object *p_field) {
	if (!p_field) {
		return 0.0;
	}
	Object *grid = Object::cast_to<Object>(p_field->get("_grid"));
	const int cc = int(p_field->get("_cell_count"));
	const PackedFloat32Array silicate = p_field->get("_silicate");
	if (!grid || cc <= 0 || silicate.size() != cc) {
		return 0.0;
	}
	const Vector3 centre = field_centre(p_field);
	const double dr = double(grid->get("cell_size"));
	const double cell_vol = dr * dr * dr;
	const Dictionary table = LASubstances::table();
	const Array mirrors = LAFieldCellMass3D::mirrors(p_field);
	std::vector<Mirror> lithic;
	for (Mirror &m : channel_mirrors(p_field, "lithic", String())) {
		if (m.substance != String() && table.has(m.substance)) {
			lithic.push_back(m);
		}
	}
	const int bins = int(std::ceil(double(grid->call("max_span")) / dr)) + 2;
	PackedFloat64Array mass_kg;
	mass_kg.resize(bins);
	PackedInt32Array cells_in;
	cells_in.resize(bins);
	PackedInt32Array bin_of;
	bin_of.resize(cc);
	for (int c = 0; c < cc; c++) {
		const Vector3 pos = grid->call("cell_world_pos", c);
		const int b = MIN(int(double((pos - centre).length()) / dr), bins - 1);
		bin_of[c] = b;
		cells_in[b] = cells_in[b] + 1;
		mass_kg[b] = mass_kg[b] + LAFieldCellMass3D::kg_m3_at(mirrors, c) * cell_vol;
	}
	// g at each bin's outer edge from the mass inside it, then p inward from one atmosphere at the top.
	PackedFloat64Array p_at;
	p_at.resize(bins);
	PackedFloat64Array g_at;
	g_at.resize(bins);
	const double bigg = la_physical("GRAVITATIONAL_CONSTANT");
	double m_in = 0.0;
	for (int b = 0; b < bins; b++) {
		m_in += mass_kg[b];
		const double r = (double(b) + 1.0) * dr;
		g_at[b] = bigg * m_in / (r * r);
	}
	double p = la_physical("STANDARD_PRESSURE_PA");
	for (int b = bins - 1; b >= 0; b--) {
		const double rho = mass_kg[b] / (double(MAX(cells_in[b], 1)) * cell_vol);
		p += rho * g_at[b] * dr;
		p_at[b] = p;
	}
	// COMPRESSION IS THE SUBSTANCE TABLE'S ANSWER, NOT THIS FILE'S. The ratio is rho(p)/rho(p_std) from
	// LASubstances, whose EOS is Birch-Murnaghan; the pressure is one per radial bin, so the table is asked
	// once per bin per phase rather than once per cell.
	const double t_c = double(la_gd_const(FIELD_GD, "INITIAL_TEMP"));
	const double p_std = la_physical("STANDARD_PRESSURE_PA");
	std::vector<PackedFloat64Array> ratio;
	for (const Mirror &m : lithic) {
		PackedFloat64Array per_bin;
		per_bin.resize(bins);
		const double rho0 = LASubstances::density(m.substance, t_c, p_std);
		for (int b = 0; b < bins; b++) {
			double r_b = 1.0;
			if (rho0 > 0.0) {
				r_b = LASubstances::density(m.substance, t_c, p_at[b]) / rho0;
			}
			per_bin[b] = (std::isfinite(r_b) && r_b > 0.0) ? r_b : 1.0;
		}
		ratio.push_back(per_bin);
	}
	const PackedByteArray solid = p_field->get("_solid");
	double added = 0.0;
	for (size_t i = 0; i < lithic.size(); i++) {
		float *w = lithic[i].arr.ptrw();
		for (int c = 0; c < cc; c++) {
			if (solid[c] == 0) {
				continue;
			}
			const double amt = double(w[c]) * ratio[i][bin_of[c]];
			added += amt - double(w[c]);
			w[c] = float(amt);
		}
		p_field->set("_" + lithic[i].name, lithic[i].arr);
	}
	return added;
}

void LAFieldLithostaticSeed::clear_gas_in_rock(Object *p_field) {
	if (!p_field) {
		return;
	}
	const int cc = int(p_field->get("_cell_count"));
	const PackedByteArray solid = p_field->get("_solid");
	if (cc <= 0 || solid.size() != cc) {
		return;
	}
	PackedFloat32Array f = unit_factor(cc);
	for (int c = 0; c < cc; c++) {
		if (solid[c] != 0) {
			f[c] = 0.0f;
		}
	}
	scale_gases(p_field, f);
}

void LAFieldLithostaticSeed::shape_atmosphere(Object *p_field, double p_temp_c, Object *p_measure) {
	if (!p_field || !p_measure) {
		return;
	}
	LABodyMeasure *m = Object::cast_to<LABodyMeasure>(p_measure);
	Object *grid = Object::cast_to<Object>(p_field->get("_grid"));
	const int cc = int(p_field->get("_cell_count"));
	const PackedByteArray solid = p_field->get("_solid");
	if (!m || !grid || cc <= 0 || solid.size() != cc || !m->measured()) {
		return;
	}
	const double scale_h = m->scale_height_m(p_temp_c);
	if (!std::isfinite(scale_h) || scale_h <= 0.0) {
		return;
	}
	const Vector3 centre = field_centre(p_field);
	const double edge = double(grid->get("cell_size"));
	// A CELL CANNOT HOLD A PROFILE SHORTER THAN ITSELF. Where the scale height is under a cell edge the
	// whole atmosphere sits inside the first open shell, and a per-cell exponential is a shape the grid
	// cannot carry; the honest seed is gas in that shell and vacuum beyond it. docs/PHYSICS_TODO.md D.
	const bool flat = scale_h < edge;
	PackedFloat32Array f = unit_factor(cc);
	for (int c = 0; c < cc; c++) {
		if (solid[c] != 0) {
			continue;
		}
		const Vector3 pos = grid->call("cell_world_pos", c);
		const double above = MAX(double((pos - centre).length()) - m->get_surface_r_m(), 0.0);
		f[c] = float(flat ? (above <= edge ? 1.0 : 0.0) : std::exp(-above / scale_h));
	}
	scale_gases(p_field, f);
}

void LAFieldLithostaticSeed::displace_gas_from_water(Object *p_field) {
	if (!p_field) {
		return;
	}
	const int cc = int(p_field->get("_cell_count"));
	const PackedFloat32Array h2o = p_field->get("_h2o");
	if (cc <= 0 || h2o.size() != cc) {
		return;
	}
	const double full = LASubstances::full_mol_m3("h2o");
	if (!(full > 0.0)) {
		return;
	}
	PackedFloat32Array f = unit_factor(cc);
	for (int c = 0; c < cc; c++) {
		f[c] = float(CLAMP(1.0 - double(h2o[c]) / full, 0.0, 1.0));
	}
	scale_gases(p_field, f);
}

void LAFieldLithostaticSeed::_bind_methods() {
	ClassDB::bind_static_method("LAFieldLithostaticSeed", D_METHOD("compress", "field"),
			&LAFieldLithostaticSeed::compress);
	ClassDB::bind_static_method("LAFieldLithostaticSeed", D_METHOD("clear_gas_in_rock", "field"),
			&LAFieldLithostaticSeed::clear_gas_in_rock);
	ClassDB::bind_static_method("LAFieldLithostaticSeed",
			D_METHOD("shape_atmosphere", "field", "temp_c", "measure"),
			&LAFieldLithostaticSeed::shape_atmosphere);
	ClassDB::bind_static_method("LAFieldLithostaticSeed", D_METHOD("displace_gas_from_water", "field"),
			&LAFieldLithostaticSeed::displace_gas_from_water);
}
