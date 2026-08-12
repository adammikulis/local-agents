class_name LAFieldDensity3D
extends RefCounted

## BULK DENSITY PER CELL, kg/m^3 — the source term of the gravity solve.
##
## This is the one place the field answers "how much mass is here". A channel is a VOLUME FILL FRACTION,
## so a cell's density is the sum of each substance's fraction times its measured density, with whatever
## fraction is left over holding air. Every density comes from LASubstances; there are no numbers here.
##
## ROCK_FILL IS A SATURATION, NOT A FRACTION. It is the pore-free share of the matrix, so the mineral it
## carries is `rock_fill * (1 - porosity)`. That distinction used to live only inside the deleted rc_of(),
## which is why two subsystems disagreed about how much rock a cell held.
##
## (Explicit types only, no ':=' inferred typing.)


## Channels whose amount is already a volume fraction, paired with the LASubstances id they hold. Built
## from the channel SSOT so a new channel cannot be invisible to gravity.
static func _fraction_channels() -> Dictionary:
	var out: Dictionary = {}
	var rows: Dictionary = LAChannels.rows()
	for name in rows:
		var sub: String = String(rows[name].get("substance", ""))
		if sub == "" or name == "rock_fill":
			continue
		out[String(name)] = sub
	return out


## Density of one substance, kg/m^3, from the substance table. Zero for a substance with no declared
## density, which is a table defect rather than a value to invent.
static func _rho(id: String) -> float:
	return float(LASubstances.table().get(id, {}).get("density", 0.0))


## Bulk density per cell, kg/m^3. `mirrors` maps channel name -> its per-cell array; missing channels
## contribute nothing, because a channel that is not resident is not mass that is somewhere else.
static func of(mirrors: Dictionary, porosity: PackedFloat32Array, cell_count: int) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(cell_count)
	out.fill(0.0)
	var condensed: PackedFloat32Array = PackedFloat32Array()
	condensed.resize(cell_count)
	condensed.fill(0.0)

	var frac: Dictionary = _fraction_channels()
	for name in frac:
		var arr = mirrors.get(name, null)
		if arr == null or arr.size() != cell_count:
			continue
		var rho: float = _rho(String(frac[name]))
		if rho <= 0.0:
			continue
		for c in cell_count:
			var f: float = arr[c]
			out[c] += f * rho
			condensed[c] += f

	# The matrix, whose amount is a saturation of the pore-free share.
	var rock = mirrors.get("rock_fill", null)
	var rho_rock: float = _rho("silicate")
	if rock != null and rock.size() == cell_count and rho_rock > 0.0:
		var has_phi: bool = porosity.size() == cell_count
		for c in cell_count:
			var solid_share: float = rock[c] * (1.0 - (porosity[c] if has_phi else 0.0))
			out[c] += solid_share * rho_rock
			condensed[c] += solid_share

	# Whatever volume is left is air, which has mass and therefore weighs.
	for c in cell_count:
		out[c] += maxf(0.0, 1.0 - condensed[c]) * LAPhysical.AIR_DENSITY_KG_M3
	return out
