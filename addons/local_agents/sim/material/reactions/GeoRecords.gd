class_name LAGeoRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"


# --- D1b THE UREY REACTION, BOTH WAYS: CaSiO3 + CO2 <-> CaCO3 + SiO2 --------------------------------------
# THE RATE LAW is Arrhenius, first order in the solvent (the LIQUID share of h2o) and first order
const DISSOLUTION_K: float = 2.0e-5


# --- COALIFICATION: BURIAL DRIVES ORGANIC MATTER TOWARD CARBON ---------------------------------------------
# Peat, lignite, coal and oil are not fuels this substrate has to name. They are one dead organic pool losing
static func _rate_k(ea_over_r_k: float) -> float:
	var t_ref: float = LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET
	return LAPhysical.VITRINITE_FREQUENCY_FACTOR_PER_S \
		* LAMaterialFieldSphereStep3D.real_seconds_per_step() * exp(-ea_over_r_k / t_ref)


## Heat released per unit of extent, per m3 of cell, when the pool loses these moles of each element: the
## chemical energy it no longer holds (LASubstances.organic_energy_j_mol) has to go somewhere, and it goes to
## the cell. Coalification comes out exothermic, which is why coal seams self-heat.
static func _coal_enthalpy_j_m3(mol_c: float, mol_h: float, mol_o: float) -> float:
	return LASubstances.ORGANIC_MOL_PER_M3 * (mol_c * LASubstances.organic_energy_j_mol("C")
		+ mol_h * LASubstances.organic_energy_j_mol("H")
		+ mol_o * LASubstances.organic_energy_j_mol("O"))


## The records this domain contributes to the live table (see LAMaterialReactions3D).
static func records() -> Array:
	var organic_n: float = float(LAReactionBalance.composition()[DETRITUS]["N"])
	return [
		# DEHYDRATION, the lowest-activation-energy leg: 2 H + O leave as water. It is the fast one, so the
		# pool's path across the van Krevelen plane runs toward the origin — toward carbon.
		rec(RM_ARRHENIUS, _rate_k(LAPhysical.COAL_DEHYDRATION_EA_OVER_R_K), ORG_O,
			[[ORG_H, 2.0], [ORG_O, 1.0]],
			[[H2O, 1.0, TGT_SELF]],
			GATE_BURIED, LAPhysical.COAL_DEHYDRATION_EA_OVER_R_K, -1,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, 0.0, _coal_enthalpy_j_m3(0.0, 2.0, 1.0)),

		# DECARBOXYLATION: a carbon and two oxygens leave as CO2, taking the backbone's nitrogen with them.
		# It strips oxygen twice as fast per unit of extent as dehydration does, which is what separates the
		# O:C fall from the H:C fall instead of walking one straight line.
		rec(RM_ARRHENIUS, _rate_k(LAPhysical.COAL_DECARBOXYLATION_EA_OVER_R_K), DETRITUS,
			[[DETRITUS, 1.0], [ORG_O, 2.0]],
			[[CO2, 1.0, TGT_SELF], [FERT, organic_n, TGT_SELF]],
			GATE_BURIED, LAPhysical.COAL_DECARBOXYLATION_EA_OVER_R_K, -1,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, 0.0, _coal_enthalpy_j_m3(1.0, 0.0, 2.0)),

		# REVERSIBLE. CaSiO3 + CO2 <-> CaCO3 + SiO2 is ONE reaction; decarbonation is this record running
		# backwards, and which way it goes is dG(T, p_CO2), not a threshold. CO2 is the one varying activity.
		LAReactionThermo.reversible(rec(RM_ARRHENIUS, DISSOLUTION_K, H2O_LIQUID,
			[[BEDROCK_BELOW, 1.0], [CO2, 1.0]],
			[[CARBONATE, 1.0, TGT_SELF],
				[SILICA, 1.0, TGT_SELF]],
			GATE_NEAR_GROUND, LAPhysical.SILICATE_DISSOLUTION_EA_OVER_R_K, CO2,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, LAPhysical.WATER_BOIL_C + LAPhysical.KELVIN_OFFSET), CO2),
	]
