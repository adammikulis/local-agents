class_name LAReduceWaterRows
extends RefCounted

const Rec: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")

## LIQUID h2o: the one water channel times the share the enthalpy ladder leaves liquid at this cell.
static func rows() -> Array:
	var wet_min: float = 0.01           # volume fraction of a cell below which it is not holding water
	var wet: Dictionary = {"gate": "h2o", "gate_aux": "h2o_liquid", "gate_lo": wet_min}
	return [
		{"key": "water_liquid_total", "source": "h2o", "aux": "h2o_liquid", "op": Rec.Op.SUM,
			"mask": Rec.Mask.ALL, "weight": true},
		{"key": "wet_cells", "source": "h2o", "aux": "h2o_liquid", "op": Rec.Op.COUNT_GE,
			"mask": Rec.Mask.OPEN, "threshold": LAMaterialField3D.RENDER_MIN},
		# Airborne h2o over every cell, in moles, mask-free.
		{"key": "vapour_amount", "source": "h2o", "aux": "h2o_vapour", "op": Rec.Op.SUM,
			"mask": Rec.Mask.ALL, "weight": true},
		# Surface water hot enough to be a spring, and the peak it reaches. Gated on holding water at all,
		# so the peak is the hottest WATER rather than the hottest cell.
		{"key": "hotspring_wet", "source": "h2o", "aux": "h2o_liquid", "op": Rec.Op.COUNT_GE,
			"mask": Rec.Mask.OPEN, "threshold": wet_min},
		wet.merged({"key": "hotspring_max_c", "source": "temp", "op": Rec.Op.MAX,
			"mask": Rec.Mask.OPEN}, true),
		wet.merged({"key": "hotspring_mild", "source": "temp", "op": Rec.Op.COUNT_GT,
			"mask": Rec.Mask.OPEN, "threshold": 30.0}, true),
		wet.merged({"key": "hotspring_cells", "source": "temp", "op": Rec.Op.COUNT_GT,
			"mask": Rec.Mask.OPEN, "threshold": 60.0}, true),
		wet.merged({"key": "hotspring_boiling", "source": "temp", "op": Rec.Op.COUNT_GE,
			"mask": Rec.Mask.OPEN, "threshold": LAPhysical.WATER_BOIL_C}, true),
	]
