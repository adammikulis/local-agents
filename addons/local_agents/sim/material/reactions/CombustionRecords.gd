class_name LACombustionRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## ===== A SOLID FUEL HAS NO IGNITION POINT ===================================================================
## `cellulose.pyrolysis_ea_over_r_k` (230 kJ/mol over R; Antal & Varhegyi 1995, the mid of a measured
## 200-250 kJ/mol). So combustion is an ARRHENIUS record, and everything the old kernel spelled out falls

# --- THE RATE CONSTANT ---------------------------------------------------------------------------------------
const PYROLYSIS_REF_TEMP_K: float = 600.0

# writing down: an Arrhenius pair is correlated (the kinetic compensation effect), so a rate constant quoted
#     A = k(T_ref) * exp(Ea / (R T_ref)) = 2.5e-3 * exp(230000 / (8.3145 * 600)) = 2.6e17 per second
const PYROLYSIS_K_PER_S: float = 2.5e-3

# --- THE OXYGEN A FLAME NEEDS --------------------------------------------------------------------------------
const OXYGEN_QUENCH: float = LAPhysical.LIMITING_OXYGEN_CONCENTRATION_FRAC / LAPhysical.AIR_MOLE_FRAC_O2


## Per-step extent per unit of (fuel x oxygen) at the reference temperature. Derived from the substrate's own
## clock, so it tracks a changed day length instead of going stale — the pattern LAPhaseRecords._evap_k uses.
static func _rate_k() -> float:
	return PYROLYSIS_K_PER_S * LAMaterialFieldSphereStep3D.real_seconds_per_step()


static func _enthalpy_j_m3(o2_per_fuel: float) -> float:
	return o2_per_fuel * LAPhysical.AMBIENT_O2_DENSITY_KG_M3 * LAPhysical.HEAT_PER_KG_OXYGEN_J


## The records this domain contributes to the live table (see LAMaterialReactions3D).
static func records() -> Array:
	# reads as the mole-for-mole reaction it is. A unit of fuel is a cell full of dry wood (16652 mol/m3) and a
	# unit of o2 is the oxygen in a cell of ambient air (8.535 mol/m3), so `o2_per_fuel` comes out near 1951:
	var o2_per_fuel: float = LAReactionBalance.unit_ratio(O2, FUEL)
	var co2_per_fuel: float = LAReactionBalance.unit_ratio(CO2, FUEL)
	var w_per_fuel: float = LAReactionBalance.unit_ratio(MOISTURE, FUEL)
	var fert_per_fuel: float = LAReactionBalance.unit_ratio(FERT, FUEL)
	# Nitrogen per mole of CH2O, read off the composition table rather than restated, so this record cannot
	# disagree with the gate about what litter is made of. It is MOLAR: LITTER_C_TO_N is a ratio of MASSES, and
	# spending it directly as a mole count is a 16 % overstatement the old kernel had to be corrected for.
	var organic_n: float = float(LAReactionBalance.composition()[FUEL]["N"])
	return [
		rec(ARRHENIUS, _rate_k(), FUEL,
			[[FUEL, 1.0], [O2, o2_per_fuel]],
			[[CO2, co2_per_fuel, TGT_SELF],
				[MOISTURE, w_per_fuel, TGT_SELF],
				[FERT, organic_n * fert_per_fuel, TGT_SELF]],
			GATE_NOT_STATIC, LAPhysical.CELLULOSE_PYROLYSIS_EA_OVER_R_K, O2, PYROLYSIS_REF_TEMP_K,
			-1, 0.0, 0.0, _enthalpy_j_m3(o2_per_fuel), O2, OXYGEN_QUENCH),
	]
