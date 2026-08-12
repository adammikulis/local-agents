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


## Kilograms one unit of a channel of `id` carries, at a cell's own temperature and pressure. A substance
## with an equation of state is held here as a VOLUME FRACTION, so this is its density and it responds to
## both. A substance without one — the gases, the organic element stocks — is held as a molar amount whose
## kilograms per unit is a fixed conversion: a gas answers temperature and pressure by changing how much of
## it is in the cell, never by changing what a mole of it weighs.
static func _kg_per_unit(id: String, eos: bool, t_c: float, p_pa: float) -> float:
	if eos:
		return LASubstances.density(id, t_c, p_pa)
	return float(LASubstances.table().get(id, {}).get("density", 0.0))


## Bulk density per cell, kg/m^3. `mirrors` maps channel name -> its per-cell array; missing channels
## contribute nothing, because a channel that is not resident is not mass that is somewhere else.
##
## TEMPERATURE AND PRESSURE ARE REQUIRED, and a cell without them weighs nothing here. Both decide which
## phase a substance is in and how much room its mass takes; neither may be invented, and a density read
## off a temperature nobody measured would be a fiction the gravity solve could not tell from a fact.
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
