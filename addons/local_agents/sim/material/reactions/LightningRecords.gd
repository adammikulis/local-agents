class_name LALightningRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## Rate coefficient on the DISCHARGE driver (J/m^3), mol N2 per joule. The driver already carries this
## step's energy, so k has no timebase of its own.
static func _fix_k() -> float:
	return LAPhysical.LIGHTNING_N_FIXED_MOL_PER_J / 2.0


static func records() -> Array:
	# The stroke's heat splits N2 and O2 and the nitrogen leaves as monoxide, absorbing the bond energy.
	return [
		LAReactionThermo.priced(rec(TB_PER_STEP, "mol m^-3 driver^-1 step^-1", RM_CONST_FRAC, _fix_k(),
			DISCHARGE,
			[[N2, 1.0], [O2, 1.0]],
			[[FERT, 2.0]])),
	]
