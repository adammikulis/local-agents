class_name LAReduceMineralRows
extends RefCounted

const Rec: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")

## Melt is mask-free: it lingers the instant a cell crosses to derived-solid, so an open-only sum would
## drop matter that physically exists. Melt confined by rock is magma; melt in the open is lava.
static func rows() -> Array:
	var drained: Dictionary = {"gate": "silicate", "gate_aux": "silicate_melt",
		"gate_hi": LAMaterialFieldQueries3D.TUBE_MELT_NEAR_ZERO}
	var melt: Dictionary = {"source": "silicate", "aux": "silicate_melt", "mask": Rec.Mask.OPEN}
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
		melt.merged({"key": "lava_hot", "op": Rec.Op.COUNT_GE, "threshold": 0.001}, true),
		melt.merged({"key": "lava_thick", "op": Rec.Op.COUNT_GE, "threshold": 0.5}, true),
		melt.merged({"key": "lava_maxmass", "op": Rec.Op.MAX}, true),
		# An open cell walled in by rock and no longer melt-filled — a drained lava tube.
		drained.merged({"key": "enclosed_void4", "source": "solid", "op": Rec.Op.COUNT_GE,
			"mask": Rec.Mask.OPEN, "threshold": 4.0, "nbr": Rec.Nbr.SOLID_COUNT}, true),
		drained.merged({"key": "enclosed_void5", "source": "solid", "op": Rec.Op.COUNT_GE,
			"mask": Rec.Mask.OPEN, "threshold": 5.0, "nbr": Rec.Nbr.SOLID_COUNT}, true),
	]
