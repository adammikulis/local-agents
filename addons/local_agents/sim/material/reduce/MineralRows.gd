class_name LAReduceMineralRows
extends RefCounted

const Rec: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")
const Heat: GDScript = preload("res://addons/local_agents/sim/material/reduce/HeatRows.gd")

## Loose (uncemented) mineral: the bed load plus what water carries in suspension. flux.glsl's grain
## prologue writes both fractions.
const LOOSE: Dictionary = {"source": "silicate", "aux": "silicate_bed",
	"aux2": "silicate_susp_water", "mask": Rec.Mask.OPEN}

## The radial bands the loose pool is sampled over, on the geotherm profile's own grid.
const BANDS: PackedStringArray = ["core", "mid", "surf"]

## Melt is mask-free: it lingers the instant a cell crosses to derived-solid, so an open-only sum would
## drop matter that physically exists. Melt confined by rock is magma; melt in the open is lava.
static func rows() -> Array:
	var drained: Dictionary = {"gate": "silicate", "gate_aux": "silicate_melt",
		"gate_hi": LAMaterialFieldQueries3D.TUBE_MELT_NEAR_ZERO}
	var melt: Dictionary = {"source": "silicate", "aux": "silicate_melt", "mask": Rec.Mask.OPEN}
	var rind: Dictionary = {"source": "temp", "gate": "melt_body", "gate_lo": 0.5, "gate_hi": 1.5}
	var interior: Dictionary = {"source": "temp", "gate": "melt_body", "gate_lo": 1.5}
	return [
		{"key": "melt_total", "source": "silicate", "aux": "silicate_melt", "op": Rec.Op.SUM,
			"mask": Rec.Mask.ALL, "weight": true},
		{"key": "magma_cells", "source": "silicate", "aux": "silicate_melt", "op": Rec.Op.COUNT_GE,
			"mask": Rec.Mask.SOLID, "threshold": LAMaterialFieldQueries3D.MOLTEN_MIN},
		{"key": "lava_cells", "source": "silicate", "aux": "silicate_melt", "op": Rec.Op.COUNT_GE,
			"mask": Rec.Mask.OPEN, "threshold": LAMaterialFieldQueries3D.MOLTEN_MIN},
		# Wind-borne mineral, per cell, unweighted: its consumer is a mean over cells, not an amount.
		{"key": "airborne_mineral_sum", "source": "silicate", "aux": "silicate_susp_air", "op": Rec.Op.SUM,
			"mask": Rec.Mask.ALL},
		# Open cells carrying a real suspended load; then a melt body, one over half full, and its peak.
		{"key": "suspended_cells", "source": "silicate", "aux": "silicate_susp_water", "mask": Rec.Mask.OPEN,
			"op": Rec.Op.COUNT_GT, "threshold": LAMaterialFieldMineralProfile3D.SUSP_ACTIVE},
		melt.merged({"key": "lava_hot", "op": Rec.Op.COUNT_GE,
			"threshold": 0.001 * LASubstances.full_mol_m3("silicate")}, true),
		melt.merged({"key": "lava_thick", "op": Rec.Op.COUNT_GE,
			"threshold": 0.5 * LASubstances.full_mol_m3("silicate")}, true),
		melt.merged({"key": "lava_maxmass", "op": Rec.Op.MAX}, true),
		# An open cell walled in by rock and no longer melt-filled — a drained lava tube.
		drained.merged({"key": "enclosed_void4", "source": "solid", "op": Rec.Op.COUNT_GE,
			"mask": Rec.Mask.OPEN, "threshold": 4.0, "nbr": Rec.Nbr.SOLID_COUNT}, true),
		drained.merged({"key": "enclosed_void5", "source": "solid", "op": Rec.Op.COUNT_GE,
			"mask": Rec.Mask.OPEN, "threshold": 5.0, "nbr": Rec.Nbr.SOLID_COUNT}, true),
		# THE MELT BODY'S SKIN: state_derive.glsl classes an open melt cell 1 where a neighbour is
		# neither rock nor more of the same melt, and 2 where none is.
		rind.merged({"key": "lava_rind", "op": Rec.Op.COUNT}, true),
		rind.merged({"key": "lava_rind_sum", "op": Rec.Op.SUM}, true),
		interior.merged({"key": "lava_interior", "op": Rec.Op.COUNT}, true),
		interior.merged({"key": "lava_interior_sum", "op": Rec.Op.SUM}, true),
	] + _band_rows()


## WHERE the loose mineral is, by radius: moles per band and the open cells the band holds, over the same
## `r_frac` grid LAReduceHeatRows samples the geotherm on.
static func _band_rows() -> Array:
	var out: Array = []
	for tag in BANDS:
		var b: int = int(Heat.PROFILE_SAMPLES[String(tag)])
		var g: Dictionary = LOOSE.merged({"gate": "r_frac",
			"gate_lo": float(b) * Heat.PROFILE_WIDTH}, true)
		if float(b + 1) * Heat.PROFILE_WIDTH < 1.0:
			g["gate_hi"] = float(b + 1) * Heat.PROFILE_WIDTH
		out.append(g.merged({"key": "mineral_band_%s_sum" % tag, "op": Rec.Op.SUM,
			"weight": true}, true))
		out.append(g.merged({"key": "mineral_band_%s_n" % tag, "op": Rec.Op.COUNT}, true))
	# The two pools a band is read against: loose in the open, where wind and water reach it, and loose
	# inside rock, where nothing does.
	out.append(LOOSE.merged({"key": "mineral_loose_open", "op": Rec.Op.SUM, "weight": true}, true))
	out.append(LOOSE.merged({"key": "mineral_loose_buried", "op": Rec.Op.SUM, "weight": true,
		"mask": Rec.Mask.SOLID}, true))
	return out
