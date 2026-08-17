class_name LAGeoRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"


# Urey, both ways: CaSiO3 + CO2 <-> CaCO3 + SiO2. Arrhenius, first order in the liquid h2o share.
const DISSOLUTION_K: float = 2.0e-5


static func _rate_k(ea_over_r_k: float) -> float:
	var t_ref: float = LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET
	return LAPhysical.VITRINITE_FREQUENCY_FACTOR_PER_S \
		* LAMaterialFieldSphereStep3D.real_seconds_per_step() * exp(-ea_over_r_k / t_ref)


## Heat per unit extent when the pool loses these moles of C, H and O. J/m3.
static func _coal_enthalpy_j_m3(mol_c: float, mol_h: float, mol_o: float) -> float:
	return LASubstances.organic_oxidation_parts().dot(Vector3(mol_c, mol_h, mol_o))


## Reaction records this domain contributes to the live table.
static func records() -> Array:
	var organic_n: float = float(LAReactionBalance.composition()[DETRITUS]["N"])
	return [
		rec(RM_ARRHENIUS, _rate_k(LAPhysical.COAL_DEHYDRATION_EA_OVER_R_K), ORG_O,
			[[ORG_H, 2.0], [ORG_O, 1.0]],
			[[H2O, 1.0, TGT_SELF]],
			GATE_BURIED, LAPhysical.COAL_DEHYDRATION_EA_OVER_R_K, -1,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, 0.0, _coal_enthalpy_j_m3(0.0, 2.0, 1.0)),

		rec(RM_ARRHENIUS, _rate_k(LAPhysical.COAL_DECARBOXYLATION_EA_OVER_R_K), DETRITUS,
			[[DETRITUS, 1.0], [ORG_O, 2.0]],
			[[CO2, 1.0, TGT_SELF], [FERT, organic_n, TGT_SELF]],
			GATE_BURIED, LAPhysical.COAL_DECARBOXYLATION_EA_OVER_R_K, -1,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, 0.0, _coal_enthalpy_j_m3(1.0, 0.0, 2.0)),

		# Reversible: direction is dG(T, p_CO2), not a threshold. CO2 is the one varying activity.
		LAReactionThermo.reversible(rec(RM_ARRHENIUS, DISSOLUTION_K, H2O_LIQUID,
			[[BEDROCK_BELOW, 1.0], [CO2, 1.0]],
			[[CARBONATE, 1.0, TGT_SELF],
				[SILICA, 1.0, TGT_SELF]],
			GATE_NEAR_GROUND, LAPhysical.SILICATE_DISSOLUTION_EA_OVER_R_K, CO2,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, LAPhysical.WATER_BOIL_C + LAPhysical.KELVIN_OFFSET), CO2),
	]
