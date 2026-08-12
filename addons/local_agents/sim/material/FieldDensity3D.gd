class_name LAFieldDensity3D
extends RefCounted

## BULK DENSITY PER CELL, kg/m^3 — the source term of the gravity solve.

## Volume-fraction channels paired with the LASubstances id they hold, built from the channel SSOT.
static func _fraction_channels() -> Dictionary:
	var out: Dictionary = {}
	var rows: Dictionary = LAChannels.rows()
	for name in rows:
		var sub: String = String(rows[name].get("substance", ""))
		if sub == "":
			continue
		out[String(name)] = sub
	return out


## Kilograms one unit of a channel of `id` carries at a cell's temperature and pressure.
static func _kg_per_unit(id: String, eos: bool, t_c: float, p_pa: float) -> float:
	if eos:
		return LASubstances.density(id, t_c, p_pa)
	return float(LASubstances.table().get(id, {}).get("density", 0.0))


## Bulk density per cell, kg/m^3. `mirrors` maps channel name -> per-cell array; a missing channel
## contributes nothing. Temperature and pressure are required and are never invented.
static func of(mirrors: Dictionary, cell_count: int) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(cell_count)
	out.fill(0.0)

	var temp = mirrors.get("temp", null)
	var pres = mirrors.get("pressure", null)
	if not (temp is PackedFloat32Array and temp.size() == cell_count) \
			or not (pres is PackedFloat32Array and pres.size() == cell_count):
		push_error("LAFieldDensity3D.of: no temperature or pressure mirror, so no cell has a density.")
		return out

	var frac: Dictionary = _fraction_channels()
	for name in frac:
		var arr = mirrors.get(name, null)
		if arr == null or arr.size() != cell_count:
			continue
		var id: String = String(frac[name])
		var eos: bool = LASubstances.has_eos(id)
		for c in cell_count:
			var f: float = arr[c]
			var p_pa: float = pres[c]
			if f <= 0.0 or p_pa <= 0.0:
				continue
			out[c] += f * _kg_per_unit(id, eos, temp[c], p_pa)
	return out
