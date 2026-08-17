class_name LACombustionRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

const PYROLYSIS_REF_TEMP_K: float = 600.0
const PYROLYSIS_K_PER_S: float = 2.5e-3    # k(T_ref), per second
const OXYGEN_QUENCH: float = LAPhysical.LIMITING_OXYGEN_CONCENTRATION_FRAC / LAPhysical.AIR_MOLE_FRAC_O2


## Per-step extent per unit of (fuel x oxygen) at PYROLYSIS_REF_TEMP_K.
static func _rate_k() -> float:
	return PYROLYSIS_K_PER_S * LAMaterialFieldSphereStep3D.real_seconds_per_step()


## Reaction records this domain contributes to the live table.
static func records() -> Array:
	# CH_yO_z + (1 + y/4 - z/2) O2 -> CO2 + (y/2) H2O, per unit of FUEL.
	var organic_n: float = float(LAReactionBalance.composition()[FUEL]["N"])
	var dh: Vector3 = LASubstances.organic_oxidation_parts()
	return [
		rec(RM_ARRHENIUS, _rate_k(), FUEL,
			[[FUEL, 1.0], [ORG_H, 0.0, 1.0, 0.0], [ORG_O, 0.0, 0.0, 1.0],
				[O2, 1.0, 0.25, -0.5]],
			[[CO2, 1.0, TGT_SELF],
				[H2O, 0.0, TGT_SELF, 0.5 * 1.0, 0.0],
				[FERT, organic_n, TGT_SELF]],
			0, LAPhysical.CELLULOSE_PYROLYSIS_EA_OVER_R_K, O2, PYROLYSIS_REF_TEMP_K,
			-1, 0.0, 0.0, dh.x, O2, OXYGEN_QUENCH, dh.y, dh.z),
	]
