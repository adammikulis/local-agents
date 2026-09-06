class_name LABioRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

const GLOBAL_GPP_PG_C_PER_YEAR: float = 123.0       # Beer et al. 2010, Science
const GLOBAL_NPP_PG_C_PER_YEAR: float = 56.4        # Field et al. 1998, Science
const GLOBAL_PLANT_CARBON_PG_C: float = 450.0       # Bar-On, Phillips & Milo 2018, PNAS
const SOIL_HETEROTROPHIC_RESP_PG_C_PER_YEAR: float = 54.0   # Bond-Lamberts & Thomson 2010
const SOIL_ORGANIC_CARBON_PG_C: float = 1500.0              # Batjes 1996, soil organic C to 1 m
const SOIL_MICROBIAL_C_KG_PER_M2: float = 0.128             # Serna-Chavez et al. 2013
const ICE_FREE_LAND_AREA_M2: float = 1.30e14
const PG_TO_KG: float = 1.0e12
const MICROBIAL_CUE: float = 0.3                    # Sinsabaugh et al. 2013; Manzoni et al. 2012

# C3 electron-transport temperature response, C: optimum and Gaussian width, June, Evans & Farquhar 2004,
# Funct. Plant Biol. 31:275.
# LA_APPROX: parabolic_photosynthesis_band
const PHOTO_T_OPT: float = 30.0
const PHOTO_T_WIDTH: float = 18.0

## Half-saturating O2 for mitochondrial respiration, Pa: the p50 of cytochrome c oxidase, Gnaiger,
## Lassnig, Kuznetsov, Rieger & Margreiter 1998, J. Exp. Biol. 201:1129.
const RESPIRATION_O2_P50_PA: float = 35.0

# Planetary mean of the LIGHT driver: sun-facing cross-section over surface, piR^2 / 4piR^2.
const LIGHT_SPHERE_MEAN: float = PI / (4.0 * PI)


## Photosynthesis per second per unit LIGHT AT UNIT BIOMASS: GPP / plant carbon, referenced to the
## mean insolation the cited flux was measured under.
# LA_APPROX: optically_thin_canopy
static func _photo_k() -> float:
	var per_year: float = GLOBAL_GPP_PG_C_PER_YEAR / GLOBAL_PLANT_CARBON_PG_C
	return per_year / (LAPhysical.SECONDS_PER_YEAR * LIGHT_SPHERE_MEAN)


## The p50 as a concentration in the cell's gas, mol/m^3: p = c R T at the temperature it was measured at.
static func _resp_half_sat_mol_m3() -> float:
	return RESPIRATION_O2_P50_PA / (LAPhysical.GAS_CONSTANT_J_MOL_K
		* (LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET))


## Autotrophic respiration per second at SATURATING O2: (GPP - NPP) / plant carbon. Michaelis-Menten in
## oxygen: k is V_max / K_m, and param2 below is 1 / K_m, so the two combine to V_max well above the p50.
static func _resp_k() -> float:
	var per_year: float = (GLOBAL_GPP_PG_C_PER_YEAR - GLOBAL_NPP_PG_C_PER_YEAR) / GLOBAL_PLANT_CARBON_PG_C
	return per_year / (LAPhysical.SECONDS_PER_YEAR * _resp_half_sat_mol_m3())


static func _litterfall_k() -> float:
	var per_year: float = GLOBAL_NPP_PG_C_PER_YEAR / GLOBAL_PLANT_CARBON_PG_C
	return per_year / LAPhysical.SECONDS_PER_YEAR


## Soil microbial biomass in FUNGUS channel units, mol/m^3: moles of CH2O carbon spread through one cell
## height.
static func _decomposer_reference() -> float:
	var h: float = cell_height_m()
	if h <= 0.0 or LAPhysical.MOLAR_MASS_CARBON_KG_MOL <= 0.0:
		return 0.0
	return SOIL_MICROBIAL_C_KG_PER_M2 / (LAPhysical.MOLAR_MASS_CARBON_KG_MOL * h)


## First-order decay constant per second per unit of decomposer; gross uptake is Rh / (1 - CUE).
static func _decompose_k() -> float:
	var k_per_year: float = SOIL_HETEROTROPHIC_RESP_PG_C_PER_YEAR / SOIL_ORGANIC_CARBON_PG_C
	var ref: float = _decomposer_reference()
	if ref <= 0.0 or MICROBIAL_CUE >= 1.0:
		return 0.0
	return (k_per_year / LAPhysical.SECONDS_PER_YEAR) / ((1.0 - MICROBIAL_CUE) * ref)


## Decomposer die-back per second: CUE/(1 - CUE) * Rh / MBC.
static func _dieback_k() -> float:
	if MICROBIAL_CUE >= 1.0 or SOIL_MICROBIAL_C_KG_PER_M2 <= 0.0:
		return 0.0
	var rh: float = SOIL_HETEROTROPHIC_RESP_PG_C_PER_YEAR * PG_TO_KG / ICE_FREE_LAND_AREA_M2
	var per_year: float = (MICROBIAL_CUE / (1.0 - MICROBIAL_CUE)) * rh / SOIL_MICROBIAL_C_KG_PER_M2
	return per_year / LAPhysical.SECONDS_PER_YEAR


## Reaction records this domain contributes to the live table.
static func records() -> Array:
	var organic_n: float = float(LAReactionBalance.composition()[DETRITUS]["N"])
	var cue: float = MICROBIAL_CUE
	# The oxygen the pool's nitrogen leaves with, on top of what its carbon and hydrogen take.
	var n_o2: float = 0.5 * organic_n
	return [
		# Decomposition, in moles of the dead pool's carbon; CUE becomes mycelium and keeps its bond energy.
		LAReactionThermo.priced(rec(TB_PER_SECOND, "mol m^-3 driver^-1 driver2^-1 s^-1", RM_BILINEAR,
			_decompose_k(), FUNGUS,
			[[DETRITUS, 1.0], [ORG_H, 0.0, 1.0, 0.0], [ORG_O, 0.0, 0.0, 1.0],
				[O2, (1.0 - cue) * (1.0 + n_o2), 0.25, -0.5]],
			[[FUNGUS, cue],
				[CO2, 1.0 - cue],
				[H2O, -cue, 0.5, 0.0],
				[FERT, organic_n * (1.0 - cue)]],
			0, 0.0, DETRITUS)),

		# Die-back: dead mycelium is CH2O, re-entering the dead pool at H:C 2, O:C 1.
		LAReactionThermo.priced(rec(TB_PER_SECOND, "mol m^-3 driver^-1 s^-1", RM_CONST_FRAC, _dieback_k(),
			FUNGUS, [[FUNGUS, 1.0]],
			[[DETRITUS, 1.0], [ORG_H, 2.0], [ORG_O, 1.0]], 0)),

		# Fixing carbon stores the bond energy burning it releases, debited from the absorbed sunlight.
		# BIOMASS is the catalyst: no photosynthetic tissue, no carbon fixed.
		LAReactionThermo.priced(rec(TB_PER_SECOND, "mol m^-3 driver^-1 driver2^-1 s^-1", RM_OPTIMUM_BAND,
			_photo_k(), LIGHT,
			[[CO2, 1.0], [SOIL_ROOT, 1.0], [FERT, organic_n]],
			[[O2, 1.0 + n_o2], [BIOMASS, 1.0]],
			GATE_NEAR_GROUND, PHOTO_T_OPT, BIOMASS, PHOTO_T_WIDTH)),

		# Respiration: first order in tissue, Michaelis-Menten in oxygen — it saturates at the p50, so the
		# rate does not track the atmosphere's oxygen once there is any to speak of.
		LAReactionThermo.priced(rec(TB_PER_SECOND, "mol m^-3 driver^-1 driver2^-1 s^-1",
			RM_RESISTANCE_SERIES, _resp_k(), BIOMASS,
			[[BIOMASS, 1.0], [O2, 1.0 + n_o2]],
			[[CO2, 1.0], [H2O, 1.0], [FERT, organic_n]],
			0, 0.0, O2, 1.0 / _resp_half_sat_mol_m3())),

		# Litterfall: shed biomass enters the dead pool at H:C 2, O:C 1.
		LAReactionThermo.priced(rec(TB_PER_SECOND, "mol m^-3 driver^-1 s^-1", RM_CONST_FRAC,
			_litterfall_k(), BIOMASS, [[BIOMASS, 1.0]],
			[[DETRITUS, 1.0], [ORG_H, 2.0], [ORG_O, 1.0]], 0)),
	]
