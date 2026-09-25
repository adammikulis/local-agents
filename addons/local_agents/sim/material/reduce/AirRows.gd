class_name LAReduceAirRows
extends RefCounted

const Rec: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")

## Air: the gases a lung meets, the condensate a cloud is, and the mean flow.
static func rows() -> Array:
	# A cell over half full of liquid water has displaced its air, so it is not part of the open sky.
	var air: Dictionary = {"gate": "h2o", "gate_aux": "h2o_liquid", "gate_hi": LAMaterialField3D.MAX_MASS * 0.5}
	# Liquid and ice hanging in a cell's gas, which state_derive.glsl classes 1 over the surface layer and 2
	# above it. Water resting on rock or on more water is a body of water, not a cloud.
	var cond: Dictionary = {"source": "h2o", "aux": "h2o_liquid", "aux2": "h2o_solid", "mask": Rec.Mask.OPEN,
		"op": Rec.Op.COUNT_GE, "threshold": LAMaterialField3D.CONDENSE_COVER_MIN, "gate": "air_class"}
	return [
		air.merged({"key": "o2_open_min", "source": "o2", "op": Rec.Op.MIN, "mask": Rec.Mask.OPEN}, true),
		air.merged({"key": "o2_open_sum", "source": "o2", "op": Rec.Op.SUM, "mask": Rec.Mask.OPEN}, true),
		air.merged({"key": "o2_open_cells", "source": "o2", "op": Rec.Op.COUNT, "mask": Rec.Mask.OPEN}, true),
		{"key": "co2_open_max", "source": "co2", "op": Rec.Op.MAX, "mask": Rec.Mask.OPEN},
		{"key": "co2_open_sum", "source": "co2", "op": Rec.Op.SUM, "mask": Rec.Mask.OPEN},
		cond.merged({"key": "fog_cells", "gate_lo": 0.5, "gate_hi": 1.5}, true),
		cond.merged({"key": "cloud_cells", "gate_lo": 1.5, "gate_hi": 2.5}, true),
		# The peak, not the mean: a jet is local, and a mean over the box cannot say how fast the wind got.
		{"key": "wind_speed_max", "source": "speed", "op": Rec.Op.MAX, "mask": Rec.Mask.OPEN},
		# The storm's electrics, read off what transport published rather than re-marched on the CPU.
		{"key": "charge_peak", "source": "charge", "op": Rec.Op.MAX, "mask": Rec.Mask.OPEN},
		{"key": "e_peak", "source": "col_e", "op": Rec.Op.MAX, "mask": Rec.Mask.OPEN},
		{"key": "bolt_cells", "source": "strike", "op": Rec.Op.COUNT_GT, "mask": Rec.Mask.OPEN,
			"threshold": 0.0},
	]
