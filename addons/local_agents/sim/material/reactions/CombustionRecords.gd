class_name LACombustionRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## A solid fuel has no ignition point: `cellulose.pyrolysis_ea_over_r_k` is 230 kJ/mol over R (Antal &
## Varhegyi 1995, the mid of a measured 200-250 kJ/mol), and combustion is an RM_ARRHENIUS record.

const PYROLYSIS_REF_TEMP_K: float = 600.0

# writing down: an Arrhenius pair is correlated (the kinetic compensation effect), so a rate constant quoted
#     A = k(T_ref) * exp(Ea / (R T_ref)) = 2.5e-3 * exp(230000 / (8.3145 * 600)) = 2.6e17 per second
const PYROLYSIS_K_PER_S: float = 2.5e-3

# --- THE OXYGEN A FLAME NEEDS --------------------------------------------------------------------------------
const OXYGEN_QUENCH: float = LAPhysical.LIMITING_OXYGEN_CONCENTRATION_FRAC / LAPhysical.AIR_MOLE_FRAC_O2


## Per-step extent per unit of (fuel x oxygen) at the reference temperature. Scales with the step quantum.
static func _rate_k() -> float:
	return PYROLYSIS_K_PER_S * LAMaterialFieldSphereStep3D.real_seconds_per_step()


## Heat released per unit of extent, per m3 of cell — the composition dotted with Channiwala & Parikh's
## per-element heating values. `enthalpy_j_m3` is the constant part, the other two scale with H:C and O:C.
## One expression covers fresh litter through anthracite; no fuel carries its own heat of combustion.
static func _enthalpy_parts() -> Vector3:
	var n: float = LASubstances.ORGANIC_MOL_PER_M3
	return Vector3(n * LASubstances.organic_energy_j_mol("C"),
		n * LASubstances.organic_energy_j_mol("H"),
		n * LASubstances.organic_energy_j_mol("O"))


## The records this domain contributes to the live table (see LAMaterialReactions3D).
static func records() -> Array:
	# Per unit of FUEL, which is LASubstances.ORGANIC_MOL_PER_M3 moles of the dead pool's CARBON. Everything
	# else is the cell's own composition: CH_yO_z + (1 + y/4 - z/2) O2 -> CO2 + (y/2) H2O.
	var organic_n: float = float(LAReactionBalance.composition()[FUEL]["N"])
	var dh: Vector3 = _enthalpy_parts()
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
