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

double eos_p(double vol, double a_gas_rt, double b_vol, double c_comp, double p_std) {
	if (vol <= 0.0) {
		return 0.0;
	}
	// Nothing compressible: the gas fills what the condensed phases leave.
	if (c_comp <= 0.0) {
		double room = vol - b_vol;
		return room > 0.0 ? a_gas_rt / room : 0.0;
	}
	// No gas at all: the condensed phases alone are squeezed into the cell.
	if (a_gas_rt <= 0.0) {
		return p_std + (b_vol - vol) / c_comp;
	}
	double k = vol - b_vol - c_comp * p_std;
	double disc = sqrt(k * k + 4.0 * c_comp * a_gas_rt);
	// Stable root of the same quadratic: for k > 0, (disc - k)/(2C) cancels catastrophically as C -> 0
	// and one ulp over 2C is an arbitrary pressure; 2A/(k + disc) is algebraically identical, sums
	// positives, and limits exactly to the ideal-gas A/k.
	double p = (k > 0.0) ? 2.0 * a_gas_rt / (k + disc) : (disc - k) / (2.0 * c_comp);
	return p;
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
				a_rt[c] += n * vol[c] * rt;
			} else {
				const double kg = n * vol[c] * mm[i];
				b_vol[c] += kg * v0[i];
				c_comp[c] += kg * v0k[i];
			}
		}
	}
	// A condensed phase raises its vapour over itself, at its saturation pressure over the room the
	// condensed matter leaves: the same fixed-volume split the derive makes.
	for (size_t i = 0; i < nm; i++) {
		if (is_gas[i] || !(psat[i] > 0.0)) {
			continue;
		}
		const float *r = mats[i].arr.ptr();
		for (int c = 0; c < cc; c++) {
			const double n = r[c] > 0.0f ? double(r[c]) : 0.0;
			const double room = vol[c] - b_vol[c];
			if (n <= 0.0 || !(room > 0.0)) {
				continue;
			}
			a_rt[c] += MIN(psat[i] * room / rt, n * vol[c]) * rt;
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
			p_at[c] = eos_p(vol[c], a_rt[c], b_vol[c], c_comp[c], p_std);
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

void LAFieldLithostaticSeed::shape_atmosphere(Object *p_field, double p_temp_c,
		const PackedFloat32Array &p_gravity, const PackedFloat64Array &p_phi) {
	if (!p_field) return;
	Object *grid = Object::cast_to<Object>(p_field->get("_grid"));
	const int cc = int(p_field->get("_cell_count"));
	const PackedByteArray solid = p_field->get("_solid");
	if (!grid || cc <= 0 || solid.size() != cc) return;
	if (p_gravity.size() != cc * 3) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: the solved gravity is absent, "
				"so the atmosphere has no scale height and would fill the box to its top at one density.");
		return;
	}
	const PackedInt32Array nbr = grid->get("neighbours");
	const PackedInt32Array slot_off = grid->get("slot_off");
	const PackedVector3Array centres = grid->get("centres");
	const PackedFloat32Array edges = grid->call("cell_edges");
	if (nbr.is_empty() || slot_off.size() < cc * 7 || p_phi.size() < cc || centres.size() < cc
			|| edges.size() < cc) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: no face list or no solved "
				"potential, so the atmosphere has nothing to stand its pressure on.");
		return;
	}
	bool pulled = false;
	for (int c = 0; c < cc && !pulled; c++) {
		const Vector3 g(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		pulled = g.length() > 0.0;
	}
	// A WORLD NOTHING PULLS ON HAS NO COLUMN TO STAND. Below the gravity rung the solve never ran, so
	// there is no vertical and no profile to lay.
	if (!pulled) return;
	// THE ATMOSPHERE IS THE BODY'S OWN, declared as a mass like its hydrosphere: the N2 inventory, and
	// every other gas in the prebiotic mole ratio to it. The box never decides how much air there is.
	const Dictionary body = LABodySeeds::of("planet");
	const double n2_kg = double(body.get("atmosphere_n2_kg", 0.0));
	const double body_kg = double(body.get("mass_kg", 0.0));
	const double r_sea = double(p_field->call("sea_radius"));
	if (!(n2_kg > 0.0) || !(body_kg > 0.0)) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: the body record declares no "
				"atmosphere_n2_kg or no mass_kg, so the planet would seed airless.");
		return;
	}
	if (!(r_sea > 0.0)) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: the terrain states no sea "
				"radius, so the barometric law has no datum.");
		return;
	}
	std::vector<Mirror> gases = channel_mirrors(p_field, "phase", "gas");
	const Dictionary table = LASubstances::table();
	const double x_n2 = la_physical("PREBIOTIC_MOLE_FRAC_N2");
	const double n2_mol = n2_kg / la_physical("MOLAR_MASS_N2_KG_MOL");
	std::vector<double> moles(gases.size(), 0.0);
	std::vector<double> molar(gases.size(), 0.0);
	double mol_sum = 0.0, kg_sum = 0.0;
	for (size_t i = 0; i < gases.size(); i++) {
		const Mirror &m = gases[i];
		molar[i] = double(Dictionary(table.get(m.substance, Dictionary())).get("molar_mass", 0.0));
		static const char *const PREBIOTIC[] = { "n2", "co2", "h2", "co", "so2", "h2s", "ch4", nullptr };
		for (int k = 0; PREBIOTIC[k]; k++) {
			if (m.name == PREBIOTIC[k]) {
				const CharString key = (String("PREBIOTIC_MOLE_FRAC_") + String(PREBIOTIC[k]).to_upper()).utf8();
				moles[i] = n2_mol * la_physical(key.get_data()) / x_n2;
			}
		}
		mol_sum += moles[i];
		kg_sum += moles[i] * molar[i];
	}
	if (!(mol_sum > 0.0) || !(kg_sum > 0.0)) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: no gas channel carries the "
				"declared inventory, so the air has no molar mass and no scale height.");
		return;
	}
	// R T / M of the air, m^2/s^2: the scale height times the gravity it was taken at, one number for the
	// whole body however g varies over it.
	const double rt_over_m = la_physical("GAS_CONSTANT_J_MOL_K") * (p_temp_c + la_physical("KELVIN_OFFSET"))
			/ (kg_sum / mol_sum);
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
	// profile is a function of the POTENTIAL and not of a height times a local scale height.
	// THE DATUM IS SEA LEVEL, in this field's own potential: every cell straddling the sea radius states
	// it there along its own g, so a slab and the planet anchor the same law at the same place.
	const Vector3 centre = field_centre(p_field);
	double phi_0 = 0.0;
	int at_sea = 0;
	for (int c = 0; c < cc; c++) {
		if (!std::isfinite(double(p_phi[c]))) {
			continue;
		}
		const double r_c = double((centres[c] - centre).length());
		const double e = double(edges[c]);
		if (std::abs(r_c - r_sea) > 0.5 * e) {
			continue;
		}
		const Vector3 g(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		phi_0 += double(p_phi[c]) + double(g.length()) * (r_sea - r_c);
		at_sea++;
	}
	if (at_sea == 0) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: no cell straddles the sea "
				"radius, so the barometric law has no datum in this box.");
		return;
	}
	phi_0 /= double(at_sea);
	// THE DENSITY AT THE DATUM IS THE INVENTORY OVER THE SHELL THE LAW FILLS: n0 = N / (4 pi r_sea^2 H),
	// H the radial integral of the profile in the body's own 1/r potential, taken until nothing is left.
	const double gm = la_physical("GRAVITATIONAL_CONSTANT") * body_kg;
	double shell = 0.0;
	{
		const double dr = 100.0;
		for (double r = r_sea + 0.5 * dr;; r += dr) {
			const double f = std::exp(-(gm / r_sea - gm / r) / rt_over_m) * (r / r_sea) * (r / r_sea);
			shell += f * dr;
			if (f < 1.0e-30 || r > r_sea + 1.0e7) {
				break;
			}
		}
	}
	const double area = 4.0 * 3.14159265358979 * r_sea * r_sea;
	// The air stands in the volume the cell's rock and sea leave, the same fractions the chords read.
	const PackedFloat32Array rock = p_field->get("_rock_fraction");
	const PackedFloat32Array water = p_field->get("_water_fraction");
	std::vector<double> shape(cc, 0.0);
	for (int c = 0; c < cc; c++) {
		if (sky[c] == 0 || !std::isfinite(double(p_phi[c]))) {
			continue;
		}
		const double e = double(edges[c]);
		const double gx[3] = { std::abs(double(p_gravity[c * 3])), std::abs(double(p_gravity[c * 3 + 1])),
			std::abs(double(p_gravity[c * 3 + 2])) };
		const double taken = (c < rock.size() ? std::max(double(rock[c]), 0.0) : 0.0)
				+ (c < water.size() ? std::max(double(water[c]), 0.0) : 0.0);
		const double room = std::max(1.0 - taken, 0.0);
		if (!(room > 0.0)) {
			continue;
		}
		// The gas stands on the cell's rock and sea: its layer is the room they leave, its centre that
		// much higher than the cell's. A CELL HOLDS WHAT ITS VOLUME HOLDS: over a layer whose potential
		// falls linearly along g, the mean of the exponential is its centre value times sinh(x)/x per
		// axis, x being half that axis's potential drop over R T / M.
		const double gmag = std::sqrt(gx[0] * gx[0] + gx[1] * gx[1] + gx[2] * gx[2]);
		const double phi_gas = double(p_phi[c]) + gmag * 0.5 * (1.0 - room) * e;
		double mean = 1.0;
		for (int a = 0; a < 3; a++) {
			const double x = gx[a] * e * room * 0.5 / rt_over_m;
			mean *= (x > 0.0) ? std::sinh(x) / x : 1.0;
		}
		shape[c] = std::exp(-(phi_gas - phi_0) / rt_over_m) * mean * room;
	}
	for (size_t i = 0; i < gases.size(); i++) {
		Mirror &m = gases[i];
		const double n0 = moles[i] / (area * shell);
		float *w = m.arr.ptrw();
		for (int c = 0; c < cc; c++) {
			w[c] = float(n0 * shape[c]);
		}
	}
	// ABOVE THE EXOBASE THERE IS NO FLUID. Where the barometric law leaves so little gas that a molecule
	// crosses the whole cell without a collision, the continuum equations say nothing about the cell,
	// and what stands there is the escape law's, not the grid's. The mean free path against the cell:
	// lambda = 1 / (sqrt(2) pi d^2 n).
	{
		const double d = la_physical("N2_KINETIC_DIAMETER_M");
		const double n_a = la_physical("AVOGADRO_PER_MOL");
		const double sigma = std::sqrt(2.0) * 3.14159265358979 * d * d;
		const double kn_limit = la_physical("KNUDSEN_CONTINUUM_LIMIT");
		std::vector<double> n_m3(cc, 0.0);
		for (const Mirror &m : gases) {
			for (int c = 0; c < cc; c++) {
				n_m3[c] += std::max(double(m.arr[c]), 0.0) * n_a;
			}
		}
		for (Mirror &m : gases) {
			float *w = m.arr.ptrw();
			for (int c = 0; c < cc; c++) {
				const double e = double(edges[c]);
				const bool collisionless = !(n_m3[c] > 0.0) || 1.0 / (sigma * n_m3[c]) > e * kn_limit;
				if (collisionless) {
					w[c] = 0.0f;
				}
			}
			p_field->set("_" + m.name, m.arr);
		}
	}
}

void LAFieldLithostaticSeed::_bind_methods() {
	ClassDB::bind_static_method("LAFieldLithostaticSeed", D_METHOD("vertical", "field", "gravity"),
			&LAFieldLithostaticSeed::vertical);
	ClassDB::bind_static_method("LAFieldLithostaticSeed", D_METHOD("compress", "field", "gravity"),
			&LAFieldLithostaticSeed::compress);
	ClassDB::bind_static_method("LAFieldLithostaticSeed",
			D_METHOD("shape_atmosphere", "field", "temp_c", "gravity", "phi"),
			&LAFieldLithostaticSeed::shape_atmosphere);
}
