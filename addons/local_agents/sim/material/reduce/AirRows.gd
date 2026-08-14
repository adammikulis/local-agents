class_name LAReduceAirRows
extends RefCounted

const Rec: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")

## Air: the gases a lung meets, the condensate a cloud is, and the mean flow.
static func rows() -> Array:
	# A cell over half full of liquid water has displaced its air, so it is not part of the open sky.
	var air: Dictionary = {"gate": "h2o", "gate_aux": "h2o_liquid", "gate_hi": LAMaterialField3D.MAX_MASS * 0.5}
	# Suspended condensate: the liquid and frozen shares of this cell's h2o, together.
	var cond: Dictionary = {"source": "h2o", "aux": "h2o_liquid", "aux2": "h2o_solid", "mask": Rec.Mask.OPEN}
	var warm: Dictionary = {"gate": "temp", "gate_lo": LAMaterialField3D.FOG_MAX_TEMP}
	var cool: Dictionary = {"gate": "temp", "gate_hi": LAMaterialField3D.FOG_MAX_TEMP}
	return [
		air.merged({"key": "o2_open_min", "source": "o2", "op": Rec.Op.MIN, "mask": Rec.Mask.OPEN}, true),
		air.merged({"key": "o2_open_sum", "source": "o2", "op": Rec.Op.SUM, "mask": Rec.Mask.OPEN}, true),
		air.merged({"key": "o2_open_cells", "source": "o2", "op": Rec.Op.COUNT, "mask": Rec.Mask.OPEN}, true),
		{"key": "co2_open_max", "source": "co2", "op": Rec.Op.MAX, "mask": Rec.Mask.OPEN},
		{"key": "co2_open_sum", "source": "co2", "op": Rec.Op.SUM, "mask": Rec.Mask.OPEN},
		cond.merged({"key": "precip_cells", "op": Rec.Op.COUNT_GT,
			"threshold": LAMaterialFieldAtmos3D.rain_threshold()}, true),
		cond.merged({"key": "cloud_cells", "op": Rec.Op.COUNT_GE,
			"threshold": LAMaterialField3D.CONDENSE_COVER_MIN}, true).merged(warm, true),
		cond.merged({"key": "fog_cells", "op": Rec.Op.COUNT_GE,
			"threshold": LAMaterialField3D.CONDENSE_COVER_MIN}, true).merged(cool, true),
		{"key": "wind_x_sum", "source": "vel_x", "op": Rec.Op.SUM, "mask": Rec.Mask.OPEN},
		{"key": "wind_z_sum", "source": "vel_z", "op": Rec.Op.SUM, "mask": Rec.Mask.OPEN},
		{"key": "shock_cells", "source": "shock", "op": Rec.Op.COUNT_GT, "mask": Rec.Mask.OPEN,
			"threshold": LAMaterialShock3D.SHOCK_ACTIVE},
		# The storm's electrics, read off what transport published rather than re-marched on the CPU.
		{"key": "charge_peak", "source": "charge", "op": Rec.Op.MAX, "mask": Rec.Mask.OPEN},
		{"key": "e_peak", "source": "col_e", "op": Rec.Op.MAX, "mask": Rec.Mask.OPEN},
		{"key": "bolt_cells", "source": "strike", "op": Rec.Op.COUNT_GT, "mask": Rec.Mask.OPEN,
			"threshold": 0.0},
	]
