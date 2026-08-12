class_name LACombustionRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## ===== A SOLID FUEL HAS NO IGNITION POINT ===================================================================
## `cellulose.pyrolysis_ea_over_r_k` (230 kJ/mol over R; Antal & Varhegyi 1995, the mid of a measured
## 200-250 kJ/mol). Combustion is an ARRHENIUS record.

# --- THE RATE CONSTANT ---------------------------------------------------------------------------------------
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
	var o2_per_fuel: float = LAReactionBalance.unit_ratio(O2, FUEL)
	var co2_per_fuel: float = LAReactionBalance.unit_ratio(CO2, FUEL)
	var w_per_fuel: float = LAReactionBalance.unit_ratio(MOISTURE, FUEL)
	var fert_per_fuel: float = LAReactionBalance.unit_ratio(FERT, FUEL)
	# Nitrogen per mole of CH2O, read off the composition table rather than restated, so this record cannot
	# disagree with the gate about what litter is made of. It is MOLAR; LITTER_C_TO_N is a ratio of MASSES.
	var organic_n: float = float(LAReactionBalance.composition()[FUEL]["N"])
	var dh: Vector3 = _enthalpy_parts()
	return [
		rec(ARRHENIUS, _rate_k(), FUEL,
			[[FUEL, 1.0], [ORG_H, 0.0, 1.0, 0.0], [ORG_O, 0.0, 0.0, 1.0],
				[O2, o2_per_fuel, 0.25 * o2_per_fuel, -0.5 * o2_per_fuel]],
			[[CO2, co2_per_fuel, TGT_SELF],
				[MOISTURE, 0.0, TGT_SELF, 0.5 * w_per_fuel, 0.0],
				[FERT, organic_n * fert_per_fuel, TGT_SELF]],
			0, LAPhysical.CELLULOSE_PYROLYSIS_EA_OVER_R_K, O2, PYROLYSIS_REF_TEMP_K,
			-1, 0.0, 0.0, dh.x, O2, OXYGEN_QUENCH, dh.y, dh.z),
	]
