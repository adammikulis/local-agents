#include "LAFieldHydrosphereSeed.hpp"

#include "LABodySystem.hpp"
#include "LAPhysicalRead.hpp"
#include "LAScriptCall.hpp"
#include "LASubstances.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
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
// LAVoxelGrid.slot_off: 7 entries per cell, the last ending its faces.
const int SLOT_STRIDE = 7;

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
	PackedFloat32Array h2o = p_field->get("_h2o");
	const PackedByteArray regolith = p_field->get("_regolith");
	const PackedFloat32Array porosity = p_field->get("_porosity");
	// The share of each cell below the sea shell and above its ground: the terrain's own ocean.
	const PackedFloat32Array water = p_field->get("_water_fraction");
	const PackedFloat32Array rock = p_field->get("_rock_fraction");
	if (!grid || cc <= 0 || h2o.size() != cc || regolith.size() != cc || porosity.size() != cc
			|| water.size() != cc || rock.size() != cc) {
		UtilityFunctions::push_error("LAFieldHydrosphereSeed: no water fraction, regolith or porosity per cell, "
				"so the hydrosphere has nowhere to stand.");
		return;
	}
	const PackedFloat32Array edges = grid->call("cell_edges");
	const Dictionary body = LABodySeeds::of("planet");
	const double water_kg = double(body.get("hydrosphere_kg", 0.0));
	const double ground_kg = double(body.get("groundwater_kg", 0.0));
	if (!(water_kg > 0.0) || ground_kg < 0.0 || ground_kg >= water_kg) {
		UtilityFunctions::push_error("LAFieldHydrosphereSeed: the body record declares no hydrosphere it "
				"could split between its surface and its pore space, so the planet would seed dry.");
		return;
	}
	// Porosity is a share of the ROCK's volume: the pore space of a cell is its rock's.
	double pore = 0.0;
	for (int c = 0; c < cc && c < edges.size(); c++) {
		if (regolith[c] != 0) {
			const double e = double(edges[c]);
			pore += double(porosity[c]) * double(MAX(rock[c], 0.0f)) * e * e * e;
		}
	}
	// NO PORE SPACE IS A BROKEN REGOLITH WALK: every box on this body has rock in it, and rock has
	// porosity, so a walk that finds none found nothing rather than a body without groundwater.
	if (!(pore > 0.0)) {
		UtilityFunctions::push_error("LAFieldHydrosphereSeed: the regolith walk found no pore space, so "
				"the body's groundwater has nowhere to stand.");
		return;
	}
	const double full_mol = LASubstances::full_mol_m3("h2o");
	const double kg_m3 = la_physical("MOLAR_MASS_WATER_KG_MOL") * full_mol;
	if (!(full_mol > 0.0) || !(kg_m3 > 0.0)) {
		return;
	}
	const double sat = MIN(ground_kg / (kg_m3 * pore), 1.0);
	PackedFloat32Array pore_w = p_field->get("_h2o_pore");
	pore_w.resize(cc);
	float *w = h2o.ptrw();
	float *pw = pore_w.ptrw();
	// THE SEA STANDS WHERE THE SHAPE PUTS IT, and the pore water wherever there is rock: two channels, the
	// sea in its own volume and the pore water in the rock's.
	for (int c = 0; c < cc; c++) {
		w[c] = float(MIN(double(MAX(water[c], 0.0f)), 1.0) * full_mol);
		pw[c] = regolith[c] != 0 ? float(sat * double(porosity[c]) * double(MAX(rock[c], 0.0f)) * full_mol) : 0.0f;
	}
	p_field->set("_h2o", h2o);
	p_field->set("_h2o_pore", pore_w);
}

void LAFieldHydrosphereSeed::_bind_methods() {
	ClassDB::bind_static_method("LAFieldHydrosphereSeed", D_METHOD("seed", "field"),
			&LAFieldHydrosphereSeed::seed);
}
