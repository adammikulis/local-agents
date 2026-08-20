class_name LAFieldEnthalpySeed
extends RefCounted

## Fill the enthalpy state from a starting TEMPERATURE, once the channels holding matter are seeded.
## Seeding-phase creation: every joule is declared through the seal.

const PC: GDScript = preload("res://addons/local_agents/sim/material/PhysicalConstants.gd")


## Kilograms of each substance in cell `c`, keyed by LASubstances id: amount (mol/m^3) times molar mass
## times the cell volume. Gas is matter with heat capacity like any other: state_derive.glsl weighs it,
## so a seed that skips it hands the air zero joules.
static func masses_at(f, c: int, cell_m3: float) -> Dictionary:
	var out: Dictionary = {}
	var tbl: Dictionary = LASubstances.table()
	var rows: Dictionary = LAChannels.rows()
	for name in rows:
		var sub: String = String(rows[name].get("substance", ""))
		if sub == "" or String(rows[name].get("unit", "")) != "mol_m3":
			continue
		var arr = f.get("_" + String(name))
		if not (arr is PackedFloat32Array) or c >= arr.size():
			continue
		var amount: float = maxf(arr[c], 0.0)
		if amount <= 0.0:
			continue
		var mm: float = float(tbl.get(sub, {}).get("molar_mass", 0.0))
		out[sub] = float(out.get(sub, 0.0)) + amount * mm * cell_m3
	return out


## Moles of gas in cell `c`: amount times volume, since a channel amount is mol/m^3.
static func gas_moles_at(f, c: int, cell_m3: float) -> float:
	var n: float = 0.0
	var rows: Dictionary = LAChannels.rows()
	for name in rows:
		if String(rows[name].get("phase", "")) != "gas":
			continue
		if String(rows[name].get("substance", "")) == "":
			continue
		var arr = f.get("_" + String(name))
		if not (arr is PackedFloat32Array) or c >= arr.size():
			continue
		n += maxf(arr[c], 0.0) * cell_m3
	return n


## The cell's enthalpy at (t, p) decomposed the way state_derive.glsl carries it: the two ladder entries
## off their own curves, everything else lumped sensible at LAMatterChannels' capacities. Joules and J/K.
static func entry_enthalpies(masses: Dictionary, n_gas_mol: float, t_c: float, p_pa: float) -> Dictionary:
	var h_h2o: float = 0.0
	var h_sil: float = 0.0
	var mc: float = 0.0
	for id in masses:
		var m: float = float(masses[id])
		if m <= 0.0:
			continue
		match LAMatterChannels.entry_of(String(id)):
			LAMatterChannels.Entry.H2O:
				h_h2o += m * LAMixtureEnthalpy.specific_enthalpy(String(id), t_c, p_pa, m, n_gas_mol)
			LAMatterChannels.Entry.SILICATE:
				h_sil += m * LAMixtureEnthalpy.specific_enthalpy(String(id), t_c, p_pa, m, n_gas_mol)
			_:
				mc += m * LAMatterChannels.specific_heat(String(id))
	return {"h_h2o": h_h2o, "h_silicate": h_sil,
		"h_sensible": mc * (t_c + PC.KELVIN_OFFSET), "cap_sensible": mc}


## Seed `_h` so every cell starts at `t_c`. Pressure is the reference: the column has not been solved yet,
## so this declares the ENERGY a cell holds and lets the ladder say what temperature that is in situ.
static func seed(f, t_c: float) -> void:
	if f._cell_count <= 0:
		return
	f._h.resize(f._cell_count)
	var vol: PackedFloat32Array = LAMaterialFieldCellVolume3D.of(f)
	if vol.size() != f._cell_count:
		push_error("LAFieldEnthalpySeed: no cell volumes, so no enthalpy can be seeded.")
		return
	var total_j: float = 0.0
	for c in f._cell_count:
		var cell_m3: float = vol[c]
		if cell_m3 <= 0.0:
			continue
		var e: Dictionary = entry_enthalpies(
			masses_at(f, c, cell_m3), gas_moles_at(f, c, cell_m3), t_c, PC.STANDARD_PRESSURE_PA)
		var h_j: float = float(e["h_h2o"]) + float(e["h_silicate"]) + float(e["h_sensible"])
		f._h[c] = h_j / cell_m3
		total_j += h_j
	if f._seal != null:
		f._seal.note_creation("seed_enthalpy_j", total_j)
