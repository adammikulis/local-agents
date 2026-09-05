class_name LACombustionRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

const PYROLYSIS_REF_TEMP_K: float = 600.0
## k(T_ref), per second: the cited Arrhenius pair evaluated at the reference temperature. Antal, Varhegyi
## & Jakab measured cellulose pyrolysis under inert gas, so the law is FIRST ORDER in the fuel alone.
const PYROLYSIS_K_PER_S: float = LAPhysical.CELLULOSE_PYROLYSIS_A_PER_S * exp(-LAPhysical.CELLULOSE_PYROLYSIS_EA_OVER_R_K / PYROLYSIS_REF_TEMP_K)


## Reaction records this domain contributes to the live table.
static func records() -> Array:
	# CH_yO_z + (1 + y/4 - z/2 + n/2) O2 -> CO2 + (y/2) H2O + n NO, per mole of FUEL carbon. One-way:
	# combustion's reverse does not occur below thousands of kelvin. Oxygen enters as the quench species,
	# where it acts: the flame goes out below the limiting oxygen concentration, it is not a rate order.
	var organic_n: float = float(LAReactionBalance.composition()[FUEL]["N"])
	return [
		LAReactionThermo.priced(rec(TB_PER_SECOND, "mol m^-3 driver^-1 s^-1", RM_ARRHENIUS,
			PYROLYSIS_K_PER_S, FUEL,
			[[FUEL, 1.0], [ORG_H, 0.0, 1.0, 0.0], [ORG_O, 0.0, 0.0, 1.0],
				[O2, 1.0 + 0.5 * organic_n, 0.25, -0.5]],
			[[CO2, 1.0],
				[H2O, 0.0, 0.5, 0.0],
				[FERT, organic_n]],
			0, LAPhysical.CELLULOSE_PYROLYSIS_EA_OVER_R_K, -1, PYROLYSIS_REF_TEMP_K,
			-1, 0.0, 0.0, 0.0, O2, LAPhysical.LIMITING_OXYGEN_CONCENTRATION_FRAC)),
	]
