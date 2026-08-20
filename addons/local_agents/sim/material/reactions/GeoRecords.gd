class_name LAGeoRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"


# Urey, both ways: CaSiO3 + CO2 <-> CaCO3 + SiO2. Arrhenius, first order in the liquid h2o volume share.
const DISSOLUTION_K_PER_VF: float = 2.0e-5


static func _dissolution_k() -> float:
	return DISSOLUTION_K_PER_VF / LASubstances.full_mol_m3("h2o")


static func _rate_k(ea_over_r_k: float) -> float:
	var t_ref: float = LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET
	return LAPhysical.VITRINITE_FREQUENCY_FACTOR_PER_S \
		* LAMaterialFieldSphereStep3D.real_seconds_per_step() * exp(-ea_over_r_k / t_ref)


## Heat per unit extent when the pool loses these moles of C, H and O. J/m3.
static func _coal_enthalpy_j_m3(mol_c: float, mol_h: float, mol_o: float) -> float:
	return LASubstances.organic_oxidation_parts().dot(Vector3(mol_c, mol_h, mol_o))


## Temperature at which segregation-ice pressure passes the rock's tensile strength, C.
static func _frost_threshold_c() -> float:
	var pa_per_k: float = LASubstances.fusion_pa_per_k("h2o")
	if pa_per_k <= 0.0:
		return -INF
	return LAPhysical.WATER_FREEZE_C \
		- float(LASubstances.table()["silicate"].get("tensile_strength_pa", 0.0)) / pa_per_k


## Silicate detached per step per kelvin of excess undercooling, mol/m^3/K: Darcy delivery of pore water
## under the Clapeyron gradient, over the crack volume a unit of rock needs, in moles of rock.
# LA_APPROX: unfrozen_fringe_darcy
static func _frost_k_per_k() -> float:
	var dz: float = cell_height_m()
	if dz <= 0.0:
		return 0.0
	var phi: float = LAPhysical.REGOLITH_SURFACE_POROSITY
	var kappa_m2: float = phi * phi * phi * LAPhysical.GRAIN_D_UPLAND_M * LAPhysical.GRAIN_D_UPLAND_M \
		/ (LAPhysical.KOZENY_CARMAN_C * (1.0 - phi) * (1.0 - phi))
	var q_m_s_per_k: float = kappa_m2 * LASubstances.fusion_pa_per_k("h2o") \
		/ (LAPhysical.WATER_DYNAMIC_VISCOSITY_PA_S * dz)
	return q_m_s_per_k * LAMaterialFieldSphereStep3D.real_seconds_per_step() \
		* LASubstances.full_mol_m3("silicate") / (dz * LAPhysical.ROCK_POROSITY_NEAR_SURFACE)


## Reaction records this domain contributes to the live table.
static func records() -> Array:
	var organic_n: float = float(LAReactionBalance.composition()[DETRITUS]["N"])
	return [
		rec(RM_ARRHENIUS, _rate_k(LAPhysical.COAL_DEHYDRATION_EA_OVER_R_K), ORG_O,
			[[ORG_H, 2.0], [ORG_O, 1.0]],
			[[H2O, 1.0]],
			GATE_BURIED, LAPhysical.COAL_DEHYDRATION_EA_OVER_R_K, -1,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, 0.0, _coal_enthalpy_j_m3(0.0, 2.0, 1.0)),

		rec(RM_ARRHENIUS, _rate_k(LAPhysical.COAL_DECARBOXYLATION_EA_OVER_R_K), DETRITUS,
			[[DETRITUS, 1.0], [ORG_O, 2.0]],
			[[CO2, 1.0], [FERT, organic_n]],
			GATE_BURIED, LAPhysical.COAL_DECARBOXYLATION_EA_OVER_R_K, -1,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, 0.0, _coal_enthalpy_j_m3(1.0, 0.0, 2.0)),

		# Reversible: direction is dG(T, p_CO2), not a threshold. CO2 is the one varying activity.
		LAReactionThermo.reversible(rec(RM_ARRHENIUS, _dissolution_k(), H2O_LIQUID,
			[[BEDROCK_BELOW, 1.0], [CO2, 1.0]],
			[[CARBONATE, 1.0],
				[SILICA, 1.0]],
			GATE_NEAR_GROUND, LAPhysical.SILICATE_DISSOLUTION_EA_OVER_R_K, CO2,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, LAPhysical.WATER_BOIL_C + LAPhysical.KELVIN_OFFSET), CO2),

		# Ice segregation: pore water migrates to the freezing front and detaches bedrock where its
		# Clapeyron pressure passes the rock's tensile strength. The water rides up with the debris.
		rec(RM_DEFICIT_BELOW_THRESHOLD, _frost_k_per_k(), TEMP,
			[[BEDROCK_BELOW, 1.0], [SOIL_TOP, _pore_water_per_rock()]],
			[[SILICATE, 1.0], [H2O, _pore_water_per_rock()]],
			GATE_NEAR_GROUND, _frost_threshold_c()),
	]


## Moles of pore water riding with one mole of detached rock: porosity times the two full amounts' ratio.
static func _pore_water_per_rock() -> float:
	return LAPhysical.ROCK_POROSITY_NEAR_SURFACE * LASubstances.full_mol_m3("h2o") \
		/ LASubstances.full_mol_m3("silicate")
