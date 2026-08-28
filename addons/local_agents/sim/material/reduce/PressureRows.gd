class_name LAReducePressureRows
extends RefCounted

const Rec: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")

## Pressure may not fall as you go DOWN, over the cells that hold matter (rho_bulk > 0), at BOTH ends. Rock over an open cell
## is in no class — lithostatic stress and gas pressure differ.
static func rows() -> Array:
	var held: Dictionary = {"gate": "rho_bulk", "gate_lo": 0.0, "gate_strict_lo": true}
	var pair: Dictionary = held.merged({"source": "pressure", "nbr": Rec.Nbr.BELOW,
		"gate_both_ends": true}, true)
	var out: Array = []
	for cls in [["rock", Rec.Mask.BEDDED], ["surface", Rec.Mask.GROUND], ["open", Rec.Mask.AIR]]:
		var name: String = String(cls[0])
		var base: Dictionary = pair.merged({"mask": cls[1]}, true)
		out.append(base.merged({"key": "pressure_inv_" + name, "op": Rec.Op.COUNT_GT,
			"threshold": 0.0}, true))
		out.append(base.merged({"key": "pressure_aud_" + name, "op": Rec.Op.COUNT}, true))
		# How big, in pascals: a count cannot tell a float-noise sign flip from a real inversion.
		out.append(base.merged({"key": "pressure_worst_" + name, "op": Rec.Op.MAX}, true))
		# Every vertical pair of this class. Against `aud` it says how many hold no matter.
		out.append({"key": "pressure_pairs_" + name, "op": Rec.Op.COUNT, "mask": cls[1],
			"source": "pressure", "nbr": Rec.Nbr.BELOW})
	# The WORST open cell's relative departure from its seeded pressure, over the same held cells.
	var rest: Dictionary = held.merged({"source": "pressure", "ref": "pressure_ref",
		"mask": Rec.Mask.OPEN}, true)
	out.append(rest.merged({"key": "pressure_seed_latch", "op": Rec.Op.LATCH}, true))
	out.append(rest.merged({"key": "pressure_rest_rel", "op": Rec.Op.MAX_REL_DIFF}, true))
	return out
