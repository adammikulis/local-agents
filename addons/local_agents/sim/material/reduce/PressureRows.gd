class_name LAReducePressureRows
extends RefCounted

const Rec: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")

## Pressure may not fall as you go DOWN. Each row is a cell-over-below pair class; rock over an open cell
## is in no class, because lithostatic stress and gas pressure are different quantities.

static func rows() -> Array:
	var inv: Dictionary = {"source": "pressure", "op": Rec.Op.COUNT_GT, "threshold": 0.0, "nbr": Rec.Nbr.BELOW}
	var aud: Dictionary = inv.merged({"op": Rec.Op.COUNT, "gate": "pressure", "gate_lo": 0.0, "gate_strict_lo": true}, true)
	var wet: Dictionary = {"gate": "h2o", "gate_aux": "h2o_liquid", "mask": Rec.Mask.AIR}
	return [
		inv.merged({"key": "pressure_inv_rock", "mask": Rec.Mask.BEDDED}, true),
		inv.merged({"key": "pressure_inv_surface", "mask": Rec.Mask.GROUND}, true),
		inv.merged(wet, true).merged({"key": "pressure_inv_wet", "gate_lo": LAMaterialField3D.MIN_MASS}, true),
		inv.merged(wet, true).merged({"key": "pressure_inv_dry", "gate_hi": LAMaterialField3D.MIN_MASS}, true),
		aud.merged({"key": "pressure_aud_rock", "mask": Rec.Mask.BEDDED}, true),
		aud.merged({"key": "pressure_aud_surface", "mask": Rec.Mask.GROUND}, true),
		aud.merged({"key": "pressure_aud_open", "mask": Rec.Mask.AIR}, true),
	]
