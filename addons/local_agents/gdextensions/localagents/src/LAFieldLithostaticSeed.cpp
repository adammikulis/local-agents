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
// MOLES, not fill fractions: a channel value is a fill fraction of the cell holding it, so on a graded
// grid a bare sum over cells is not proportional to matter and the profile would move mass across a seam.
void redistribute_gases(Object *p_field, const PackedFloat32Array &p_shape,
		const std::vector<double> &p_vol) {
	std::vector<Mirror> gases = channel_mirrors(p_field, "phase", "gas");
	const int cc = MIN(p_shape.size(), int(p_vol.size()));
	for (Mirror &m : gases) {
		float *w = m.arr.ptrw();
		double had = 0.0;
		double laid = 0.0;
		for (int c = 0; c < cc; c++) {
			if (p_shape[c] < 0.0f) {
				continue;
			}
			had += double(w[c]) * p_vol[c];
			laid += double(w[c]) * double(p_shape[c]) * p_vol[c];
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
	// RESOLUTION FOLLOWS POSITION: a cell's edge and volume are its own.
	const PackedFloat32Array edges = grid->call("cell_edges");
	std::vector<double> dr(cc, 0.0), vol(cc, 0.0);
	for (int c = 0; c < cc && c < edges.size(); c++) {
		dr[c] = double(edges[c]);
		vol[c] = dr[c] * dr[c] * dr[c];
	}
	// A face list the march cannot walk costs it its COLUMN, not the pressure each cell states.
	const PackedInt32Array nbr = grid->get("neighbours");
	const PackedInt32Array slot_off = grid->get("slot_off");
	const bool walkable = !nbr.is_empty() && slot_off.size() >= cc * 7 && edges.size() >= cc;
	const Dictionary table = LASubstances::table();
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const double t_c = double(la_gd_const(FIELD_GD, "INITIAL_TEMP"));
	const double p_std = la_physical("STANDARD_PRESSURE_PA");
	const double rt = la_physical("GAS_CONSTANT_J_MOL_K") * (t_c + la_physical("KELVIN_OFFSET"));

	// Every matter channel, with what the substance table says about the substance it carries.
	std::vector<Mirror> mats = channel_mirrors(p_field, "unit", "mol_m3");
	const size_t nm = mats.size();
	std::vector<double> mm(nm, 0.0), v0(nm, 0.0), v0k(nm, 0.0), rho0(nm, 0.0), psat(nm, 0.0);
	std::vector<bool> is_gas(nm, false);
	for (size_t i = 0; i < nm; i++) {
		const Dictionary row = rows.get(mats[i].name, Dictionary());
		const Dictionary sub = table.get(mats[i].substance, Dictionary());
		mm[i] = double(sub.get("molar_mass", 0.0));
		is_gas[i] = String(row.get("phase", "")) == "gas";
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
				a_rt[c] += n * vol[c] * rt;
			} else {
				const double kg = n * vol[c] * mm[i];
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
		return rho[c] * gm * dr[c] * m;
	};

	// A cell stands at the pressure its own amounts state, off the same equation of state the derive uses.
	std::vector<double> p_at(cc, 0.0);
	for (int c = 0; c < cc; c++) {
		if (rho[c] > 0.0) {
			p_at[c] = eos_p(vol[c], a_rt[c], b_vol[c], c_comp[c], p_std, p_sat[c]);
		}
	}

	// Height along the local vertical and the slot pointing up it: rock's column marches these.
	const PackedVector3Array la_cw = grid->get("centres");
	std::vector<double> h(cc, 0.0);
	std::vector<int> up_slot(cc, -1);
	for (int c = 0; c < cc; c++) {
		const Vector3 g(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		const double gm = double(g.length());
		if (!(gm > 0.0)) {
			continue;
		}
		const Vector3 up = -g / gm;
		h[c] = double((la_cw[c] - centre).dot(up));
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
		// The cell ABOVE: where the slot meets four finer cells, the one the plumb line runs into.
		// Any other of the four stands over different ground.
		const int d = up_slot[c];
		int u = -1;
		double off = 0.0;
		if (d >= 0) {
			const Vector3 g(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
			const double gm = double(g.length());
			const Vector3 up = gm > 0.0 ? Vector3(-g / gm) : Vector3(0, 1, 0);
			const Vector3 here = la_cw[c];
			for (int f2 = slot_off[c * 7 + d]; f2 < slot_off[c * 7 + d + 1]; f2++) {
				const int n = nbr[f2];
				if (n < 0 || n >= cc) {
					continue;
				}
				const Vector3 r = la_cw[n] - here;
				const double lat = double((r - up * float(r.dot(up))).length());
				if (u < 0 || lat < off) {
					u = n;
					off = lat;
				}
			}
		}
		double top = 0.0;
		if (u >= 0 && u < cc) {
			top = solid[u] != 0 ? p_at[u] + 0.5 * column_load(u) : p_at[u];
		}
		p_at[c] = top + 0.5 * column_load(c);
	}
	// THE MATTER IS THE COMPOSITION'S: the radial profile it was laid down from is the hydrostatic
	// solution of the same EOS, so the march states the pressure and moves no mass.
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
		const PackedFloat32Array &p_gravity, const PackedFloat32Array &p_phi) {
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
	const PackedInt32Array nbr = grid->get("neighbours");
	const PackedInt32Array slot_off = grid->get("slot_off");
	// A ghost tail rides after the interior block, so the tables are at least the interior's.
	if (nbr.is_empty() || slot_off.size() < cc * 7 || p_phi.size() < cc) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: no face list or no solved "
				"potential, so the atmosphere has nothing to stand its pressure on.");
		return;
	}
	// R T / M of the air, m^2/s^2: the scale height times the gravity it was taken at, which is one
	// number for the whole body however g varies over it.
	double rt_over_m = 0.0;
	bool pulled = false;
	for (int c = 0; c < cc && !(rt_over_m > 0.0); c++) {
		const Vector3 g(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		const double gm = double(g.length());
		if (!(gm > 0.0)) {
			continue;
		}
		pulled = true;
		const double sh = m->scale_height_at(p_temp_c, gm);
		if (std::isfinite(sh) && sh > 0.0) {
			rt_over_m = gm * sh;
		}
	}
	// A WORLD NOTHING PULLS ON HAS NO COLUMN TO STAND. Below the gravity rung the solve never ran, so
	// there is no vertical and no profile to lay; the composition's own amounts stand as they are.
	if (!pulled) {
		return;
	}
	if (!(rt_over_m > 0.0)) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: gravity pulls on this "
				"world and the air still states no scale height, so its column has no law.");
		return;
	}
	// AIR IS WHAT THE OUTSIDE REACHES, which is CONNECTIVITY and not a direction: flooded through open
	// faces from every open cell the box edge touches. A void the flood never reaches is sealed under
	// rock -- a cavity, not a column, and the barometric law has nothing to say about it.
	std::vector<char> sky(cc, 0);
	std::vector<int> front;
	for (int c = 0; c < cc; c++) {
		if (solid[c] != 0) {
			continue;
		}
		for (int f2 = slot_off[c * 7]; f2 < slot_off[c * 7 + 6]; f2++) {
			if (nbr[f2] < 0) {
				sky[c] = 1;
				front.push_back(c);
				break;
			}
		}
	}
	while (!front.empty()) {
		const int c = front.back();
		front.pop_back();
		for (int f2 = slot_off[c * 7]; f2 < slot_off[c * 7 + 6]; f2++) {
			const int n = nbr[f2];
			if (n < 0 || n >= cc || solid[n] != 0 || sky[n] != 0) {
				continue;
			}
			sky[n] = 1;
			front.push_back(n);
		}
	}
	// THE EXACT ISOTHERMAL HYDROSTATIC SOLUTION, IN THE POTENTIAL THE SOLVE PRODUCED. dp/dz = -rho g
	// with p = rho R T / M integrates to p = p0 exp(-M (phi - phi0) / (R T)) in ANY field, so the
	// profile is a function of the POTENTIAL and not of a height times a local scale height. A scale
	// height is only 1/g's own linearization, and g falls by tens of percent over this box: taking each
	// cell's own H makes every cell a different atmosphere, and two neighbours then disagree about
	// which of them holds the denser air. The same lambda = M depth / (R T) the escape law reads.
	// The deepest air the flood reached, as the exponent's ZERO. Any constant anchor cancels in the
	// renormalisation below; this one keeps every exponent negative, so nothing overflows.
	double phi_ref = 0.0;
	bool have_ref = false;
	for (int c = 0; c < cc; c++) {
		if (solid[c] != 0 || sky[c] == 0 || !std::isfinite(double(p_phi[c]))) {
			continue;
		}
		if (!have_ref || double(p_phi[c]) < phi_ref) {
			phi_ref = double(p_phi[c]);
			have_ref = true;
		}
	}
	PackedFloat32Array f = unit_factor(cc);
	f.fill(-1.0f);
	if (!have_ref) {
		return;
	}
	const PackedFloat32Array edges = grid->call("cell_edges");
	// A CELL HOLDS WHAT ITS VOLUME HOLDS, not what its centre stands at. Over a cube whose potential
	// falls linearly along g, the mean of the exponential is its centre value times sinh(x)/x per axis,
	// x being half that axis's potential drop over R T / M. It is the same law, integrated.
	for (int c = 0; c < cc; c++) {
		if (sky[c] == 0 || !std::isfinite(double(p_phi[c]))) {
			continue;
		}
		const double e = c < edges.size() ? double(edges[c]) : 0.0;
		const double gx[3] = { std::abs(double(p_gravity[c * 3])), std::abs(double(p_gravity[c * 3 + 1])),
			std::abs(double(p_gravity[c * 3 + 2])) };
		double mean = 1.0;
		for (int a = 0; a < 3; a++) {
			const double x = gx[a] * e * 0.5 / rt_over_m;
			mean *= (x > 0.0) ? std::sinh(x) / x : 1.0;
		}
		// phi rises outward, so this is 1 at that anchor and falls from there.
		f[c] = float(std::exp(-(double(p_phi[c]) - phi_ref) / rt_over_m) * mean);
	}
	std::vector<double> vol(cc, 0.0);
	for (int c = 0; c < cc && c < edges.size(); c++) {
		const double e = double(edges[c]);
		vol[c] = e * e * e;
	}
	redistribute_gases(p_field, f, vol);
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
			D_METHOD("shape_atmosphere", "field", "temp_c", "measure", "gravity", "phi"),
			&LAFieldLithostaticSeed::shape_atmosphere);
	ClassDB::bind_static_method("LAFieldLithostaticSeed", D_METHOD("displace_gas_from_water", "field"),
			&LAFieldLithostaticSeed::displace_gas_from_water);
}
