class_name LAGeoRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"


# Urey, both ways: CaSiO3 + CO2 <-> CaCO3 + SiO2. An areal rate on the wetted bedrock surface, mol/m^2/s.
static func _dissolution_k() -> float:
	return pow(10.0, LAPhysical.WOLLASTONITE_DISSOLUTION_LOG10_K)


static func _rate_k_per_s(ea_over_r_k: float) -> float:
	var t_ref: float = LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET
	return LAPhysical.VITRINITE_FREQUENCY_FACTOR_PER_S * exp(-ea_over_r_k / t_ref)


## Premelted-film pressure per kelvin of undercooling, Pa/K (Walder & Anderson 1985, WRR 21:551).
static func _segregation_pa_per_k() -> float:
	var s: Dictionary = LASubstances.table()["h2o"]
	var t_m: float = LAPhysical.WATER_FREEZE_C + LAPhysical.KELVIN_OFFSET
	return LASubstances.solid_density("h2o") * float(s.get("latent_fusion_j_kg", 0.0)) / t_m


## Temperature at which segregation-ice pressure passes the rock's tensile strength, C.
static func _frost_threshold_c() -> float:
	var pa_per_k: float = _segregation_pa_per_k()
	if pa_per_k <= 0.0:
		return -INF
	return LAPhysical.WATER_FREEZE_C \
		- float(LASubstances.table()["silicate"].get("tensile_strength_pa", 0.0)) / pa_per_k


## Moles of rock detached per second per kelvin of undercooling, over the crack volume it needs.
# LA_APPROX: unfrozen_fringe_darcy
static func _frost_k_per_k() -> float:
	var dz: float = cell_height_m()
	if dz <= 0.0:
		return 0.0
	var phi: float = LAPhysical.REGOLITH_SURFACE_POROSITY
	var kappa_m2: float = phi * phi * phi * LAPhysical.GRAIN_D_UPLAND_M * LAPhysical.GRAIN_D_UPLAND_M \
		/ (LAPhysical.KOZENY_CARMAN_C * (1.0 - phi) * (1.0 - phi))
	var q_m_s_per_k: float = kappa_m2 * _segregation_pa_per_k() \
		/ (LAPhysical.WATER_DYNAMIC_VISCOSITY_PA_S * dz)
	return q_m_s_per_k * LASubstances.full_mol_m3("silicate") \
		/ (dz * LAPhysical.ROCK_POROSITY_NEAR_SURFACE)


static func records() -> Array:
	var organic_n: float = float(LAReactionBalance.composition()[DETRITUS]["N"])
	# Moles of pore water riding with one mole of detached rock: porosity times the full amounts' ratio.
	var pore: float = LAPhysical.ROCK_POROSITY_NEAR_SURFACE * LASubstances.full_mol_m3("h2o") \
		/ LASubstances.full_mol_m3("silicate")
	return [
		# Reversible on dG(T, p_H2O): water re-enters low-rank organic matter wet and leaves hot.
		LAReactionThermo.reversible(rec(TB_PER_SECOND, "mol m^-3 driver^-1 s^-1", RM_ARRHENIUS,
			_rate_k_per_s(LAPhysical.COAL_DEHYDRATION_EA_OVER_R_K), ORG_O,
			[[ORG_H, 2.0], [ORG_O, 1.0]],
			[[H2O, 1.0]],
			GATE_BURIED, LAPhysical.COAL_DEHYDRATION_EA_OVER_R_K, -1,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET), H2O),

		# One-way: nothing in the rock fixes CO2 back into buried kerogen.
		LAReactionThermo.priced(rec(TB_PER_SECOND, "mol m^-3 driver^-1 s^-1", RM_ARRHENIUS,
			_rate_k_per_s(LAPhysical.COAL_DECARBOXYLATION_EA_OVER_R_K), DETRITUS,
			[[DETRITUS, 1.0], [ORG_O, 2.0 + organic_n]],
			[[CO2, 1.0], [FERT, organic_n]],
			GATE_BURIED, LAPhysical.COAL_DECARBOXYLATION_EA_OVER_R_K, -1,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET)),

		# Reversible on dG(T, p_CO2); the driver is the WETTED bedrock surface, so a dry rock does not
		# dissolve.
		LAReactionThermo.reversible(rec(TB_PER_SECOND, "mol m^-3 driver^-1 s^-1",
			RM_ARRHENIUS, _dissolution_k(), ROCK_SURFACE_WET,
			[[BEDROCK_BELOW, 1.0], [CO2, 1.0]],
			[[CARBONATE, 1.0], [SILICA, 1.0]],
			GATE_NEAR_GROUND, LAPhysical.SILICATE_DISSOLUTION_EA_OVER_R_K, -1,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET), CO2),

		# Pore water migrating to the freezing front detaches bedrock where its premelting pressure passes
		# the rock's tensile strength; the water rides up with the debris.
		LAReactionThermo.priced(rec(TB_PER_SECOND, "mol m^-3 driver^-1 s^-1",
			RM_DEFICIT_BELOW_THRESHOLD, _frost_k_per_k(), TEMP,
			[[BEDROCK_BELOW, 1.0], [SOIL_TOP, pore]],
			[[SILICATE, 1.0], [H2O, pore]],
			GATE_NEAR_GROUND, _frost_threshold_c())),
	]
