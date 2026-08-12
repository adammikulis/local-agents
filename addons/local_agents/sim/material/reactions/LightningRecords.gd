class_name LALightningRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## Lightning nitrogen fixation — the planet's only abiotic route from atmospheric N2 to plant-available N.
##
## The chemistry is sub-grid. NO forms in a channel a centimetre across at ~30000 K and freezes out as the
## channel cools; on an anoxic CO2 atmosphere the oxygen comes from CO2 (N2 + 2 CO2 -> 2 NO + 2 CO), on an
## oxic one from O2 (Zel'dovich). A cell here is a kilometre and holds one temperature, so an Arrhenius law
## on the cell mean cannot represent it — evaluated at 300 K with the Zel'dovich Ea/R of 38370 K it returns
## exactly zero. The measurable closure is the published YIELD PER UNIT OF DISCHARGE ENERGY, which is what
## this record uses, driven by the charge the return stroke actually drained from the cell.
##
## `fixed_n` is declared as the bare element N (LASubstances), so the record that balances is N2 -> 2 N.
## The oxygen that ends up in nitrate is not in the books on either side, which is the substance table's
## own stated model of soil nitrogen, not a licence taken here. Nothing is created or destroyed.


## Moles of N fixed per unit of charge drained. J_PER_CHARGE is LIGHTNING_FLASH_J / BREAKDOWN, so a full
## breakdown IS one flash by the charge module's own definition and the flash energy cancels:
##     mol N per charge unit = LIGHTNING_N_FIXED_MOL_PER_FLASH / BREAKDOWN
static func _mol_n_per_charge() -> float:
	var breakdown: float = maxf(LAMaterialCharge3D.BREAKDOWN, 1.0e-6)
	return LAPhysical.LIGHTNING_N_FIXED_MOL_PER_FLASH / breakdown


## Cell volume in cubic metres. The driver is an absolute per-cell quantity and a rate model works in
## concentration, so this is the one conversion between them.
static func _cell_volume_m3() -> float:
	var h: float = maxf(cell_size_m, 0.001)
	return h * h * h


## x = LIGHTNING_FIX_RATE * discharge, in N2 channel units.
##     LIGHTNING_FIX_RATE = (mol N per charge unit) / (2 * mol_per_unit(N2) * cell volume)
static func _fix_k() -> float:
	var mpu_n2: float = float(LAReactionBalance.mol_per_unit().get(N2, 0.0))
	var vol: float = _cell_volume_m3()
	if mpu_n2 <= 0.0 or vol <= 0.0:
		return 0.0
	return _mol_n_per_charge() / (2.0 * mpu_n2 * vol)


static func records() -> Array:
	# 2 N per N2, converted from N2 channel units into FERT channel units.
	var fert_per_n2: float = 2.0 * LAReactionBalance.unit_ratio(FERT, N2)
	return [
		# TGT_SCRATCH, not TGT_SELF: the strike happens aloft and nitrate reaches the ground in precipitation.
		# The scratch buffer is the substrate's existing column-deposit path — fungus_fert_sphere3d.glsl sums
		# each radial line and credits the ground-hugging open cell, which is where a root is.
		rec(CONST_FRAC, _fix_k(), DISCHARGE,
			[[N2, 1.0]],
			[[FERT, fert_per_n2, TGT_SCRATCH]]),
	]
