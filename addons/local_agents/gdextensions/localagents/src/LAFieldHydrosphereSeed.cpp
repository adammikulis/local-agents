#include "LASeedCancellation.hpp"
#include "LAFieldHydrosphereSeed.hpp"

#include "LAFieldMirrors.hpp"
#include "LAParallel.hpp"

#include "LABodySystem.hpp"
#include "LAGridGeometry.hpp"
#include "LAMixtureEnthalpy.hpp"
#include "LAPhaseEos.hpp"
#include "LAPhysicalRead.hpp"
#include "LAPlanetTables.hpp"
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
#include <atomic>
#include <cmath>
#include <limits>
#include <vector>

using namespace godot;

namespace {

const char *GEOMETRY_GD = "res://addons/local_agents/sim/material/FieldGeometry3D.gd";

Vector3 field_centre(Object *p_field) {
	Array args;
	args.append(p_field);
	return la_call_gd(GEOMETRY_GD, "centre", args);
}

// THE WATER TABLE'S RADIUS: the sea shell plus the height the body's groundwater stands at over its
// hypsometry. NAN where the body declares no hydrosphere to split.
double table_radius(Object *p_field) {
	const Dictionary body = LABodySeeds::of("planet");
	const double water_kg = double(body.get("hydrosphere_kg", 0.0));
	const double ground_kg = double(body.get("groundwater_kg", 0.0));
	const double kg_m3 = la_physical("MOLAR_MASS_WATER_KG_MOL") * LASubstances::full_mol_m3("h2o");
	const double body_r = LABodySeeds::seed_radius_m("planet");
	const double sea_r = double(p_field->call("sea_radius"));
	if (!(water_kg > 0.0) || ground_kg < 0.0 || ground_kg >= water_kg || !(kg_m3 > 0.0) || !(body_r > 0.0)
			|| !(sea_r > 0.0)) {
		return NAN;
	}
	// The frame at the surface: its grains at the surface's state, under the body's surface gravity.
	// LA_APPROX: seed_water_table_equipotential
	const double g = la_physical("GRAVITATIONAL_CONSTANT") * double(body.get("mass_kg", 0.0)) / (body_r * body_r);
	const double rho_grain = LAPlanetComposition::shell_density(LABodySeeds::surface_temp_c(),
			la_physical("STANDARD_PRESSURE_PA"));
	const double h_wt = LAPlanetComposition::water_table_m(body_r, ground_kg / kg_m3, sea_r - body_r,
			la_physical_array("HYPSOMETRY_AREA_BELOW"), la_physical_array("HYPSOMETRY_ELEVATION_M"), g, rho_grain,
			kg_m3);
	return std::isfinite(h_wt) ? sea_r + h_wt : NAN;
}

// Simpson's rule on [a, b] against its two halves, Richardson-corrected, halved where they disagree by more
// than `p_tol` -- which is not halved with them, so a jump in the integrand is walled in rather than chased.
// NAN where `p_depth` halvings leave a piece unresolved.
template <typename F>
double adaptive_simpson(const F &p_f, double p_a, double p_b, double p_fa, double p_fm, double p_fb, double p_whole,
		double p_tol, int p_depth) {
	const double m = 0.5 * (p_a + p_b);
	const double f_l = p_f(0.5 * (p_a + m)), f_r = p_f(0.5 * (m + p_b));
	const double left = (m - p_a) * (p_fa + 4.0 * f_l + p_fm) / 6.0;
	const double right = (p_b - m) * (p_fm + 4.0 * f_r + p_fb) / 6.0;
	const double delta = left + right - p_whole;
	if (std::abs(delta) <= 15.0 * p_tol) {
		return left + right + delta / 15.0;
	}
	if (p_depth <= 0 || !std::isfinite(delta)) {
		return NAN;
	}
	return adaptive_simpson(p_f, p_a, m, p_fa, f_l, p_fm, left, p_tol, p_depth - 1)
			+ adaptive_simpson(p_f, m, p_b, p_fm, f_r, p_fb, right, p_tol, p_depth - 1);
}

} // namespace

PackedFloat32Array LAFieldHydrosphereSeed::saturated_share(Object *p_field) {
	PackedFloat32Array out;
	Object *grid = p_field ? Object::cast_to<Object>(p_field->get("_grid")) : nullptr;
	const int cc = p_field ? int(p_field->get("_cell_count")) : 0;
	const PackedByteArray regolith = p_field ? PackedByteArray(p_field->get("_regolith")) : PackedByteArray();
	const PackedFloat32Array rock = p_field ? PackedFloat32Array(p_field->get("_rock_fraction")) : PackedFloat32Array();
	const PackedFloat32Array depth = p_field ? PackedFloat32Array(p_field->get("_surface_depth")) : PackedFloat32Array();
	const double r_table = p_field ? table_radius(p_field) : NAN;
	ERR_FAIL_COND_V_MSG(!grid || cc <= 0 || regolith.size() != cc || rock.size() != cc || depth.size() != cc
					|| !std::isfinite(r_table),
			out, "LAFieldHydrosphereSeed.saturated_share: no regolith, rock fraction, ground depth or water table "
			"per cell, so no pore is below the table or above it.");
	const PackedFloat32Array edges = grid->call("cell_edges");
	const PackedFloat64Array cw = LAGridGeometry::centres_f64(grid);
	const Vector3 centre = field_centre(p_field);
	out.resize(cc);
	float *w = out.ptrw();
	for (int c = 0; c < cc; c++) {
		LASeedCancellation::check();
		const double f = std::max(double(rock[c]), 0.0);
		w[c] = 0.0f;
		if (regolith[c] == 0 || !(f > 0.0)) {
			continue;
		}
		const double r = std::hypot(cw[c * 3] - double(centre.x), cw[c * 3 + 1] - double(centre.y),
				cw[c * 3 + 2] - double(centre.z));
		const double r_g = r + double(depth[c]);
		const double e = double(edges[c]);
		// The table is one equipotential CAPPED AT THE GROUND: under the sea the ground is the sea floor, so
		// every pore beneath it is full; on land, the rock below the table.
		const double r_wt = std::min(r_g, r_table);
		const double below = e > 0.0 ? std::clamp((r_wt - (r - 0.5 * e)) / e, 0.0, 1.0) : 0.0;
		w[c] = float(r_wt >= r_g ? f : std::min(below, f));
	}
	return out;
}

void LAFieldHydrosphereSeed::seed(Object *p_field, const Dictionary &p_air, const PackedFloat32Array &p_gravity) {
	if (!p_field) {
		return;
	}
	Object *grid = Object::cast_to<Object>(p_field->get("_grid"));
	Object *gravity = Object::cast_to<Object>(p_field->get("_gravity"));
	const int cc = int(p_field->get("_cell_count"));
	PackedFloat32Array h2o = LAFieldMirrors::of(p_field, "h2o");
	PackedFloat32Array pore_w = LAFieldMirrors::of(p_field, "h2o_pore");
	const PackedFloat32Array porosity = LAFieldMirrors::of(p_field, "porosity");
	// The share of each cell below the sea shell and above its ground: the terrain's own ocean.
	const PackedFloat32Array water = p_field->get("_water_fraction");
	const PackedFloat32Array depth = p_field->get("_surface_depth");
	const PackedFloat32Array t_rock = p_field->get("_t_rock");
	const PackedFloat32Array sat = saturated_share(p_field);
	const double sea_r = double(p_field->call("sea_radius"));
	const double r_table = table_radius(p_field);
	if (!grid || cc <= 0 || h2o.size() != cc || pore_w.size() != cc || porosity.size() != cc || water.size() != cc
			|| depth.size() != cc || t_rock.size() != cc || sat.size() != cc || !(sea_r > 0.0)
			|| !std::isfinite(r_table)) {
		UtilityFunctions::push_error("LAFieldHydrosphereSeed: no sea shell, water table, water fraction, "
				"porosity, ground depth or rock temperature per cell, so the hydrosphere has nowhere to stand.");
		return;
	}
	const double t_s = LABodySeeds::surface_temp_c();
	const double mm = la_physical("MOLAR_MASS_WATER_KG_MOL");
	const double eps = double(std::numeric_limits<float>::epsilon());
	const LACondensedEos &eos = LAPhaseEosFn::condensed("h2o");
	const LAFluidEos &fluid = LAPhaseEosFn::fluid("h2o");
	const double kelvin = la_physical("KELVIN_OFFSET");
	const double t_crit = la_physical("WATER_CRITICAL_T_C");
	// Water's vapour pressure at T; NAN past its critical point, where it has none.
	auto p_vapour = [&](double t_c) {
		return t_c < t_crit
				? LAMixtureEnthalpy::vapour_p_at("h2o", t_c, LASubstances::saturation_p_at("h2o", t_c)) : NAN;
	};
	// WATER'S SPECIFIC VOLUME AT (T, p), m^3/kg, condensed or a fluid: the one Peng-Robinson fluid under its
	// vapour pressure and past its critical point, the condensed phase over it.
	auto v_at = [&](double t_c, double p, bool condensed) {
		const double v = condensed ? LAPhaseEosFn::condensed_volume(eos, t_c, p)
								   : LAPhaseEosFn::pr_molar_volume(fluid, t_c + kelvin, p) / mm;
		return v > 0.0 ? v : NAN;
	};
	float *w = h2o.ptrw();
	float *pw = pore_w.ptrw();
	// ONLY THE HYDROSTATIC RUNG STANDS A COLUMN: below it the water has vacuum over it and stands at its own
	// vapour pressure, the condensed phase there; past the critical point the fluid at that curve's end.
	if (!LAProcessSet::has_record("pass", "PressurePass.gd", LAProcessSet::ANY)) {
		auto rho_saturated = [&](double t_c) {
			const double p_v = p_vapour(t_c);
			return std::isnan(p_v)
					? 1.0 / v_at(t_c, LASubstances::saturation_p_at("h2o", t_c), false) : 1.0 / v_at(t_c, p_v, true);
		};
		const double rho_sea = rho_saturated(t_s);
		for (int c = 0; c < cc; c++) {
			LASeedCancellation::check();
			const double f_sea = std::clamp(double(water[c]), 0.0, 1.0);
			const double v_pore = double(porosity[c]) * std::clamp(double(sat[c]), 0.0, 1.0);
			const double rho_pore = v_pore > 0.0 ? rho_saturated(double(t_rock[c])) : 0.0;
			ERR_FAIL_COND_MSG((f_sea > 0.0 && !(rho_sea > 0.0)) || (v_pore > 0.0 && !(rho_pore > 0.0)),
					"LAFieldHydrosphereSeed: cell " + String::num_int64(c) + "'s water has no volume at its own "
					"vapour pressure.");
			w[c] = float(f_sea * rho_sea / mm);
			pw[c] = float(v_pore * rho_pore / mm);
		}
		LAFieldMirrors::store(p_field, "h2o", h2o);
		LAFieldMirrors::store(p_field, "h2o_pore", pore_w);
		return;
	}
	// ON IT, UNDER THE WEIGHT OF THE WATER AND THE AIR ABOVE, down the one vertical relation
	// kernels3d/pressure.glsl walks the rock's column along, so the two columns are one discretisation.
	// LA_APPROX: seed_water_table_equipotential
	const double phi_0 = double(p_air.get("phi_0", NAN));
	const double p_0 = double(p_air.get("p_0", NAN));
	const double rt_over_m = double(p_air.get("rt_over_m", NAN));
	const PackedInt32Array up_of = gravity ? PackedInt32Array(gravity->call("up_table")) : PackedInt32Array();
	const PackedFloat64Array p_phi = gravity ? PackedFloat64Array(gravity->call("phi_abs")) : PackedFloat64Array();
	if (!std::isfinite(phi_0) || !(p_0 > 0.0) || !(rt_over_m > 0.0) || p_gravity.size() != cc * 3
			|| p_phi.size() < cc || up_of.size() != cc) {
		UtilityFunctions::push_error("LAFieldHydrosphereSeed: a column stands and the air over the water, the "
				"solved gravity, its potential or its vertical relation is absent, so the water has no weight to "
				"stand at.");
		return;
	}
	const PackedFloat32Array edges = grid->call("cell_edges");
	const PackedFloat64Array cw = LAGridGeometry::centres_f64(grid);
	const Vector3 centre = field_centre(p_field);
	const PackedFloat32Array rock = p_field->get("_rock_fraction");
	ERR_FAIL_COND_MSG(rock.size() != cc, "LAFieldHydrosphereSeed: no rock fraction per cell, so no sea is known "
			"to reach a cell's floor.");
	// A BAND OF WATER AT ONE TEMPERATURE STANDS ON ITS OWN WEIGHT: its specific volume integrated over the
	// pressure it spans is its height times g, which sets the pressure at its foot, and its mass per unit area
	// is the pressure it adds over g. The integral is adaptive Simpson's in ln p on each side of the vapour
	// pressure, to float precision; the foot is Newton's from the head, which a volume falling with pressure
	// never lets overshoot. NAN where no state holds.
	auto v_dp = [&](double t_c, double p_v, double a, double b) -> double {
		double total = 0.0;
		for (double lo = a; lo < b;) {
			const double hi = (lo < p_v && p_v < b) ? p_v : b;
			const bool condensed = !std::isnan(p_v) && !(lo < p_v);
			auto f = [&](double u) { return v_at(t_c, std::exp(u), condensed) * std::exp(u); };
			const double u0 = std::log(lo), u1 = std::log(hi);
			const double f0 = f(u0), fm = f(0.5 * (u0 + u1)), f1 = v_at(t_c, hi, condensed) * hi;
			const double whole = (u1 - u0) * (f0 + 4.0 * fm + f1) / 6.0;
			const double piece = adaptive_simpson(f, u0, u1, f0, fm, f1, whole, eps * std::abs(whole),
					std::numeric_limits<double>::digits);
			if (!std::isfinite(piece)) {
				return NAN;
			}
			total += piece;
			lo = hi;
		}
		return total;
	};
	auto band_foot = [&](double t_c, double p_head, double weight) -> double {
		const double p_v = p_vapour(t_c);
		double p = p_head, reached = 0.0;
		for (int it = 0; it < 64; it++) {
			if (!(weight - reached > eps * weight)) {
				return p;
			}
			const double v = v_at(t_c, p, !std::isnan(p_v) && !(p < p_v));
			const double next = p + (weight - reached) / v;
			const double gained = v_dp(t_c, p_v, p, next);
			if (!std::isfinite(next) || !std::isfinite(gained)) {
				return NAN;
			}
			reached += gained;
			p = next;
		}
		return NAN;
	};
	// Cells down each column a level at a time, so the water over a cell is laid before the cell is.
	std::vector<std::vector<int>> levels;
	{
		std::vector<int> up(cc, -1);
		for (int c = 0; c < cc; c++) {
			LASeedCancellation::check();
			up[c] = up_of[c];
		}
		ERR_FAIL_COND_MSG(!la_column_levels(up, std::vector<char>(cc, 1), levels), "LAFieldHydrosphereSeed: the "
				"vertical relation closes on itself, so no column has a top.");
	}
	// The water's pressure at a cell's lower face: the sea sits on the ground and the pores are full below
	// the table, so a cell's water, where it holds any, reaches its bottom.
	std::vector<double> p_bot(cc, NAN);
	// A cell whose water fails: 1 no gravity to weigh it, 2 no state its equation of state holds.
	std::atomic<int> bad_cell(-1), bad_kind(0);
	auto lay = [&](int c) {
		const double f_sea = std::clamp(double(water[c]), 0.0, 1.0);
		const double f_sat = std::clamp(double(sat[c]), 0.0, 1.0);
		const double v_pore = double(porosity[c]) * f_sat;
		w[c] = 0.0f;
		pw[c] = 0.0f;
		if (!(f_sea > 0.0) && !(v_pore > 0.0)) {
			return;
		}
		auto fail = [&](int p_kind) {
			int none = -1;
			if (bad_cell.compare_exchange_strong(none, c)) {
				bad_kind = p_kind;
			}
		};
		const Vector3 gv(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		const double gm = double(gv.length());
		if (!(gm > 0.0)) {
			fail(1);
			return;
		}
		const Vector3 up = -gv / float(gm);
		// kernels3d/pressure.glsl's la_load per kg/m^3: |g| over the step's projection on the local vertical.
		const double g_step = gm * double(edges[c]) * double(MAX(MAX(std::abs(up.x), std::abs(up.y)), std::abs(up.z)));
		// Water over this cell's own: the cell above's; where there is none, the air over this cell's water
		// surface, the sea's or the table's, by the barometric law the atmosphere was laid by.
		const int u = up_of[c];
		double p_top = u >= 0 ? p_bot[u] : NAN;
		if (!std::isfinite(p_top)) {
			const double r = std::hypot(cw[c * 3] - double(centre.x), cw[c * 3 + 1] - double(centre.y),
					cw[c * 3 + 2] - double(centre.z));
			const double r_surface = f_sea > 0.0 ? sea_r : std::min(r + double(depth[c]), r_table);
			const double phi = double(p_phi[c]) + gm * r * r * (1.0 / r - 1.0 / r_surface);
			p_top = p_0 * std::exp(-(phi - phi_0) / rt_over_m);
		}
		// THE SEA OVER THE PORES, each band on its own weight at its own temperature, the sea at the surface's
		// and the pore water at the rock's.
		double p_mid = p_top, rho_sea = 0.0, rho_pore = 0.0;
		if (f_sea > 0.0) {
			p_mid = band_foot(t_s, p_top, f_sea * g_step);
			rho_sea = (p_mid - p_top) / (f_sea * g_step);
		}
		double p_foot = p_mid;
		if (v_pore > 0.0) {
			p_foot = band_foot(double(t_rock[c]), p_mid, f_sat * g_step);
			rho_pore = (p_foot - p_mid) / (f_sat * g_step);
		}
		if ((f_sea > 0.0 && !(rho_sea > 0.0)) || (v_pore > 0.0 && !(rho_pore > 0.0))) {
			fail(2);
			return;
		}
		// The water reaches the cell's floor through its pores, or as a sea with no rock under it.
		p_bot[c] = (v_pore > 0.0 || !(double(rock[c]) > 0.0)) ? p_foot : NAN;
		w[c] = float(f_sea * rho_sea / mm);
		pw[c] = float(v_pore * rho_pore / mm);
	};
	for (const std::vector<int> &level : levels) {
		for (const int c : level) {
			LASeedCancellation::check();
			lay(c);
		}
		ERR_FAIL_COND_MSG(bad_cell >= 0, "LAFieldHydrosphereSeed: cell " + String::num_int64(bad_cell)
				+ (bad_kind == 1 ? " holds water and stands where the solved gravity vanishes, so the water has "
				"no weight." : "'s water stands on no weight its own equation of state holds to float precision."));
	}
	LAFieldMirrors::store(p_field, "h2o", h2o);
	LAFieldMirrors::store(p_field, "h2o_pore", pore_w);
}

Dictionary LAFieldHydrosphereSeed::wetness(Object *p_field) {
	Dictionary out;
	if (!p_field) {
		return out;
	}
	const PackedByteArray regolith = p_field->get("_regolith");
	const PackedFloat32Array pore = LAFieldMirrors::of(p_field, "h2o_pore");
	const int n = MIN(int(p_field->get("_cell_count")), MIN(int(regolith.size()), int(pore.size())));
	if (n <= 0) {
		return out;
	}
	int cells = 0, wet = 0;
	for (int c = 0; c < n; c++) {
		LASeedCancellation::check();
		if (regolith[c] == 0) {
			continue;
		}
		cells++;
		wet += pore[c] > 0.0f ? 1 : 0;
	}
	out["regolith_cells"] = cells;
	out["regolith_wet_cells"] = wet;
	// Rock whose pores stand over the table and hold no gas: a vacuum where the soil air belongs.
	const PackedFloat32Array porosity = LAFieldMirrors::of(p_field, "porosity");
	const PackedFloat32Array rock = p_field->get("_rock_fraction");
	const PackedFloat32Array sat = saturated_share(p_field);
	if (porosity.size() < n || rock.size() < n || sat.size() < n) {
		return out;
	}
	std::vector<PackedFloat32Array> gases;
	const Dictionary rows = la_call_gd("res://addons/local_agents/sim/material/Channels.gd", "rows", Array());
	const Array names = rows.keys();
	for (int i = 0; i < names.size(); i++) {
		const Dictionary row = rows[names[i]];
		const PackedFloat32Array arr = LAFieldMirrors::of(p_field, String(names[i]));
		if (String(row.get("phase", "")) == "gas" && String(row.get("unit", "")) == "mol_m3" && arr.size() >= n) {
			gases.push_back(arr);
		}
	}
	int vacuum = 0;
	for (int c = 0; c < n; c++) {
		LASeedCancellation::check();
		if (regolith[c] == 0 || !(double(porosity[c]) * (double(rock[c]) - double(sat[c])) > 0.0)) {
			continue;
		}
		double mol = 0.0;
		for (const PackedFloat32Array &g : gases) {
			mol += std::max(double(g[c]), 0.0);
		}
		vacuum += mol > 0.0 ? 0 : 1;
	}
	out["regolith_dry_pore_vacuum_cells"] = vacuum;
	return out;
}

void LAFieldHydrosphereSeed::_bind_methods() {
	ClassDB::bind_static_method("LAFieldHydrosphereSeed", D_METHOD("seed", "field", "air", "g_rest"),
			&LAFieldHydrosphereSeed::seed);
	ClassDB::bind_static_method("LAFieldHydrosphereSeed", D_METHOD("saturated_share", "field"),
			&LAFieldHydrosphereSeed::saturated_share);
	ClassDB::bind_static_method("LAFieldHydrosphereSeed", D_METHOD("wetness", "field"),
			&LAFieldHydrosphereSeed::wetness);
}
