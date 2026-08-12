class_name LALightningRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## Lightning nitrogen fixation — the planet's only abiotic route from atmospheric N2 to plant-available N.


## x = LIGHTNING_FIX_RATE * discharge, in N2 channel units. The DISCHARGE driver is J/m^3, so no cell
## volume enters: (mol N / J) * (J / m^3) / (2 * mol N2 per unit per m^3) is already a channel amount.
static func _fix_k() -> float:
	return LAPhysical.LIGHTNING_N_FIXED_MOL_PER_J / 2.0


static func records() -> Array:
	# 2 N per N2, converted from N2 channel units into FERT channel units.
	var fert_per_n2: float = 2.0
	return [
		# TGT_SCRATCH, not TGT_SELF: the strike happens aloft and nitrate reaches the ground in precipitation.
		# The scratch buffer is the substrate's existing column-deposit path — fungus_fert_sphere3d.glsl sums
		# each radial line and credits the ground-hugging open cell, which is where a root is.
		rec(CONST_FRAC, _fix_k(), DISCHARGE,
			[[N2, 1.0]],
			[[FERT, fert_per_n2, TGT_SCRATCH]]),
	]
