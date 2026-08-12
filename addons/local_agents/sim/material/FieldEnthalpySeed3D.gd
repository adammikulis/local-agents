class_name LAFieldEnthalpySeed
extends RefCounted

## Fill the enthalpy state from a starting TEMPERATURE, once the channels holding matter are seeded.
## Seeding-phase creation: every joule is declared through the seal.

const PC: GDScript = preload("res://addons/local_agents/sim/material/PhysicalConstants.gd")


## Kilograms of each substance in cell `c`, keyed by LASubstances id.
static func masses_at(f, c: int, cell_m3: float) -> Dictionary:
	var out: Dictionary = {}
	var tbl: Dictionary = LASubstances.table()
	for name in LAChannels.mixture_channels():
		var arr = f.get("_" + String(name))
		if not (arr is PackedFloat32Array) or c >= arr.size():
			continue
		var row: Dictionary = LAChannels.mixture_channels()[name]
		var vf: float = maxf(arr[c], 0.0)
		if vf <= 0.0:
			continue
		var id: String = String(row["substance"])
		var rho: float = float(tbl.get(id, {}).get("density", 0.0))
		out[id] = float(out.get(id, 0.0)) + vf * rho * cell_m3
	return out


## Moles of gas in cell `c`. The gas channels carry kilograms per channel unit, not a material density.
static func gas_moles_at(f, c: int, cell_m3: float) -> float:
	var tbl: Dictionary = LASubstances.table()
	var n: float = 0.0
	var rows: Dictionary = LAChannels.rows()
	for name in rows:
		if String(rows[name].get("phase", "")) != "gas":
			continue
		var id: String = String(rows[name].get("substance", ""))
		if id == "":
			continue
		var arr = f.get("_" + String(name))
		if not (arr is PackedFloat32Array) or c >= arr.size():
			continue
		var entry: Dictionary = tbl.get(id, {})
		var mm: float = float(entry.get("molar_mass", 0.0))
		if mm <= 0.0:
			continue
		var kg: float = maxf(arr[c], 0.0) * float(entry.get("density", 0.0)) * cell_m3
		n += kg / mm
	return n


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
		var h_j: float = LAMixtureEnthalpy.enthalpy_at(
			masses_at(f, c, cell_m3), gas_moles_at(f, c, cell_m3), t_c, PC.STANDARD_PRESSURE_PA)
		f._h[c] = h_j / cell_m3
		total_j += h_j
	if f._seal != null:
		f._seal.note_creation("seed_enthalpy_j", total_j)
