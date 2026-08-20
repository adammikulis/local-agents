class_name LAGeoRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"


# Urey, both ways: CaSiO3 + CO2 <-> CaCO3 + SiO2. Arrhenius, first order in the liquid h2o volume share.
const DISSOLUTION_K_PER_VF: float = 2.0e-5


## The quoted k is per liquid VOLUME SHARE; the H2O_LIQUID driver is mol/m^3, so divide by a full cell's.
static func _dissolution_k() -> float:
	return DISSOLUTION_K_PER_VF / LASubstances.full_mol_m3("h2o")


static func _rate_k_per_s(ea_over_r_k: float) -> float:
	var t_ref: float = LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET
	return LAPhysical.VITRINITE_FREQUENCY_FACTOR_PER_S * exp(-ea_over_r_k / t_ref)


## Heat released when the pool loses these moles of C, H and O, J/mol of extent.
static func _coal_enthalpy_j_mol(mol_c: float, mol_h: float, mol_o: float) -> float:
	return mol_c * LASubstances.organic_energy_j_mol("C") + mol_h * LASubstances.organic_energy_j_mol("H") \
		+ mol_o * LASubstances.organic_energy_j_mol("O")


## Temperature at which segregation-ice pressure passes the rock's tensile strength, C.
static func _frost_threshold_c() -> float:
	var pa_per_k: float = LASubstances.fusion_pa_per_k("h2o")
	if pa_per_k <= 0.0:
		return -INF
	return LAPhysical.WATER_FREEZE_C \
		- float(LASubstances.table()["silicate"].get("tensile_strength_pa", 0.0)) / pa_per_k


## Moles of rock detached per second per kelvin of excess undercooling: Darcy delivery of pore water
## under the Clapeyron gradient over the crack volume a unit of rock needs, times rock molar density.
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
	return q_m_s_per_k * LASubstances.full_mol_m3("silicate") \
		/ (dz * LAPhysical.ROCK_POROSITY_NEAR_SURFACE)


## Reaction records this domain contributes to the live table.
static func records() -> Array:
	var organic_n: float = float(LAReactionBalance.composition()[DETRITUS]["N"])
	# Moles of pore water riding with one mole of detached rock: porosity times the full amounts' ratio.
	var pore: float = LAPhysical.ROCK_POROSITY_NEAR_SURFACE * LASubstances.full_mol_m3("h2o") \
		/ LASubstances.full_mol_m3("silicate")
	return [
		# Reversible: direction is dG(T, p_H2O) — water re-enters low-rank organic matter wet, leaves hot.
		LAReactionThermo.reversible(rec(TB_PER_SECOND, "mol m^-3 driver^-1 s^-1", RM_ARRHENIUS,
			_rate_k_per_s(LAPhysical.COAL_DEHYDRATION_EA_OVER_R_K), ORG_O,
			[[ORG_H, 2.0], [ORG_O, 1.0]],
			[[H2O, 1.0]],
			GATE_BURIED, LAPhysical.COAL_DEHYDRATION_EA_OVER_R_K, -1,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, 0.0, _coal_enthalpy_j_mol(0.0, 2.0, 1.0)), H2O),

		# One-way: FERT (fixed_n) has no standard-state data, so no dG can be derived for it.
		rec(TB_PER_SECOND, "mol m^-3 driver^-1 s^-1", RM_ARRHENIUS,
			_rate_k_per_s(LAPhysical.COAL_DECARBOXYLATION_EA_OVER_R_K), DETRITUS,
			[[DETRITUS, 1.0], [ORG_O, 2.0]],
			[[CO2, 1.0], [FERT, organic_n]],
			GATE_BURIED, LAPhysical.COAL_DECARBOXYLATION_EA_OVER_R_K, -1,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, 0.0, _coal_enthalpy_j_mol(1.0, 0.0, 2.0)),

		# Reversible: direction is dG(T, p_CO2), not a threshold. CO2 is the one varying activity.
		LAReactionThermo.reversible(rec(TB_PER_STEP, "mol m^-3 driver^-1 driver2^-1 step^-1",
			RM_ARRHENIUS, _dissolution_k(), H2O_LIQUID,
			[[BEDROCK_BELOW, 1.0], [CO2, 1.0]],
			[[CARBONATE, 1.0], [SILICA, 1.0]],
			GATE_NEAR_GROUND, LAPhysical.SILICATE_DISSOLUTION_EA_OVER_R_K, CO2,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, LAPhysical.WATER_BOIL_C + LAPhysical.KELVIN_OFFSET), CO2),

		# Ice segregation: pore water migrating to the freezing front detaches bedrock where its Clapeyron
		# pressure passes the rock's tensile strength; the water rides up with the debris.
		rec(TB_PER_SECOND, "mol m^-3 driver^-1 s^-1", RM_DEFICIT_BELOW_THRESHOLD, _frost_k_per_k(), TEMP,
			[[BEDROCK_BELOW, 1.0], [SOIL_TOP, pore]],
			[[SILICATE, 1.0], [H2O, pore]],
			GATE_NEAR_GROUND, _frost_threshold_c()),
	]
