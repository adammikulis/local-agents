#include "LAFieldHydrosphereSeed.hpp"

#include "LAFieldMirrors.hpp"

#include "LABodySystem.hpp"
#include "LAGridGeometry.hpp"
#include "LAPhysicalRead.hpp"
#include "LAPlanetTables.hpp"
#include "LAScriptCall.hpp"
#include "LASubstances.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
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

} // namespace

void LAFieldHydrosphereSeed::seed(Object *p_field) {
	if (!p_field) {
		return;
	}
	Object *grid = Object::cast_to<Object>(p_field->get("_grid"));
	const int cc = int(p_field->get("_cell_count"));
	PackedFloat32Array h2o = LAFieldMirrors::of(p_field, "h2o");
	const PackedByteArray regolith = p_field->get("_regolith");
	const PackedFloat32Array porosity = LAFieldMirrors::of(p_field, "porosity");
	// The share of each cell under the free water surface the fill left and above its ground.
	const PackedFloat32Array water = p_field->get("_water_fraction");
	const PackedFloat32Array rock = p_field->get("_rock_fraction");
	if (!grid || cc <= 0 || h2o.size() != cc || regolith.size() != cc || porosity.size() != cc
			|| water.size() != cc || rock.size() != cc) {
		UtilityFunctions::push_error("LAFieldHydrosphereSeed: no water fraction, regolith or porosity per cell, "
				"so the hydrosphere has nowhere to stand.");
		return;
	}
	const PackedFloat32Array edges = grid->call("cell_edges");
	const PackedFloat32Array depth = p_field->get("_surface_depth");
	const PackedFloat64Array cw = LAGridGeometry::centres_f64(grid);
	const Dictionary body = LABodySeeds::of("planet");
	const double water_kg = double(body.get("hydrosphere_kg", 0.0));
	const double ground_kg = double(body.get("groundwater_kg", 0.0));
	if (!(water_kg > 0.0) || ground_kg < 0.0 || ground_kg >= water_kg) {
		UtilityFunctions::push_error("LAFieldHydrosphereSeed: the body record declares no hydrosphere it "
				"could split between its surface and its pore space, so the planet would seed dry.");
		return;
	}
	const double full_mol = LASubstances::full_mol_m3("h2o");
	const double kg_m3 = la_physical("MOLAR_MASS_WATER_KG_MOL") * full_mol;
	if (!(full_mol > 0.0) || !(kg_m3 > 0.0)) {
		return;
	}
	const double body_r = LABodySeeds::seed_radius_m("planet");
	if (!(body_r > 0.0) || depth.size() != cc || cw.size() < cc * 3 || edges.size() < cc) {
		UtilityFunctions::push_error("LAFieldHydrosphereSeed: no ground depth or cell centres, so there "
				"is no surface for the water table to be measured from.");
		return;
	}
	// WHAT THE PORE WATER STANDS OVER: the free surface the fill left over this box, measured, never a
	// declared shell. A box whose columns are all dry has none, and its pore water stands at the ground.
	Object *terrain = Object::cast_to<Object>(p_field->get("_terrain"));
	const Vector3 centre = field_centre(p_field);
	double w_sum = 0.0;
	int w_n = 0;
	for (int c = 0; c < cc; c++) {
		if (!(water[c] > 0.0f) || !terrain || !terrain->has_method("water_radius")) {
			continue;
		}
		const Vector3 rel = Vector3(float(cw[c * 3] - double(centre.x)), float(cw[c * 3 + 1] - double(centre.y)),
				float(cw[c * 3 + 2] - double(centre.z)));
		const double w = double(terrain->call("water_radius", rel.normalized()));
		if (std::isfinite(w)) {
			w_sum += w;
			w_n++;
		}
	}
	const double sea_r = w_n > 0 ? w_sum / double(w_n) : body_r;
	// LA_APPROX: seed_water_table_equipotential
	const double h_wt = LAPlanetComposition::water_table_m(body_r, ground_kg / kg_m3, sea_r - body_r,
			la_physical_array("HYPSOMETRY_AREA_BELOW"), la_physical_array("HYPSOMETRY_ELEVATION_M"));
	if (!std::isfinite(h_wt)) {
		return;
	}
	PackedFloat32Array pore_w = LAFieldMirrors::of(p_field, "h2o_pore");
	pore_w.resize(cc);
	float *w = h2o.ptrw();
	float *pw = pore_w.ptrw();
	// THE WATER STANDS WHERE THE FILL PUT IT, and the pore water under the water table: two channels, the
	// free water in its own volume and the pore water in the rock's, wherever the rock is below the table.
	for (int c = 0; c < cc; c++) {
		w[c] = float(MIN(double(MAX(water[c], 0.0f)), 1.0) * full_mol);
		pw[c] = 0.0f;
		if (regolith[c] == 0) {
			continue;
		}
		const double r = std::hypot(cw[c * 3] - double(centre.x), cw[c * 3 + 1] - double(centre.y),
				cw[c * 3 + 2] - double(centre.z));
		// The table is one equipotential CAPPED AT THE GROUND: under the sea the ground is the sea floor,
		// so the pore beneath it stands at the sea's own head; on land the cap is a spring.
		const double r_wt = MIN(r + double(depth[c]), sea_r + h_wt);
		const double e = double(edges[c]);
		const double below = e > 0.0 ? (r_wt - (r - 0.5 * e)) / e : 0.0;
		const double fill = MIN(MAX(below, 0.0), 1.0);
		pw[c] = float(fill * double(porosity[c]) * double(MAX(rock[c], 0.0f)) * full_mol);
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
		if (regolith[c] == 0) {
			continue;
		}
		cells++;
		wet += pore[c] > 0.0f ? 1 : 0;
	}
	out["regolith_cells"] = cells;
	out["regolith_wet_cells"] = wet;
	return out;
}

void LAFieldHydrosphereSeed::_bind_methods() {
	ClassDB::bind_static_method("LAFieldHydrosphereSeed", D_METHOD("seed", "field"),
			&LAFieldHydrosphereSeed::seed);
	ClassDB::bind_static_method("LAFieldHydrosphereSeed", D_METHOD("wetness", "field"),
			&LAFieldHydrosphereSeed::wetness);
}
