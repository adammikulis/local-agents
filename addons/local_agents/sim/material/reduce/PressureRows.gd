class_name LAReducePressureRows
extends RefCounted

const Rec: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")

## Pressure may not fall as you go DOWN. Each pair class carries its own inv, aud and worst rows over the
## SAME cells; `gate_both_ends` demands a reading at both ends, so gas over vacuum is a boundary, not an
## inversion. Rock over an open cell is in no class: lithostatic stress and gas pressure differ.
static func rows() -> Array:
	var pair: Dictionary = {"source": "pressure", "nbr": Rec.Nbr.BELOW, "gate": "pressure",
		"gate_lo": 0.0, "gate_strict_lo": true, "gate_both_ends": true}
	var out: Array = []
	for cls in [["rock", Rec.Mask.BEDDED], ["surface", Rec.Mask.GROUND], ["open", Rec.Mask.AIR]]:
		var name: String = String(cls[0])
		var base: Dictionary = pair.merged({"mask": cls[1]}, true)
		out.append(base.merged({"key": "pressure_inv_" + name, "op": Rec.Op.COUNT_GT,
			"threshold": 0.0}, true))
		out.append(base.merged({"key": "pressure_aud_" + name, "op": Rec.Op.COUNT}, true))
		# How big, in pascals: a count cannot tell a float-noise sign flip from a real inversion.
		out.append(base.merged({"key": "pressure_worst_" + name, "op": Rec.Op.MAX}, true))
	return out
