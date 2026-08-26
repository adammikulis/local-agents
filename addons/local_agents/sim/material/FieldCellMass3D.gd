class_name LAFieldCellMass3D
extends RefCounted

## THE ONE WALK FROM CHANNELS TO KILOGRAMS. A channel amount is mol/m^3, so a cell's mass is the sum over
## every matter channel of amount * molar mass * that cell's own volume.

## [mirror array, molar mass kg/mol] for every channel the field carries as an amount of matter.
static func mirrors(field) -> Array:
	var out: Array = []
	if field == null:
		return out
	var rows: Dictionary = LAChannels.rows()
	var table: Dictionary = LANativeTables.subs().table()
	for name in rows:
		if String(rows[name].get("unit", "")) != "mol_m3":
			continue
		var arr = field.get("_" + String(name))
		if not (arr is PackedFloat32Array) or arr.size() != field._cell_count:
			continue
		var s: Dictionary = table.get(String(rows[name].get("substance", "")), {})
		out.append([arr, float(s.get("molar_mass", 0.0))])
	return out


## The channel names mirrors() returned, in the same order, so a per-mirror total can be named.
static func mirror_names(field) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if field == null:
		return out
	for name in LAChannels.rows():
		if String(LAChannels.rows()[name].get("unit", "")) != "mol_m3":
			continue
		var arr = field.get("_" + String(name))
		if (arr is PackedFloat32Array) and arr.size() == field._cell_count:
			out.append(String(name))
	return out


## The same, restricted to the channels that are gas: a mixture's specific gas constant is R over the
## mole-weighted molar mass of what is actually in the air.
static func gas_mirrors(field) -> Array:
	var out: Array = []
	if field == null:
		return out
	var rows: Dictionary = LAChannels.rows()
	var table: Dictionary = LANativeTables.subs().table()
	for name in rows:
		if String(rows[name].get("phase", "")) != "gas":
			continue
		var arr = field.get("_" + String(name))
		if arr is PackedFloat32Array and arr.size() == field._cell_count:
			out.append([arr,
				float(table.get(String(rows[name].get("substance", "")), {}).get("molar_mass", 0.0))])
	return out


## Moles per m^3 summed into kilograms per m^3 for one cell. Multiply by the cell's own volume for its mass.
static func kg_m3_at(mirrors_of: Array, c: int) -> float:
	var m: float = 0.0
	for pair in mirrors_of:
		m += maxf(pair[0][c], 0.0) * float(pair[1])
	return m
