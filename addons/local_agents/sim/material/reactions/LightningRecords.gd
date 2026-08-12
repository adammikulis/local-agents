class_name LALightningRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## Rate coefficient on the DISCHARGE driver (J/m^3), in N2 channel units.
static func _fix_k() -> float:
	return LAPhysical.LIGHTNING_N_FIXED_MOL_PER_J / 2.0


static func records() -> Array:
	var fert_per_n2: float = 2.0
	return [
		rec(RM_CONST_FRAC, _fix_k(), DISCHARGE,
			[[N2, 1.0]],
			[[FERT, fert_per_n2, TGT_SCRATCH]]),
	]
