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
const int SLOTS = 6;
// Bisection steps on the one scale that spends the water budget. Monotone, so this is convergence.
const int FILL_STEPS = 80;

Vector3 field_centre(Object *p_field) {
	Array args;
	args.append(p_field);
	return la_call_gd(GEOMETRY_GD, "centre", args);
}

// Cells' worth of water the scale lays down: a floor takes a share of a brim-full cell in proportion to
// how deep the basin stands over it, and no cell holds more than a cell.
double filled(const std::vector<double> &p_deep, double p_edge, double p_scale) {
	double acc = 0.0;
	for (double d : p_deep) {
		acc += MIN(p_scale * d / p_edge, 1.0);
	}
	return acc;
}

} // namespace

void LAFieldHydrosphereSeed::seed(Object *p_field) {
	if (!p_field) {
		return;
	}
	Object *grid = Object::cast_to<Object>(p_field->get("_grid"));
	Object *terrain = Object::cast_to<Object>(p_field->get("_terrain"));
	Object *gravity = Object::cast_to<Object>(p_field->get("_gravity"));
	const int cc = int(p_field->get("_cell_count"));
	const PackedByteArray solid = p_field->get("_solid");
	PackedFloat32Array h2o = p_field->get("_h2o");
	const PackedByteArray regolith = p_field->get("_regolith");
	const PackedFloat32Array porosity = p_field->get("_porosity");
	if (!grid || !terrain || !gravity || cc <= 0 || solid.size() != cc || h2o.size() != cc
			|| regolith.size() != cc || porosity.size() != cc) {
		return;
	}
	const PackedInt32Array nbr = grid->get("neighbours");
	const PackedInt32Array below = gravity->call("down_table");
	const double edge = double(grid->get("cell_size"));
	const double sea_r = double(terrain->call("sea_radius"));
	if (nbr.size() != cc * SLOTS || !(edge > 0.0) || !(sea_r > 0.0)) {
		return;
	}
	const Dictionary body = LABodySeeds::of("planet");
	const double water_kg = double(body.get("hydrosphere_kg", 0.0));
	const double ground_kg = double(body.get("groundwater_kg", 0.0));
	if (!(water_kg > 0.0) || ground_kg < 0.0 || ground_kg >= water_kg) {
		UtilityFunctions::push_error("LAFieldHydrosphereSeed: the body record declares no hydrosphere it "
				"could split between its surface and its pore space, so the planet would seed dry.");
		return;
	}

	// Height above the body centre — the flood's priority key — and the pore space beside it.
	const Vector3 centre = field_centre(p_field);
	std::vector<double> height(cc, 0.0);
	double pore = 0.0;
	for (int c = 0; c < cc; c++) {
		height[c] = double((Vector3(grid->call("cell_world_pos", c)) - centre).length());
		if (regolith[c] != 0) {
			pore += double(porosity[c]);
		}
	}
	const int bins = MAX(int(grid->call("max_span")) + 2, 2);
	std::vector<std::vector<int>> buckets(bins);
	std::vector<double> level(cc, std::numeric_limits<double>::infinity());
	std::vector<char> done(cc, 0);
	auto bin_of = [&](double lv) {
		return CLAMP(int((lv - sea_r) / edge), 0, bins - 1);
	};

	// OUTLETS: an open cell at or below the sea surface drains to the ocean, one on a box face out of it.
	for (int c = 0; c < cc; c++) {
		if (solid[c] != 0) {
			continue;
		}
		bool edged = false;
		for (int d = 0; d < SLOTS; d++) {
			edged = edged || nbr[c * SLOTS + d] < 0;
		}
		if (!edged && height[c] > sea_r) {
			continue;
		}
		level[c] = MAX(height[c], sea_r);
		buckets[bin_of(level[c])].push_back(c);
	}

	// Low -> high, so the first time a cell is popped it holds the lowest level a route out of it spills at.
	for (int b = 0; b < bins; b++) {
		for (size_t qi = 0; qi < buckets[b].size(); qi++) {
			const int c = buckets[b][qi];
			if (done[c] != 0) {
				continue;
			}
			done[c] = 1;
			for (int d = 0; d < SLOTS; d++) {
				const int n = nbr[c * SLOTS + d];
				if (n < 0 || n >= cc || done[n] != 0 || solid[n] != 0) {
					continue;
				}
				const double lv = MAX(height[n], level[c]);
				if (lv < level[n]) {
					level[n] = lv;
					buckets[bin_of(lv)].push_back(n);
				}
			}
		}
	}

	// Water lies on a basin floor: a cell qualifies when the vertical relation puts rock or nothing under
	// it. How deep the basin stands over it is its share of the budget.
	std::vector<int> floors;
	std::vector<double> deep;
	for (int c = 0; c < cc; c++) {
		if (solid[c] != 0 || done[c] == 0 || !std::isfinite(level[c]) || level[c] <= height[c]) {
			continue;
		}
		const int b = below.size() == cc ? below[c] : -1;
		if (b >= 0 && b < cc && solid[b] == 0) {
			continue;
		}
		floors.push_back(c);
		deep.push_back(level[c] - height[c]);
	}
	if (floors.empty() || !(pore > 0.0)) {
		UtilityFunctions::push_error("LAFieldHydrosphereSeed: the flood marked no basin floor or the "
				"regolith walk no pore space, so the body's water has nowhere to stand.");
		return;
	}

	const double full_mol = LASubstances::full_mol_m3("h2o");
	const double cell_mol = full_mol * edge * edge * edge;
	const double mass_mol = la_physical("MOLAR_MASS_WATER_KG_MOL") * cell_mol;
	if (!(mass_mol > 0.0)) {
		return;
	}
	const double sat = ground_kg / (mass_mol * pore);
	const double want = (water_kg - ground_kg) / mass_mol;
	if (sat > 1.0) {
		UtilityFunctions::push_error("LAFieldHydrosphereSeed: the body's groundwater is more water than the "
				"regolith has pore space for, so it cannot stand in the crust.");
		return;
	}
	// A BOX THAT IS A WINDOW ON THE BODY HOLDS PART OF ITS OCEAN. The basins in it fill and the rest of the
	// water is elsewhere on the body; scripts/check_hydrosphere_mass.sh holds the whole box to the whole
	// hydrosphere, which is where a body that cannot hold its own water shows up.
	if (want > double(floors.size())) {
		UtilityFunctions::push_warning("LAFieldHydrosphereSeed: the basins in this box hold less than the "
				"body's water, so they fill and the rest of it stands outside the box.");
	}
	// THE ONE SCALE ON BASIN DEPTH THAT SPENDS THE BUDGET, capped at a brim-full cell: water poured into a
	// basin that is already full runs into the next one.
	double hi = 1.0;
	for (int i = 0; i < 60 && filled(deep, edge, hi) < want; i++) {
		hi *= 2.0;
	}
	double lo = 0.0;
	for (int i = 0; i < FILL_STEPS; i++) {
		const double mid = 0.5 * (lo + hi);
		if (filled(deep, edge, mid) < want) {
			lo = mid;
		} else {
			hi = mid;
		}
	}
	const double thick = 0.5 * (lo + hi);

	float *w = h2o.ptrw();
	for (int c = 0; c < cc; c++) {
		if (regolith[c] != 0) {
			w[c] = float(sat * double(porosity[c]) * full_mol);
		}
	}
	for (size_t i = 0; i < floors.size(); i++) {
		w[floors[i]] = float(MIN(thick * deep[i] / edge, 1.0) * full_mol);
	}
	p_field->set("_h2o", h2o);
}

void LAFieldHydrosphereSeed::_bind_methods() {
	ClassDB::bind_static_method("LAFieldHydrosphereSeed", D_METHOD("seed", "field"),
			&LAFieldHydrosphereSeed::seed);
}
