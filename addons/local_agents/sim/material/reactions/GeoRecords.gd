class_name LAGeoRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"


const LOFT_WIND: float = 6.0             # m/s wind threshold for lofting sand
const LOFT_RATE: float = 0.003           # sediment lofted per step per m/s over the threshold
const SUSP_SETTLE_RATE: float = 0.05     # per-step fraction of suspended sediment that settles
const DISSOLUTION_K: float = 2.0e-5      # Arrhenius pre-factor, per step
const LITH_RATE_PER_PA: float = 1.0e-9   # per-step k on x = max(0, P - P_lith) * k


## Per-step Arrhenius rate at the lab reference temperature.
static func _rate_k(ea_over_r_k: float) -> float:
	var t_ref: float = LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET
	return LAPhysical.VITRINITE_FREQUENCY_FACTOR_PER_S \
		* LAMaterialFieldSphereStep3D.real_seconds_per_step() * exp(-ea_over_r_k / t_ref)


## Heat released per unit extent per m3 when the pool loses these moles of C, H and O. J/m3.
static func _coal_enthalpy_j_m3(mol_c: float, mol_h: float, mol_o: float) -> float:
	return LASubstances.ORGANIC_MOL_PER_M3 * (mol_c * LASubstances.organic_energy_j_mol("C")
		+ mol_h * LASubstances.organic_energy_j_mol("H")
		+ mol_o * LASubstances.organic_energy_j_mol("O"))


## Reaction records this domain contributes to the live table.
static func records() -> Array:
	var organic_n: float = float(LAReactionBalance.composition()[DETRITUS]["N"])
	return [
		# Dehydration: 2 H + O leave as water.
		rec(RM_ARRHENIUS, _rate_k(LAPhysical.COAL_DEHYDRATION_EA_OVER_R_K), ORG_O,
			[[ORG_H, 2.0], [ORG_O, 1.0]],
			[[H2O, 1.0, TGT_SELF]],
			GATE_BURIED, LAPhysical.COAL_DEHYDRATION_EA_OVER_R_K, -1,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, 0.0, _coal_enthalpy_j_m3(0.0, 2.0, 1.0)),

		# Decarboxylation: C + 2 O leave as CO2, with the backbone's nitrogen.
		rec(RM_ARRHENIUS, _rate_k(LAPhysical.COAL_DECARBOXYLATION_EA_OVER_R_K), DETRITUS,
			[[DETRITUS, 1.0], [ORG_O, 2.0]],
			[[CO2, 1.0, TGT_SELF], [FERT, organic_n, TGT_SELF]],
			GATE_BURIED, LAPhysical.COAL_DECARBOXYLATION_EA_OVER_R_K, -1,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, 0.0, _coal_enthalpy_j_m3(1.0, 0.0, 2.0)),

		rec(RM_EXCESS_OVER_THRESHOLD, LOFT_RATE, WINDSPEED, [[SEDIMENT, 1.0]], [[DUST, 1.0, TGT_SELF]],
			GATE_DRY, LOFT_WIND),

		rec(RM_CONST_FRAC, SUSP_SETTLE_RATE, SUSP, [[SUSP, 1.0]], [[SEDIMENT, 1.0, TGT_SELF]], 0),

		# Urey, reversible: CaSiO3 + CO2 <-> CaCO3 + SiO2, direction set by dG(T, p_CO2).
		LAReactionThermo.reversible(rec(RM_ARRHENIUS, DISSOLUTION_K, H2O_LIQUID,
			[[BEDROCK_BELOW, 1.0], [CO2, 1.0]],
			[[CARBONATE, 1.0, TGT_SELF],
				[SILICA, 1.0, TGT_SELF]],
			GATE_NEAR_GROUND, LAPhysical.SILICATE_DISSOLUTION_EA_OVER_R_K, CO2,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, LAPhysical.WATER_BOIL_C + LAPhysical.KELVIN_OFFSET), CO2),

		rec(RM_EXCESS_OVER_THRESHOLD, LITH_RATE_PER_PA, OVERBURDEN, [[SEDIMENT, 1.0]],
			[[ROCK_FILL, 1.0, TGT_SELF]], 0, LAPhysical.LITHIFICATION_PRESSURE_PA),
	]
