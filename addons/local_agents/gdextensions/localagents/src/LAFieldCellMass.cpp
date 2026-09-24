#include <godot_cpp/variant/utility_functions.hpp>
#include "LAGridGeometry.hpp"
#include "LAFieldCellMass.hpp"

#include "LAFieldMirrors.hpp"
#include "LAScriptCall.hpp"
#include "LASubstances.hpp"
#include "LAPlanetTables.hpp"
#include "LAMixtureEnthalpy.hpp"
#include "LAPhysicalRead.hpp"

#include <godot_cpp/classes/rendering_device.hpp>

#include <algorithm>
#include <cmath>
#include <vector>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

using namespace godot;

namespace {

const char *CHANNELS_GD = "res://addons/local_agents/sim/material/Channels.gd";
const char *TRANSPORT_PASS_GD = "res://addons/local_agents/sim/material/sphere_passes/FluxPass.gd";

// The mirrors of every channel whose row passes `p_want`, paired with the molar mass of its substance.
Array walk(Object *p_field, const String &p_key, const String &p_value, bool p_names_only,
		PackedStringArray *r_names) {
	Array out;
	if (!p_field) {
		return out;
	}
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const Dictionary table = LASubstances::table();
	const int cc = int(p_field->get("_cell_count"));
	const Array names = rows.keys();
	for (int i = 0; i < names.size(); i++) {
		const String name = names[i];
		const Dictionary row = rows[name];
		if (String(row.get(p_key, "")) != p_value) {
			continue;
		}
		const PackedFloat32Array arr = LAFieldMirrors::of(p_field, name);
		if (arr.size() != cc) {
			continue;
		}
		if (p_names_only) {
			r_names->append(name);
			continue;
		}
		const Dictionary s = table.get(String(row.get("substance", "")), Dictionary());
		Array pair;
		pair.append(arr);
		pair.append(double(s.get("molar_mass", 0.0)));
		out.append(pair);
	}
	return out;
}

} // namespace

// Kilograms of each substance in one cell, keyed by LASubstances id: mol/m^3 times molar mass times the
// cell's own volume. Gas is matter with heat capacity like any other and is counted with the rest. EMPTY
// for a cell under the bulk-density floor state_derive.glsl empties on: it holds no bulk state at all.
// The solid mask as the kernels read it: 1.0 where the cell is lattice rock.
void LAFieldCellMass3D::upload_solid(RenderingDevice *p_rd, const Dictionary &p_bufs, Object *p_field) {
	if (!p_rd || !p_field || !p_bufs.has("solid")) {
		return;
	}
	const PackedByteArray m = p_field->get("_solid");
	PackedFloat32Array f;
	f.resize(m.size());
	float *w = f.ptrw();
	for (int i = 0; i < m.size(); i++) {
		w[i] = m[i] != 0 ? 1.0f : 0.0f;
	}
	PackedByteArray b = f.to_byte_array();
	p_rd->buffer_update(RID(p_bufs["solid"]), 0, b.size(), b);
}

void LAFieldCellMass3D::upload_regolith(RenderingDevice *p_rd, const Dictionary &p_bufs, Object *p_field) {
	if (!p_rd || !p_field) {
		return;
	}
	const int cc = int(p_field->get("_cell_count"));
	const PackedByteArray m = p_field->get("_regolith");
	if (m.size() != cc || !p_bufs.has("regolith")) {
		return;
	}
	PackedFloat32Array f;
	f.resize(cc);
	float *w = f.ptrw();
	bool any = false;
	for (int i = 0; i < cc; i++) {
		w[i] = m[i] != 0 ? 1.0f : 0.0f;
		any = any || m[i] != 0;
	}
	PackedByteArray b = f.to_byte_array();
	p_rd->buffer_update(RID(p_bufs["regolith"]), 0, b.size(), b);
	const PackedFloat32Array g = LAFieldMirrors::of(p_field, "grain");
	if (g.size() == cc && p_bufs.has("grain")) {
		const PackedByteArray gb = g.to_byte_array();
		p_rd->buffer_update(RID(p_bufs["grain"]), 0, gb.size(), gb);
	}
	const PackedFloat32Array por = LAFieldMirrors::of(p_field, "porosity");
	if (any && por.size() == cc && p_bufs.has("porosity")) {
		const PackedByteArray pb = por.to_byte_array();
		p_rd->buffer_update(RID(p_bufs["porosity"]), 0, pb.size(), pb);
	}
}

void LAFieldCellMass3D::regolith(Object *p_field) {
	if (!p_field) {
		return;
	}
	Object *grid = Object::cast_to<Object>(p_field->get("_grid"));
	Object *gravity = Object::cast_to<Object>(p_field->get("_gravity"));
	const int cc = int(p_field->get("_cell_count"));
	const PackedByteArray solid = p_field->get("_solid");
	if (!grid || !gravity || cc <= 0 || solid.size() != cc) {
		UtilityFunctions::push_error("LAFieldCellMass3D.regolith: no grid, no gravity or a solid mask of the wrong size; no regolith.");
		return;
	}
	const PackedInt32Array up = gravity->call("up_table");
	const PackedFloat64Array cw = LAGridGeometry::centres_f64(grid);
	Array cargs;
	cargs.append(p_field);
	const Vector3 centre = la_call_gd("res://addons/local_agents/sim/material/FieldGeometry3D.gd", "centre", cargs);
	const double sea_r = double(p_field->call("sea_radius"));
	const double circulation_m = la_physical("GROUNDWATER_CIRCULATION_M");
	const double phi0 = la_physical("REGOLITH_SURFACE_POROSITY");
	const PackedFloat32Array depth = p_field->get("_surface_depth");
	const PackedFloat32Array edges = grid->call("cell_edges");
	const PackedFloat32Array rock_fr = p_field->get("_rock_fraction");
	const double z_c = la_physical("COMPACTION_LENGTH_M");
	const double d_low = la_physical("GRAIN_D_LOWLAND_M");
	const double d_up = la_physical("GRAIN_D_UPLAND_M");
	PackedByteArray mask;
	PackedFloat32Array grain, por;
	mask.resize(cc);
	grain.resize(cc);
	por.resize(cc);
	mask.fill(0);
	grain.fill(0.0f);
	por.fill(0.0f);
	// THE AQUIFER IS A DEPTH: rock whose top lies within the circulation depth of its own ground. The
	// porosity is Athy's law averaged over the rock's depth span in the cell, whatever the cell's size.
	std::vector<double> radius(cc, 0.0);
	std::vector<double> z_top(cc, -1.0), z_bot(cc, -1.0);
	double highest = sea_r;
	const bool walkable = up.size() >= cc && cw.size() >= cc * 3 && depth.size() == cc && edges.size() >= cc
			&& rock_fr.size() == cc;
	for (int c = 0; c < cc && walkable; c++) {
		radius[c] = std::hypot(cw[c * 3] - double(centre.x), cw[c * 3 + 1] - double(centre.y), cw[c * 3 + 2] - double(centre.z));
		// Any rock counts, locked or not: a cut cell's rock is the ground's own first metres.
		if (!(rock_fr[c] > 0.0f)) {
			continue;
		}
		const double e = double(edges[c]);
		const double d = double(depth[c]);
		z_top[c] = std::max(d - 0.5 * e, 0.0);
		z_bot[c] = d + 0.5 * e;
		if (z_top[c] < circulation_m) {
			highest = std::max(highest, radius[c]);
		}
	}
	const double relief = std::max(highest - sea_r, double(grid->get("cell_size")));
	uint8_t *mw = mask.ptrw();
	float *gw = grain.ptrw();
	float *pw = por.ptrw();
	for (int c = 0; c < cc; c++) {
		if (z_bot[c] <= z_top[c] || z_top[c] >= circulation_m) {
			continue;
		}
		const double height = std::clamp((radius[c] - sea_r) / relief, 0.0, 1.0);
		const double span = z_bot[c] - z_top[c];
		mw[c] = 1;
		gw[c] = float(d_low * std::pow(d_up / d_low, height));
		pw[c] = float(phi0 * z_c / span * (std::exp(-z_top[c] / z_c) - std::exp(-z_bot[c] / z_c)));
	}
	int marked = 0;
	int solids = 0;
	double z_min = 1.0e300;
	for (int c = 0; c < cc; c++) {
		marked += mw[c] != 0 ? 1 : 0;
		if (z_bot[c] > z_top[c]) {
			solids++;
			z_min = std::min(z_min, z_top[c]);
		}
	}
	if (marked == 0) {
		UtilityFunctions::push_error(String("LAFieldCellMass3D.regolith: no rock within ")
				+ String::num(circulation_m) + " m of its ground: " + String::num_int64(solids)
				+ " rock-bearing cells, tables " + (walkable ? "walked" : "MISSING (surface depth or edges)")
				+ ", shallowest rock top " + String::num(z_min) + " m.");
	}
	p_field->set("_regolith", mask);
	LAFieldMirrors::store(p_field, "grain", grain);
	LAFieldMirrors::store(p_field, "porosity", por);
}

Dictionary LAFieldCellMass3D::masses_at(Object *p_field, int p_c, double p_cell_m3) {
	Dictionary out;
	if (!p_field || p_c < 0) {
		return out;
	}
	LAFieldMirrors *m = LAFieldMirrors::mirrors_of(p_field);
	if (m == nullptr) {
		return out;
	}
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const Dictionary table = LASubstances::table();
	const Array names = rows.keys();
	double total_kg = 0.0;
	for (int i = 0; i < names.size(); i++) {
		const String name = names[i];
		const Dictionary row = rows[name];
		const String sub = String(row.get("substance", ""));
		if (sub.is_empty() || String(row.get("unit", "")) != "mol_m3") {
			continue;
		}
		const double a = m->at(name, p_c);
		if (!(a > 0.0)) {
			continue;
		}
		const Dictionary srow = table.get(sub, Dictionary());
		const double kg = a * double(srow.get("molar_mass", 0.0)) * p_cell_m3;
		out[sub] = double(out.get(sub, 0.0)) + kg;
		total_kg += kg;
	}
	if (!(total_kg > 0.0)) {
		return Dictionary();
	}
	return out;
}

// Moles of gas in one cell: a channel amount is mol/m^3, so it is that times the cell's own volume.
double LAFieldCellMass3D::gas_moles_at(Object *p_field, int p_c, double p_cell_m3) {
	if (!p_field || p_c < 0) {
		return 0.0;
	}
	LAFieldMirrors *m = LAFieldMirrors::mirrors_of(p_field);
	if (m == nullptr) {
		return 0.0;
	}
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const Array names = rows.keys();
	double n = 0.0;
	for (int i = 0; i < names.size(); i++) {
		const String name = names[i];
		const Dictionary row = rows[name];
		if (String(row.get("phase", "")) != "gas" || String(row.get("substance", "")).is_empty()) {
			continue;
		}
		const double a = m->at(name, p_c);
		if (a > 0.0) {
			n += a * p_cell_m3;
		}
	}
	return n;
}

// THE ROCK'S OWN TEMPERATURE per cell, C: the geotherm's mean over the depth span of the rock the cell
// holds, running down from the local ground; a cell with no rock reads the surface's.
PackedFloat32Array LAFieldCellMass3D::rock_temperature(Object *p_field, Object *p_grid, double p_r_body,
		double p_t_surface_c, const PackedFloat32Array &p_depth) {
	PackedFloat32Array out;
	if (!p_field || !p_grid) {
		return out;
	}
	const int cc = int(p_field->get("_cell_count"));
	const PackedFloat32Array edges = p_grid->call("cell_edges");
	const double kelvin = la_physical("KELVIN_OFFSET");
	// The mean over each cell's rock: N_S depths through its span under the surface.
	const int n_s = 16;
	PackedFloat64Array z;
	z.resize(cc * n_s);
	std::vector<bool> rock(cc, false);
	for (int c = 0; c < cc; c++) {
		const double depth = c < p_depth.size() ? double(p_depth[c]) : 0.0;
		const double e = c < edges.size() ? double(edges[c]) : 0.0;
		const double d_lo = std::max(depth - 0.5 * e, 0.0);
		const double d_hi = depth + 0.5 * e;
		rock[c] = d_hi > d_lo;
		for (int k = 0; k < n_s; k++) {
			z[c * n_s + k] = d_lo + (d_hi - d_lo) * (double(k) + 0.5) / double(n_s);
		}
	}
	const PackedFloat64Array t_k = LAPlanetComposition::geotherm_at_depths(p_r_body, p_t_surface_c, z);
	out.resize(cc);
	float *w = out.ptrw();
	for (int c = 0; c < cc; c++) {
		double acc = 0.0;
		for (int k = 0; k < n_s; k++) {
			acc += t_k[c * n_s + k];
		}
		w[c] = float(rock[c] ? acc / double(n_s) - kelvin : p_t_surface_c);
	}
	return out;
}

Dictionary LAFieldCellMass3D::seed_enthalpy(Object *p_field, Object *p_grid,
		const PackedFloat32Array &p_t_rock, double p_t_surface_c,
		const PackedFloat32Array &p_p_pa, const PackedFloat32Array &p_p_rock) {
	Dictionary out;
	if (!p_field || !p_grid) {
		return out;
	}
	const int cc = int(p_field->get("_cell_count"));
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const Dictionary table = LASubstances::table();
	const char *MATTER_GD = "res://addons/local_agents/sim/material/MatterChannels.gd";
	// Every matter channel once: its mirror, substance, molar mass, entry, gas flag.
	struct Chan { PackedFloat32Array arr; String sub; double molar; int entry; bool gas; bool lattice; double full; };
	std::vector<Chan> chans;
	const Array names = rows.keys();
	for (int i = 0; i < names.size(); i++) {
		const String name = names[i];
		const Dictionary row = rows[name];
		const String sub = String(row.get("substance", ""));
		if (sub.is_empty() || String(row.get("unit", "")) != "mol_m3") {
			continue;
		}
		Chan ch;
		ch.arr = LAFieldMirrors::of(p_field, name);
		if (ch.arr.size() != cc) {
			continue;
		}
		ch.sub = sub;
		ch.molar = double(Dictionary(table.get(sub, Dictionary())).get("molar_mass", 0.0));
		Array a1;
		a1.append(sub);
		ch.entry = int(la_call_gd(MATTER_GD, "entry_of", a1));
		ch.gas = String(row.get("phase", "")) == "gas";
		ch.lattice = bool(row.get("lattice", false));
		// mol/m^3 at which a cell is full of it: the same full amount state_derive.glsl's props carry.
		ch.full = LASubstances::full_mol_m3(sub);
		chans.push_back(ch);
	}
	const PackedVector3Array centres = p_grid->get("centres");
	const PackedFloat32Array vol = p_grid->call("cell_volumes");
	const PackedFloat32Array rock_fr = p_field->get("_rock_fraction");
	const double full_h2o = LASubstances::full_mol_m3("h2o");
	const double kg_per_mol_h2o = double(Dictionary(table.get("h2o", Dictionary())).get("molar_mass", 0.0));
	const Vector3 centre = p_field->call("centre");
	PackedFloat32Array h;
	h.resize(cc);
	float *hw = h.ptrw();
	PackedFloat32Array h_lith;
	h_lith.resize(cc);
	float *lw = h_lith.ptrw();
	double total_j = 0.0;
	for (int c = 0; c < cc; c++) {
		hw[c] = 0.0f;
		lw[c] = 0.0f;
		const double cell_m3 = c < vol.size() ? double(vol[c]) : 0.0;
		if (!(cell_m3 > 0.0) || c >= p_p_pa.size() || c >= centres.size()) {
			continue;
		}
		// The rock and its pore water hold the rock's own temperature, the sea and the air the surface's.
		const double t_rock = c < p_t_rock.size() ? double(p_t_rock[c]) : p_t_surface_c;
		const double f_rock = c < rock_fr.size() ? std::max(double(rock_fr[c]), 0.0) : 0.0;
		const double t_gas = f_rock < 1.0 ? p_t_surface_c : t_rock;
		// The fluid's entries at the fluid's own pressure, the lattice's at the column its rock carries.
		const double p_pa = std::max(double(p_p_pa[c]), 0.0);
		const double p_rock = c < p_p_rock.size() ? std::max(double(p_p_rock[c]), 0.0) : p_pa;
		double v_cond = 0.0, m_h2o_pore = 0.0, total_kg = 0.0;
		for (const Chan &ch : chans) {
			const double a = double(ch.arr[c]);
			if (!(a > 0.0)) {
				continue;
			}
			const double m = a * ch.molar * cell_m3;
			total_kg += m;
			if (!ch.gas && ch.full > 0.0) {
				v_cond += a / ch.full;
			}
			if (ch.entry == 0 && ch.lattice) {
				m_h2o_pore += m;
			}
		}
		if (!(total_kg > 0.0)) {
			continue;   // no matter, no joules to hold
		}
		// The gas room: the cell less every condensed volume, where the vapour stands at saturation.
		const double room = cell_m3 * std::max(1.0 - v_cond, 0.0);
		// TWO RESERVOIRS: the lattice (rock and its pore water) at the geotherm, the fluid (sea, air) at
		// the surface. Seeded rock is bedrock, so every mineral is the lattice's. EVERY substance is
		// weighed on its own phase ladder, the one state_derive.glsl reads the enthalpy back over.
		double h_l = 0.0;
		double h_f = 0.0;
		for (const Chan &ch : chans) {
			const double a = double(ch.arr[c]);
			if (!(a > 0.0)) {
				continue;
			}
			const double m = a * ch.molar * cell_m3;
			if (ch.lattice || (!ch.gas && ch.entry != 0)) {
				h_l += m * LAMixtureEnthalpy::specific_enthalpy(ch.sub, t_rock, p_rock, m, 0.0);
			} else {
				h_f += m * LAMixtureEnthalpy::specific_enthalpy(ch.sub,
						ch.gas ? t_gas : p_t_surface_c, p_pa, m, room);
			}
		}
		const double h_j = h_l + h_f;
		// THE CELL KEEPS INTERNAL ENERGY: U = H - pV over the room the lithic matter leaves, the same
		// room state_derive.glsl reads the enthalpy back over.
		double v_lith = 0.0;
		for (const Chan &ch : chans) {
			const double a = double(ch.arr[c]);
			if (!(a > 0.0) || ch.gas || ch.entry == 0 || !(ch.full > 0.0)) {
				continue;
			}
			v_lith += a / ch.full;
		}
		// The fluid's pV is the fluid's: a cell whose free matter is nothing has no room at any pressure,
		// and the room is what the lattice leaves, its pore water included.
		const double v_pore = full_h2o > 0.0 ? m_h2o_pore / (kg_per_mol_h2o * full_h2o * cell_m3) : 0.0;
		const double room_f = std::max(1.0 - std::min(v_lith + v_pore, 1.0), 0.0);
		const double e_j = h_j - (h_f > 0.0 ? p_pa * room_f * cell_m3 : 0.0);
		hw[c] = float((e_j - h_l) / cell_m3);
		lw[c] = float(h_l / cell_m3);
		total_j += e_j;
	}
	out["e"] = h;
	out["e_lith"] = h_lith;
	out["total_j"] = total_j;
	return out;
}

Array LAFieldCellMass3D::mirrors(Object *p_field) {
	return walk(p_field, "unit", "mol_m3", false, nullptr);
}

PackedStringArray LAFieldCellMass3D::mirror_names(Object *p_field) {
	PackedStringArray out;
	walk(p_field, "unit", "mol_m3", true, &out);
	return out;
}

double LAFieldCellMass3D::kg_m3_at(const Array &p_mirrors, int p_c) {
	double m = 0.0;
	for (int i = 0; i < p_mirrors.size(); i++) {
		const Array pair = p_mirrors[i];
		const PackedFloat32Array arr = pair[0];
		m += MAX(double(arr[p_c]), 0.0) * double(pair[1]);
	}
	return m;
}

void LAFieldCellMass3D::_bind_methods() {
	ClassDB::bind_static_method("LAFieldCellMass3D",
			D_METHOD("upload_regolith", "rd", "bufs", "field"), &LAFieldCellMass3D::upload_regolith);
	ClassDB::bind_static_method("LAFieldCellMass3D",
			D_METHOD("upload_solid", "rd", "bufs", "field"), &LAFieldCellMass3D::upload_solid);
	ClassDB::bind_static_method("LAFieldCellMass3D", D_METHOD("regolith", "field"), &LAFieldCellMass3D::regolith);
	ClassDB::bind_static_method("LAFieldCellMass3D",
			D_METHOD("masses_at", "field", "cell", "cell_m3"), &LAFieldCellMass3D::masses_at);
	ClassDB::bind_static_method("LAFieldCellMass3D",
			D_METHOD("gas_moles_at", "field", "cell", "cell_m3"), &LAFieldCellMass3D::gas_moles_at);
	ClassDB::bind_static_method("LAFieldCellMass3D",
			D_METHOD("rock_temperature", "field", "grid", "r_body", "t_surface_c", "depth"),
			&LAFieldCellMass3D::rock_temperature);
	ClassDB::bind_static_method("LAFieldCellMass3D",
			D_METHOD("seed_enthalpy", "field", "grid", "t_rock", "t_surface_c", "p_pa", "p_rock"),
			&LAFieldCellMass3D::seed_enthalpy);
	ClassDB::bind_static_method("LAFieldCellMass3D", D_METHOD("mirrors", "field"),
			&LAFieldCellMass3D::mirrors);
	ClassDB::bind_static_method("LAFieldCellMass3D", D_METHOD("mirror_names", "field"),
			&LAFieldCellMass3D::mirror_names);
	ClassDB::bind_static_method("LAFieldCellMass3D", D_METHOD("kg_m3_at", "mirrors", "c"),
			&LAFieldCellMass3D::kg_m3_at);
}
