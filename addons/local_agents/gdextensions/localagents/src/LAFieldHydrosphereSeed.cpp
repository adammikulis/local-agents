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
// Bisection steps on the one scale that spends the water budget. Monotone, so this is convergence.
const int FILL_STEPS = 80;

Vector3 field_centre(Object *p_field) {
	Array args;
	args.append(p_field);
	return la_call_gd(GEOMETRY_GD, "centre", args);
}

// Cubic metres of brim-full water the scale lays down: a floor takes a share of its own cell in
// proportion to how deep the basin stands over it, and no cell holds more than itself.
double filled(const std::vector<double> &p_deep, const std::vector<double> &p_edge,
		const std::vector<double> &p_vol, double p_scale) {
	double acc = 0.0;
	for (size_t i = 0; i < p_deep.size(); i++) {
		acc += MIN(p_scale * p_deep[i] / p_edge[i], 1.0) * p_vol[i];
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
	const PackedInt32Array slot_off = grid->get("slot_off");
	const PackedFloat32Array edges = grid->call("cell_edges");
	const PackedInt32Array below = gravity->call("down_table");
	const double sea_r = double(terrain->call("sea_radius"));
	if (nbr.is_empty() || slot_off.size() < cc * SLOT_STRIDE || edges.size() < cc || !(sea_r > 0.0)) {
		return;
	}
	// RESOLUTION FOLLOWS POSITION, so a cell's edge and volume are its own.
	std::vector<double> edge(cc, 0.0), vol(cc, 0.0);
	double edge_min = std::numeric_limits<double>::infinity();
	for (int c = 0; c < cc; c++) {
		edge[c] = double(edges[c]);
		vol[c] = edge[c] * edge[c] * edge[c];
		edge_min = MIN(edge_min, edge[c]);
	}
	if (!(edge_min > 0.0)) {
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
			pore += double(porosity[c]) * vol[c];
		}
	}
	const int bins = MAX(int(grid->call("max_span")) + 2, 2);
	std::vector<std::vector<int>> buckets(bins);
	std::vector<double> level(cc, std::numeric_limits<double>::infinity());
	std::vector<char> done(cc, 0);
	auto bin_of = [&](double lv) {
		return CLAMP(int((lv - sea_r) / edge_min), 0, bins - 1);
	};

	// OUTLETS: an open cell at or below the sea surface drains to the ocean, one on a box face out of it.
	for (int c = 0; c < cc; c++) {
		if (solid[c] != 0) {
			continue;
		}
		bool edged = false;
		for (int f = slot_off[c * SLOT_STRIDE]; f < slot_off[c * SLOT_STRIDE + 6]; f++) {
			edged = edged || nbr[f] < 0;
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
			for (int f = slot_off[c * SLOT_STRIDE]; f < slot_off[c * SLOT_STRIDE + 6]; f++) {
				const int n = nbr[f];
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
	// NO PORE SPACE IS A BROKEN REGOLITH WALK: every box on this body has rock in it, and rock has
	// porosity, so a walk that finds none found nothing rather than a body without groundwater.
	if (!(pore > 0.0)) {
		UtilityFunctions::push_error("LAFieldHydrosphereSeed: the regolith walk found no pore space, so "
				"the body's groundwater has nowhere to stand.");
		return;
	}

	const double full_mol = LASubstances::full_mol_m3("h2o");
	// kg one m^3 of brim-full water weighs, so a budget in kg becomes one in cubic metres of full cell.
	const double kg_m3 = la_physical("MOLAR_MASS_WATER_KG_MOL") * full_mol;
	if (!(kg_m3 > 0.0)) {
		return;
	}
	const double sat = MIN(ground_kg / (kg_m3 * pore), 1.0);
	const double want = (water_kg - ground_kg) / kg_m3;
	float *w = h2o.ptrw();
	// THE PORE WATER STANDS WHEREVER THERE IS ROCK, basin or no basin.
	for (int c = 0; c < cc; c++) {
		if (regolith[c] != 0) {
			w[c] = float(sat * double(porosity[c]) * full_mol);
		}
	}
	// A BOX WITH NO BASIN IS A BOX ON LAND, not a broken seed: a column standing above the sea holds
	// none of the body's surface water, and the rest of the body holds all of it.
	if (floors.empty()) {
		UtilityFunctions::push_warning("LAFieldHydrosphereSeed: this box holds no basin floor, so all of "
				"the body's surface water stands outside it.");
		p_field->set("_h2o", h2o);
		return;
	}
	std::vector<double> floor_edge, floor_vol;
	double floor_room = 0.0;
	for (size_t i = 0; i < floors.size(); i++) {
		floor_edge.push_back(edge[floors[i]]);
		floor_vol.push_back(vol[floors[i]]);
		floor_room += vol[floors[i]];
	}
	// A BOX THAT IS A WINDOW ON THE BODY HOLDS PART OF ITS OCEAN AND PART OF ITS GROUNDWATER. The basins
	// and the pore space in it fill and the rest of the water is elsewhere on the body;
	// scripts/check_hydrosphere_mass.sh holds the whole box to the whole hydrosphere, which is where a
	// body that cannot hold its own water shows up.
	if (want > floor_room || ground_kg > kg_m3 * pore) {
		UtilityFunctions::push_warning("LAFieldHydrosphereSeed: the basins and pore space in this box hold "
				"less than the body's water, so they fill and the rest of it stands outside the box.");
	}
	// THE ONE SCALE ON BASIN DEPTH THAT SPENDS THE BUDGET, capped at a brim-full cell: water poured into a
	// basin that is already full runs into the next one.
	double hi = 1.0;
	for (int i = 0; i < 60 && filled(deep, floor_edge, floor_vol, hi) < want; i++) {
		hi *= 2.0;
	}
	double lo = 0.0;
	for (int i = 0; i < FILL_STEPS; i++) {
		const double mid = 0.5 * (lo + hi);
		if (filled(deep, floor_edge, floor_vol, mid) < want) {
			lo = mid;
		} else {
			hi = mid;
		}
	}
	const double thick = 0.5 * (lo + hi);
	for (size_t i = 0; i < floors.size(); i++) {
		w[floors[i]] = float(MIN(thick * deep[i] / edge[floors[i]], 1.0) * full_mol);
	}
	p_field->set("_h2o", h2o);
}

void LAFieldHydrosphereSeed::_bind_methods() {
	ClassDB::bind_static_method("LAFieldHydrosphereSeed", D_METHOD("seed", "field"),
			&LAFieldHydrosphereSeed::seed);
}
