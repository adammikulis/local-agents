class_name LAReducePressureRows
extends RefCounted

const Rec: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")
const TransportPassScript: GDScript = preload("res://addons/local_agents/sim/material/sphere_passes/TransportPass.gd")

## Pressure may not fall as you go DOWN. Each pair class carries its own inv, aud and worst rows over the
## SAME cells. Rock over an open cell is in no class: lithostatic stress and gas pressure differ.
##
## THE POPULATION IS THE DERIVE'S OWN. `state_derive.glsl` gives a cell under `rho_floor` no bulk state at
## all — no temperature, and an open cell no pressure — so a pair with an empty end compares a reading
## with a quantity the model does not define. `gate_both_ends` on the SAME structural test transport.glsl
## states in `no_matter()`, `rho_bulk >= rho_floor`, is what keeps the two populations one.
static func rows() -> Array:
	var held: Dictionary = {"gate": "rho_bulk", "gate_lo": TransportPassScript.EMPTY_RHO_KG_M3}
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
		# EVERY vertical pair of this class, floor or no floor. Against `aud` it says how many the
		# emptiness floor kept out, so an audit that examined nothing cannot read as a pass.
		out.append({"key": "pressure_pairs_" + name, "op": Rec.Op.COUNT, "mask": cls[1],
			"source": "pressure", "nbr": Rec.Nbr.BELOW})
	# The WORST open cell's relative departure from its seeded pressure, over the same held cells.
	var rest: Dictionary = held.merged({"source": "pressure", "ref": "pressure_ref",
		"mask": Rec.Mask.OPEN}, true)
	out.append(rest.merged({"key": "pressure_seed_latch", "op": Rec.Op.LATCH}, true))
	out.append(rest.merged({"key": "pressure_rest_rel", "op": Rec.Op.MAX_REL_DIFF}, true))
	return out
