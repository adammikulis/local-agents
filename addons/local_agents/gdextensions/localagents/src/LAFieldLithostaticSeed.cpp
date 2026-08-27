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

// kernels3d/eos.glsli INVERTED: the factor every amount in a cell is multiplied by so that cell's own
// equation of state returns `p_pa`. Exact for all three of la_eos_p's branches, since scaling A, B and C
// together scales the quadratic's own coefficients. Infinite where no finite amount reaches that pressure.
double eos_scale(double p_pa, double p_vol, double p_a_rt, double p_b_vol, double p_c_comp, double p_std) {
	if (!(p_pa > 0.0)) {
		return 0.0;
	}
	const double den = p_a_rt + p_pa * (p_b_vol + p_c_comp * p_std - p_c_comp * p_pa);
	return den > 0.0 ? p_vol * p_pa / den : std::numeric_limits<double>::infinity();
}

// The pressure a cell's own amounts already state: eos_scale's root at s = 1, bisected. The scale rises
// with pressure on every branch, and finding the forward value this way keeps eos.glsli the ONE statement
// of the equation of state.
double eos_rest_p(double p_vol, double p_a_rt, double p_b_vol, double p_c_comp, double p_std) {
	double hi = p_std;
	for (int i = 0; i < 200 && eos_scale(hi, p_vol, p_a_rt, p_b_vol, p_c_comp, p_std) < 1.0; i++) {
		hi *= 2.0;
	}
	double lo = 0.0;
	for (int i = 0; i < 100; i++) {
		const double mid = 0.5 * (lo + hi);
		if (eos_scale(mid, p_vol, p_a_rt, p_b_vol, p_c_comp, p_std) < 1.0) {
			lo = mid;
		} else {
			hi = mid;
		}
	}
	return 0.5 * (lo + hi);
}

PackedFloat32Array unit_factor(int p_cc) {
	PackedFloat32Array f;
	f.resize(p_cc);
	f.fill(1.0f);
	return f;
}

} // namespace

double LAFieldLithostaticSeed::compress(Object *p_field, const PackedFloat32Array &p_gravity) {
	if (!p_field) {
		return 0.0;
	}
	Object *grid = Object::cast_to<Object>(p_field->get("_grid"));
	const int cc = int(p_field->get("_cell_count"));
	const PackedByteArray solid = p_field->get("_solid");
	if (!grid || cc <= 0 || solid.size() != cc) {
		return 0.0;
	}
	if (p_gravity.size() != cc * 3) {
		UtilityFunctions::push_error(String("LAFieldLithostaticSeed.compress: the solved gravity is ")
				+ String::num_int64(p_gravity.size()) + " long against " + String::num_int64(cc)
				+ " cells, so the balance has no direction to march along.");
		return 0.0;
	}
	const Vector3 centre = field_centre(p_field);
	const double dr = double(grid->get("cell_size"));
	const double vol = dr * dr * dr;
	const PackedInt32Array nbr = grid->get("neighbours");
	if (nbr.size() != cc * 6) {
		return 0.0;
	}
	const Dictionary table = LASubstances::table();
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const double t_c = double(la_gd_const(FIELD_GD, "INITIAL_TEMP"));
	const double p_std = la_physical("STANDARD_PRESSURE_PA");
	const double rt = la_physical("GAS_CONSTANT_J_MOL_K") * (t_c + la_physical("KELVIN_OFFSET"));

	// Every matter channel, with what the substance table says about the substance it carries.
	std::vector<Mirror> mats = channel_mirrors(p_field, "unit", "mol_m3");
	const size_t nm = mats.size();
	std::vector<double> mm(nm, 0.0), v0(nm, 0.0), v0k(nm, 0.0), rho0(nm, 0.0);
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
		rho0[i] = LASubstances::density(mats[i].substance, t_c, p_std);
		v0[i] = rho0[i] > 0.0 ? 1.0 / rho0[i] : 0.0;
		const double k = double(sub.get("bulk_modulus_pa", 0.0));
		v0k[i] = k > 0.0 ? v0[i] / k : 0.0;
	}

	// la_eos_p's own coefficients per cell at the amounts the composition laid down, and the mass those
	// amounts weigh. A gas is the A term; a condensed phase is B, and C where it declares a bulk modulus.
	std::vector<double> a_rt(cc, 0.0), b_vol(cc, 0.0), c_comp(cc, 0.0), rho(cc, 0.0);
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
			}
		}
	}

	// THE MARCH IS ALONG THE SOLVED GRAVITY, cell by cell on the Cartesian grid. Height is the outward
	// distance along the local vertical, so walking it from the top visits a cell after the cell above it.
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

	// THE BALANCE THE STEPPER HOLDS. transport.glsl's face_p() presents one pressure to a shared face when
	// p_below - p_above = 0.5 * dx * (rho_above * g_above.n + rho_below * g_below.n), and there its
	// reconstruction cancels the bodyf_* impulse exactly. scripts/check_atmosphere_at_rest.sh is what
	// holds this expression to the kernel's.
	std::vector<double> p_at(cc, 0.0);
	std::vector<char> done(cc, 0);
	std::vector<double> scale(cc, 1.0);
	int unresolved = 0;
	double worst_span = 0.0;
	for (int c : order) {
		done[c] = 1;
		if (up_slot[c] < 0) {
			continue;
		}
		const int d = up_slot[c];
		const Vector3 g_c(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		const Vector3 down = -slot_normal(d);
		const double a_c = double(g_c.dot(down));
		const int u = nbr[c * 6 + d];
		const bool from_above = u >= 0 && u < cc && done[u] != 0 && rho[u] > 0.0 && p_at[u] > 0.0;
		if (rho[c] <= 0.0) {
			continue;      // vacuum: no matter to carry a pressure, and state_derive reads it as none
		}
		if (!from_above) {
			// The top of a column stands under nothing, so its own matter states its pressure.
			p_at[c] = eos_rest_p(vol, a_rt[c], b_vol[c], c_comp[c], p_std);
			continue;
		}
		const Vector3 g_u(p_gravity[u * 3], p_gravity[u * 3 + 1], p_gravity[u * 3 + 2]);
		const double load_u = rho[u] * double(g_u.dot(down));
		if (solid[c] != 0) {
			// Rock is quasi-static and kernels3d/pressure.glsl owns its pressure; what the seed owes it is
			// the DENSITY that pressure implies, through the substance table's own equation of state.
			p_at[c] = p_at[u] + 0.5 * dr * (load_u + rho[c] * a_c);
			continue;
		}
		// An open cell's pressure IS its matter, so the balance is solved for the amount that states it.
		// The iteration contracts by 0.5 * dx / H; a cell it cannot reach is one the grid cannot resolve.
		double p = p_at[u] + dr * rho[c] * a_c;
		bool settled = false;
		for (int it = 0; it < 200; it++) {
			const double s = eos_scale(p, vol, a_rt[c], b_vol[c], c_comp[c], p_std);
			const double next = p_at[u] + 0.5 * dr * (load_u + s * rho[c] * a_c);
			if (!(next > 0.0) || !std::isfinite(next)) {
				break;
			}
			const double rel = std::abs(next - p) / next;
			p = next;
			if (rel <= 1.0e-13) {
				settled = true;
				break;
			}
		}
		if (!settled) {
			unresolved++;
			const double span = p_at[u] > 0.0 ? dr * rho[c] * a_c / p_at[u] : 0.0;
			worst_span = MAX(worst_span, span);
			continue;
		}
		p_at[c] = p;
		scale[c] = eos_scale(p, vol, a_rt[c], b_vol[c], c_comp[c], p_std);
		rho[c] *= scale[c];
	}
	if (unresolved > 0) {
		UtilityFunctions::push_error(String("LAFieldLithostaticSeed.compress: ")
				+ String::num_int64(unresolved) + " open cell(s) hold no balanced state at this cell edge: "
				+ "a cell taller than twice the local scale height has none. Worst cell edge over scale "
				+ "height: " + String::num(worst_span, 3) + ".");
	}

	// WRITE IT BACK. An open cell takes the scale its pressure implies, on every amount it holds; a solid
	// cell takes the substance table's compression ratio at its marched pressure, on its lithic phases.
	double added = 0.0;
	for (size_t i = 0; i < nm; i++) {
		float *w = mats[i].arr.ptrw();
		bool touched = false;
		for (int c = 0; c < cc; c++) {
			double f = 1.0;
			if (solid[c] == 0) {
				f = scale[c];
			} else if (is_lithic[i] && rho0[i] > 0.0 && p_at[c] > 0.0) {
				const double r = LASubstances::density(mats[i].substance, t_c, p_at[c]) / rho0[i];
				f = (std::isfinite(r) && r > 0.0) ? r : 1.0;
			}
			if (f == 1.0 || w[c] <= 0.0f) {
				continue;
			}
			const double amt = double(w[c]) * f;
			added += amt - double(w[c]);
			w[c] = float(amt);
			touched = true;
		}
		if (touched) {
			p_field->set("_" + mats[i].name, mats[i].arr);
		}
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
	const Vector3 centre = field_centre(p_field);
	PackedFloat32Array f = unit_factor(cc);
	for (int c = 0; c < cc; c++) {
		if (solid[c] != 0) {
			continue;
		}
		const Vector3 g(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		const double scale_h = m->scale_height_at(p_temp_c, double(g.length()));
		if (!std::isfinite(scale_h) || scale_h <= 0.0) {
			continue;
		}
		const Vector3 pos = grid->call("cell_world_pos", c);
		const double above = MAX(double((pos - centre).length()) - m->get_surface_r_m(), 0.0);
		f[c] = float(std::exp(-above / scale_h));
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
