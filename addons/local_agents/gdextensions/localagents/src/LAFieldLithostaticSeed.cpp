#include "LAFieldLithostaticSeed.hpp"

#include "LABodySystem.hpp"
#include "LAFieldCellMass.hpp"
#include "LAPhysicalRead.hpp"
#include "LAProcessSet.hpp"
#include "LAScriptCall.hpp"
#include "LASubstances.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>
#include <vector>

using namespace godot;

namespace {

const char *CHANNELS_GD = "res://addons/local_agents/sim/material/Channels.gd";
const char *GEOMETRY_GD = "res://addons/local_agents/sim/material/FieldGeometry3D.gd";
const char *FIELD_GD = "res://addons/local_agents/sim/material/MaterialField3D.gd";

// The hydrostatic seed's Gauss-Seidel: over-relaxation factor, sweeps per frozen reconstruction,
// re-takes of it, and the move below which a sweep has settled.

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
// Lay each gas along `p_shape` and keep its total. Cells are one volume, so the moles are the amounts.
// A NEGATIVE share is a cell the profile does not reach: it keeps what it holds and joins neither sum.
void redistribute_gases(Object *p_field, const PackedFloat32Array &p_shape) {
	std::vector<Mirror> gases = channel_mirrors(p_field, "phase", "gas");
	const int cc = p_shape.size();
	for (Mirror &m : gases) {
		float *w = m.arr.ptrw();
		double had = 0.0;
		double laid = 0.0;
		for (int c = 0; c < cc; c++) {
			if (p_shape[c] < 0.0f) {
				continue;
			}
			had += double(w[c]);
			laid += double(w[c]) * double(p_shape[c]);
		}
		if (!(had > 0.0) || !(laid > 0.0)) {
			continue;
		}
		const double k = had / laid;
		for (int c = 0; c < cc; c++) {
			if (p_shape[c] >= 0.0f) {
				w[c] = float(double(w[c]) * double(p_shape[c]) * k);
			}
		}
		p_field->set("_" + m.name, m.arr);
	}
}

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

// Outward unit normal of face slot d. Slot order -X,+X,-Y,+Y,-Z,+Z, as LAVoxelGrid lays it out.
Vector3 slot_normal(int p_d) {
	Vector3 n;
	n[p_d >> 1] = (p_d & 1) ? 1.0 : -1.0;
	return n;
}

// The slot whose step points most nearly along `p_dir`.
int slot_toward(const Vector3 &p_dir) {
	int best = 0;
	double best_dot = -1.0e30;
	for (int d = 0; d < 6; d++) {
		const double dp = p_dir.dot(slot_normal(d));
		if (dp > best_dot) {
			best_dot = dp;
			best = d;
		}
	}
	return best;
}

double eos_p(double vol, double a_gas_rt, double b_vol, double c_comp, double p_std, double p_sat) {
	if (vol <= 0.0) {
		return 0.0;
	}
	// Nothing compressible: the gas fills what the condensed phases leave.
	if (c_comp <= 0.0) {
		double room = vol - b_vol;
		return MAX(room > 0.0 ? a_gas_rt / room : 0.0, p_sat);
	}
	// No gas of its own: the condensed phases alone are squeezed into the cell, and the void they leave
	// is their vapour.
	if (a_gas_rt <= 0.0) {
		return MAX(p_std + (b_vol - vol) / c_comp, p_sat);
	}
	double k = vol - b_vol - c_comp * p_std;
	double disc = sqrt(k * k + 4.0 * c_comp * a_gas_rt);
	// Stable root of the same quadratic: for k > 0, (disc - k)/(2C) cancels catastrophically as C -> 0
	// and one ulp over 2C is an arbitrary pressure; 2A/(k + disc) is algebraically identical, sums
	// positives, and limits exactly to the ideal-gas A/k.
	double p = (k > 0.0) ? 2.0 * a_gas_rt / (k + disc) : (disc - k) / (2.0 * c_comp);
	return MAX(p, p_sat);
}

PackedFloat32Array unit_factor(int p_cc) {
	PackedFloat32Array f;
	f.resize(p_cc);
	f.fill(1.0f);
	return f;
}

} // namespace

PackedFloat32Array LAFieldLithostaticSeed::vertical(Object *p_field,
		const PackedFloat32Array &p_gravity) {
	const int cc = p_field ? int(p_field->get("_cell_count")) : 0;
	if (LAProcessSet::has_record("pass", "PressurePass.gd", LAProcessSet::ANY)
			&& p_gravity.size() == cc * 3) {
		return p_gravity;
	}
	PackedFloat32Array z;
	z.resize(MAX(cc, 0) * 3);
	z.fill(0.0f);
	return z;
}

PackedFloat32Array LAFieldLithostaticSeed::compress(Object *p_field,
		const PackedFloat32Array &p_gravity) {
	PackedFloat32Array out;
	if (!p_field) {
		return out;
	}
	Object *grid = Object::cast_to<Object>(p_field->get("_grid"));
	const int cc = int(p_field->get("_cell_count"));
	const PackedByteArray solid = p_field->get("_solid");
	if (!grid || cc <= 0 || solid.size() != cc) {
		return out;
	}
	if (p_gravity.size() != cc * 3) {
		UtilityFunctions::push_error(String("LAFieldLithostaticSeed.compress: the solved gravity is ")
				+ String::num_int64(p_gravity.size()) + " long against " + String::num_int64(cc)
				+ " cells, so the balance has no direction to march along.");
		return out;
	}
	const Vector3 centre = field_centre(p_field);
	const double dr = double(grid->get("cell_size"));
	const double vol = dr * dr * dr;
	// A neighbour table the march cannot walk costs it its COLUMN, not the pressure each cell states.
	const PackedInt32Array nbr = grid->get("neighbours");
	const bool walkable = nbr.size() == cc * 6;
	const Dictionary table = LASubstances::table();
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const double t_c = double(la_gd_const(FIELD_GD, "INITIAL_TEMP"));
	const double p_std = la_physical("STANDARD_PRESSURE_PA");
	const double rt = la_physical("GAS_CONSTANT_J_MOL_K") * (t_c + la_physical("KELVIN_OFFSET"));

	// Every matter channel, with what the substance table says about the substance it carries.
	std::vector<Mirror> mats = channel_mirrors(p_field, "unit", "mol_m3");
	const size_t nm = mats.size();
	std::vector<double> mm(nm, 0.0), v0(nm, 0.0), v0k(nm, 0.0), rho0(nm, 0.0), psat(nm, 0.0);
	std::vector<bool> is_gas(nm, false), is_lithic(nm, false);
	for (size_t i = 0; i < nm; i++) {
		const Dictionary row = rows.get(mats[i].name, Dictionary());
		const Dictionary sub = table.get(mats[i].substance, Dictionary());
		mm[i] = double(sub.get("molar_mass", 0.0));
		is_gas[i] = String(row.get("phase", "")) == "gas";
		is_lithic[i] = bool(row.get("lithic", false)) && !mats[i].substance.is_empty()
				&& table.has(mats[i].substance);
		if (is_gas[i]) {
			continue;
		}
		psat[i] = LASubstances::saturation_p_at(mats[i].substance, t_c);
		rho0[i] = LASubstances::density(mats[i].substance, t_c, p_std);
		v0[i] = rho0[i] > 0.0 ? 1.0 / rho0[i] : 0.0;
		const double k = double(sub.get("bulk_modulus_pa", 0.0));
		v0k[i] = k > 0.0 ? v0[i] / k : 0.0;
	}

	// la_eos_p's own coefficients per cell at the amounts the composition laid down, and the mass those
	// amounts weigh. A gas is the A term; a condensed phase is B, and C where it declares a bulk modulus.
	std::vector<double> a_rt(cc, 0.0), b_vol(cc, 0.0), c_comp(cc, 0.0), rho(cc, 0.0), p_sat(cc, 0.0);
	for (size_t i = 0; i < nm; i++) {
		const float *r = mats[i].arr.ptr();
		for (int c = 0; c < cc; c++) {
			const double n = r[c] > 0.0f ? double(r[c]) : 0.0;
			if (n <= 0.0) {
				continue;
			}
			rho[c] += n * mm[i];
			if (is_gas[i]) {
				a_rt[c] += n * vol * rt;
			} else {
				const double kg = n * vol * mm[i];
				b_vol[c] += kg * v0[i];
				c_comp[c] += kg * v0k[i];
				p_sat[c] = MAX(p_sat[c], psat[i]);
			}
		}
	}

	// kernels3d/pressure.glsl's la_load: the weight per unit area of one cell's matter, Pa, over the
	// step's projection on the local vertical.
	auto column_load = [&](int c) -> double {
		const Vector3 gv(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		const double gm = double(gv.length());
		if (!(gm > 0.0)) {
			return 0.0;
		}
		const Vector3 up = -gv / gm;
		const double m = MAX(MAX(std::abs(up.x), std::abs(up.y)), std::abs(up.z));
		return rho[c] * gm * dr * m;
	};

	// A cell stands at the pressure its own amounts state, off the same equation of state the derive uses.
	std::vector<double> p_at(cc, 0.0);
	for (int c = 0; c < cc; c++) {
		if (rho[c] > 0.0) {
			p_at[c] = eos_p(vol, a_rt[c], b_vol[c], c_comp[c], p_std, p_sat[c]);
		}
	}

	// Height along the local vertical and the slot pointing up it: rock's column marches these.
	std::vector<double> h(cc, 0.0);
	std::vector<int> up_slot(cc, -1);
	for (int c = 0; c < cc; c++) {
		const Vector3 g(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		const double gm = double(g.length());
		if (!(gm > 0.0)) {
			continue;
		}
		const Vector3 up = -g / gm;
		h[c] = double((Vector3(grid->call("cell_world_pos", c)) - centre).dot(up));
		up_slot[c] = slot_toward(up);
	}
	std::vector<int> order(cc);
	std::iota(order.begin(), order.end(), 0);
	std::sort(order.begin(), order.end(), [&h](int a, int b) { return h[a] > h[b]; });

	// AN OPEN CELL STANDS AT THE PRESSURE ITS OWN MATTER STATES, which `p_at` already holds off the same
	// equation of state the derive uses. Its balance is the composition's to satisfy: the atmosphere is
	// laid along the barometric profile and the hydrosphere into its basins, so the pressures those
	// amounts state are the balanced ones and nothing here writes over them.
	// ROCK IS A COLUMN, and kernels3d/pressure.glsl owns it: the weight standing over the cell, ending at
	// the pressure of the first fluid above. Descending height, so a cell is reached after the one over it.
	for (int c : order) {
		if (!walkable || solid[c] == 0) {
			continue;
		}
		const int d = up_slot[c];
		const int u = d >= 0 ? nbr[c * 6 + d] : -1;
		double top = 0.0;
		if (u >= 0 && u < cc) {
			top = solid[u] != 0 ? p_at[u] + 0.5 * column_load(u) : p_at[u];
		}
		p_at[c] = top + 0.5 * column_load(c);
	}
	// WRITE IT BACK. AN OPEN CELL'S MATTER IS THE COMPOSITION'S, and state_derive.glsl states its pressure
	// from that matter; a seed that scaled amounts to hit a pressure would be inventing an atmosphere.
	// Rock FILLS its cell, so its lithic phases take the substance table's own compression at the column
	// pressure standing over them.
	for (size_t i = 0; i < nm; i++) {
		float *w = mats[i].arr.ptrw();
		bool touched = false;
		for (int c = 0; c < cc; c++) {
			double f = 1.0;
			if (solid[c] != 0 && is_lithic[i] && rho0[i] > 0.0 && p_at[c] > 0.0) {
				const double r = LASubstances::density(mats[i].substance, t_c, p_at[c]) / rho0[i];
				f = (std::isfinite(r) && r > 0.0) ? r : 1.0;
			}
			if (f == 1.0 || w[c] <= 0.0f) {
				continue;
			}
			w[c] = float(double(w[c]) * f);
			touched = true;
		}
		if (touched) {
			p_field->set("_" + mats[i].name, mats[i].arr);
		}
	}
	// The pressure the balance states, so the first state derive is taken at it rather than at zero.
	out.resize(cc);
	float *w = out.ptrw();
	for (int c = 0; c < cc; c++) {
		w[c] = float(p_at[c]);
	}
	return out;
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

void LAFieldLithostaticSeed::shape_atmosphere(Object *p_field, double p_temp_c, Object *p_measure,
		const PackedFloat32Array &p_gravity) {
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
	if (p_gravity.size() != cc * 3) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: the solved gravity is absent, "
				"so the atmosphere has no scale height and would fill the box to its top at one density.");
		return;
	}
	const double edge = double(grid->get("cell_size"));
	Object *terrain = Object::cast_to<Object>(p_field->get("_terrain"));
	const double datum = terrain ? double(terrain->call("sea_radius")) : 0.0;
	const PackedInt32Array nbr = grid->get("neighbours");
	const PackedFloat32Array h2o = p_field->get("_h2o");
	const PackedFloat32Array sil = p_field->get("_silicate");
	const double full_h2o = LASubstances::full_mol_m3("h2o");
	// Saturated vapour at the seed temperature, mol/m^3: h2o past this is a condensed phase, and a
	// condensed phase is what a column has a SURFACE at. A trace of vapour is not one.
	const double n_sat = LASubstances::saturation_p_at("h2o", p_temp_c)
			/ (la_physical("GAS_CONSTANT_J_MOL_K") * (p_temp_c + la_physical("KELVIN_OFFSET")));
	const double full_sil = LASubstances::full_mol_m3("silicate");
	// A ghost tail rides after the interior block, so the table is at least the interior's six slots.
	if (nbr.size() < cc * 6 || h2o.size() != cc || sil.size() != cc || !(datum > 0.0)
			|| !(full_h2o > 0.0) || !(full_sil > 0.0) || !(edge > 0.0)) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: no neighbour table or no "
				"condensed amounts, so no column knows where its own surface is.");
		return;
	}
	const Vector3 centre = field_centre(p_field);
	// Height along the LOCAL VERTICAL, the axis the column is stacked along, and the slot that steps
	// DOWN it. A rotating body's plumb line is not its radius.
	std::vector<double> h(cc, 0.0), scale(cc, 0.0);
	std::vector<double> cond(cc, 0.0);
	std::vector<int> below(cc, -1), above(cc, -1);
	for (int c = 0; c < cc; c++) {
		const Vector3 g(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		const double gm = double(g.length());
		if (!(gm > 0.0)) {
			continue;
		}
		const Vector3 up = -g / gm;
		h[c] = double((Vector3(grid->call("cell_world_pos", c)) - centre).dot(up));
		const int us = slot_toward(up);
		above[c] = nbr[c * 6 + us];
		below[c] = nbr[c * 6 + (us ^ 1)];
		scale[c] = m->scale_height_at(p_temp_c, gm);
		cond[c] = solid[c] != 0 ? 1.0
				: MIN(MAX(double(MAX(h2o[c], 0.0f)) - n_sat, 0.0) / full_h2o
						+ double(MAX(sil[c], 0.0f)) / full_sil, 1.0);
	}
	// THE LOCAL SURFACE, low to high so a cell reads the column under it: the top of the condensed matter
	// standing in this cell, or the surface the cell below it stands at. Over ocean that is the water the
	// hydrosphere seed laid, over land the rock, and it is the same interface stack.glsli reconstructs at.
	std::vector<int> up_order(cc);
	std::iota(up_order.begin(), up_order.end(), 0);
	std::sort(up_order.begin(), up_order.end(), [&h](int a2, int b2) { return h[a2] < h[b2]; });
	const double nowhere = -std::numeric_limits<double>::infinity();
	std::vector<double> surf(cc, nowhere);
	for (int c : up_order) {
		if (cond[c] > 0.0) {
			surf[c] = h[c] - 0.5 * edge + cond[c] * edge;
		} else if (below[c] >= 0 && below[c] < cc) {
			surf[c] = surf[below[c]];
		}
	}
	// AIR IS WHAT IS OPEN TO THE SKY. High to low, so a cell reads the one over it: an open cell under
	// open cells all the way out of the box holds atmosphere, and a void sealed under rock holds none --
	// it is a cavity, not a column, and the barometric law has nothing to say about it.
	std::vector<char> sky(cc, 0);
	for (size_t i = up_order.size(); i-- > 0;) {
		const int c = up_order[i];
		const int a = above[c];
		sky[c] = (solid[c] == 0 && (a < 0 || a >= cc || sky[a] != 0)) ? 1 : 0;
	}
	PackedFloat32Array f = unit_factor(cc);
	f.fill(-1.0f);
	for (int c = 0; c < cc; c++) {
		if (sky[c] == 0 || !std::isfinite(scale[c]) || scale[c] <= 0.0 || !std::isfinite(surf[c])) {
			continue;
		}
		// THE CELL'S OWN SHARE OF THE COLUMN OVER ITS OWN SURFACE, which is the MEAN of exp(-z/H) over
		// the height it spans, not the density at its centre. state_derive.glsl states a cell's pressure
		// off the amounts it holds and kernels3d/stack.glsli reads that pressure as the gas layer's own
		// mean, so the mean density is what makes the two agree, and measuring the height from the
		// column's own surface is what makes a vertical pair of them consistent. A cell under the water
		// or in the rock holds what the composition put there and the profile leaves it alone.
		// THE BAROMETRIC INTEGRAL OVER THE CELL'S OPEN HEIGHT, from ONE datum for the whole body: a
		// pressure surface is level, so a column over a mountain holds less air rather than holding
		// sea-level air higher up. The span starts at this column's own surface where that cuts the
		// cell, so a half-buried cell holds the air over its rock and not the rock's worth of it.
		const double z_bot = MAX(h[c] - 0.5 * edge, surf[c]);
		const double z_top = h[c] + 0.5 * edge;
		// THE ATMOSPHERE STANDS ON THE SEA SURFACE OR ON WHAT RISES OUT OF IT. A column whose own surface
		// is under the datum is a pocket the vertical walk stepped into, not a column of air: the walk
		// steps on the grid's axes and can pass the body's shell on a diagonal, and exp of how far under
		// the datum that puts it is what a cell was being seeded with.
		if (!(z_top > z_bot) || surf[c] < datum) {
			continue;
		}
		f[c] = float((scale[c] / edge) * (std::exp(-(z_bot - datum) / scale[c])
				- std::exp(-(z_top - datum) / scale[c])));
	}
	redistribute_gases(p_field, f);
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
	ClassDB::bind_static_method("LAFieldLithostaticSeed", D_METHOD("vertical", "field", "gravity"),
			&LAFieldLithostaticSeed::vertical);
	ClassDB::bind_static_method("LAFieldLithostaticSeed", D_METHOD("compress", "field", "gravity"),
			&LAFieldLithostaticSeed::compress);
	ClassDB::bind_static_method("LAFieldLithostaticSeed", D_METHOD("clear_gas_in_rock", "field"),
			&LAFieldLithostaticSeed::clear_gas_in_rock);
	ClassDB::bind_static_method("LAFieldLithostaticSeed",
			D_METHOD("shape_atmosphere", "field", "temp_c", "measure", "gravity"),
			&LAFieldLithostaticSeed::shape_atmosphere);
	ClassDB::bind_static_method("LAFieldLithostaticSeed", D_METHOD("displace_gas_from_water", "field"),
			&LAFieldLithostaticSeed::displace_gas_from_water);
}
