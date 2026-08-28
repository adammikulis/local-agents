class_name LACombustionRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

const PYROLYSIS_REF_TEMP_K: float = 600.0
## k(T_ref) in air, per second: the cited Arrhenius pair evaluated at the reference temperature.
const PYROLYSIS_K_PER_S: float = LAPhysical.CELLULOSE_PYROLYSIS_A_PER_S * exp(-LAPhysical.CELLULOSE_PYROLYSIS_EA_OVER_R_K / PYROLYSIS_REF_TEMP_K)

## Ambient O2, mol/m3 — the concentration PYROLYSIS_K_PER_S is quoted at.
const O2_AMBIENT_MOL_M3: float = LAPhysical.AIR_MOLAR_DENSITY_MOL_M3 * LAPhysical.AIR_MOLE_FRAC_O2


## mol C m^-3 s^-1 per (fuel mol/m3 x O2 mol/m3) at PYROLYSIS_REF_TEMP_K.
static func _rate_k_per_s() -> float:
	return PYROLYSIS_K_PER_S / O2_AMBIENT_MOL_M3


## Reaction records this domain contributes to the live table.
static func records() -> Array:
	# CH_yO_z + (1 + y/4 - z/2) O2 -> CO2 + (y/2) H2O, per mole of FUEL carbon. One-way: FERT (fixed_n)
	# has no standard-state data, and combustion's reverse does not occur below thousands of kelvin.
	var organic_n: float = float(LAReactionBalance.composition()[FUEL]["N"])
	var dh: Vector3 = LASubstances.organic_oxidation_parts()
	return [
		rec(TB_PER_SECOND, "mol m^-3 driver^-1 driver2^-1 s^-1", RM_ARRHENIUS, _rate_k_per_s(), FUEL,
			[[FUEL, 1.0], [ORG_H, 0.0, 1.0, 0.0], [ORG_O, 0.0, 0.0, 1.0],
				[O2, 1.0, 0.25, -0.5]],
			[[CO2, 1.0],
				[H2O, 0.0, 0.5 * 1.0, 0.0],
				[FERT, organic_n]],
			0, LAPhysical.CELLULOSE_PYROLYSIS_EA_OVER_R_K, O2, PYROLYSIS_REF_TEMP_K,
			-1, 0.0, 0.0, dh.x, O2, LAPhysical.LIMITING_OXYGEN_CONCENTRATION_FRAC, dh.y, dh.z),
	]
