class_name LAMaterialFieldMineralProfile3D
extends RefCounted

## LAMaterialFieldMineralProfile3D: WHERE the planet's loose mineral is, by radius — not how much of it.
## Every reading is a reduce row the device folded; nothing here walks a cell.

const RowsScript: GDScript = preload("res://addons/local_agents/sim/material/reduce/MineralRows.gd")

## A cell counts as actively eroding when it carries a real suspended load, mol/m^3 — well above fp
## noise, so it counts cells with a load in transit rather than cells with a rounding error.
const SUSP_ACTIVE: float = 0.001 * LAPhysical.ROCK_DENSITY_KG_M3 / LAPhysical.MOLAR_MASS_CASIO3_KG_MOL


var _f = null                    # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field
	LASimReport.register(report)


## The profile as SIM_REPORT keys: moles of loose mineral per radial band, the open cells each band holds,
## and the band's share of the whole surface pool. A row this world does not fold is absent, never 0.
func report() -> Dictionary:
	if _f == null or _f._queries == null:
		return {}
	var rows: Dictionary = _f._queries.reduced()
	var out: Dictionary = {}
	for key in ["mineral_loose_open", "mineral_loose_buried"]:
		if rows.has(key):
			out[key] = float(rows[key])
	for tag in RowsScript.BANDS:
		var sum_key: String = "mineral_band_%s_sum" % tag
		var n_key: String = "mineral_band_%s_n" % tag
		if rows.has(sum_key):
			out[sum_key] = float(rows[sum_key])
			if out.get("mineral_loose_open", 0.0) > 0.0:
				out["mineral_band_%s_frac" % tag] = float(rows[sum_key]) / float(out["mineral_loose_open"])
		if rows.has(n_key):
			out[n_key] = int(round(float(rows[n_key])))
	return out
