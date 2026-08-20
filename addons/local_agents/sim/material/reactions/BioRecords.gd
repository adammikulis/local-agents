class_name LABioRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

const PHOTO_LUE_KG_C_PER_J: float = 1.0e-9        # 1.0 g C / MJ absorbed PAR (MODIS MOD17 eps_max)
const PAR_FRACTION_OF_SHORTWAVE: float = 0.45     # 400-700 nm share of shortwave (Monteith & Unsworth)
const TRANSPIRATION_MOL_H2O_PER_MOL_C: float = 400.0
const GLOBAL_GPP_PG_C_PER_YEAR: float = 123.0       # Beer et al. 2010, Science
const GLOBAL_NPP_PG_C_PER_YEAR: float = 56.4        # Field et al. 1998, Science
const GLOBAL_PLANT_CARBON_PG_C: float = 450.0       # Bar-On, Phillips & Milo 2018, PNAS
const SOIL_HETEROTROPHIC_RESP_PG_C_PER_YEAR: float = 54.0   # Bond-Lamberts & Thomson 2010
const SOIL_ORGANIC_CARBON_PG_C: float = 1500.0              # Batjes 1996, soil organic C to 1 m
const SOIL_MICROBIAL_C_KG_PER_M2: float = 0.128             # Serna-Chavez et al. 2013
const ICE_FREE_LAND_AREA_M2: float = 1.30e14
const PG_TO_KG: float = 1.0e12
const MICROBIAL_CUE: float = 0.3                    # Sinsabaugh et al. 2013; Manzoni et al. 2012

const PHOTO_T_OPT: float = (LAPhysical.PROTEIN_DENATURE_C + LAPhysical.WATER_FREEZE_C) * 0.5
const PHOTO_T_WIDTH: float = (LAPhysical.PROTEIN_DENATURE_C - LAPhysical.WATER_FREEZE_C) * 0.5

## Ambient O2, mol/m3 — the concentration the cited fluxes were measured at.
const O2_AMBIENT_MOL_M3: float = LAPhysical.AIR_MOLAR_DENSITY_MOL_M3 * LAPhysical.AIR_MOLE_FRAC_O2


## Photosynthesis rate coefficient, mol C m^-3 s^-1 per unit insolation: (eps / M_C) * f_PAR * S0 / H.
static func _photo_k() -> float:
	var mol_c: float = LAPhysical.MOLAR_MASS_CARBON_KG_MOL
	var h: float = cell_height_m()
	if mol_c <= 0.0 or h <= 0.0:
		return 0.0
	return (PHOTO_LUE_KG_C_PER_J / mol_c) * PAR_FRACTION_OF_SHORTWAVE \
		* LAPhysical.SOLAR_CONSTANT_W_M2 / h


## Autotrophic respiration per second AT AMBIENT O2: (GPP - NPP) / plant carbon.
static func _resp_k() -> float:
	var per_year: float = (GLOBAL_GPP_PG_C_PER_YEAR - GLOBAL_NPP_PG_C_PER_YEAR) / GLOBAL_PLANT_CARBON_PG_C
	return per_year / (LAPhysical.SECONDS_PER_YEAR * O2_AMBIENT_MOL_M3)


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
	var transpired: float = TRANSPIRATION_MOL_H2O_PER_MOL_C
	var cue: float = MICROBIAL_CUE
	var dh: Vector3 = LASubstances.organic_oxidation_parts()
	var ox: float = 1.0 - cue
	var lumped: float = dh.dot(Vector3(1.0, LASubstances.fresh_litter_per_carbon("H"),
		LASubstances.fresh_litter_per_carbon("O")))
	return [
		# Decomposition, in moles of the dead pool's carbon; CUE becomes mycelium and keeps its bond energy.
		rec(TB_PER_SECOND, "mol m^-3 driver^-1 driver2^-1 s^-1", RM_BILINEAR, _decompose_k(), FUNGUS,
			[[DETRITUS, 1.0], [ORG_H, 0.0, 1.0, 0.0], [ORG_O, 0.0, 0.0, 1.0],
				[O2, 1.0 - cue, 0.25, -0.5]],
			[[FUNGUS, cue],
				[CO2, 1.0 - cue],
				[H2O, -cue, 0.5, 0.0],
				[FERT, organic_n * (1.0 - cue)]],
			0, 0.0, DETRITUS, 0.0, -1, 0.0, 0.0, dh.x * ox, -1, 0.0, dh.y * ox, dh.z * ox),

		# Die-back: dead mycelium is CH2O, re-entering the dead pool at H:C 2, O:C 1.
		rec(TB_PER_SECOND, "mol m^-3 driver^-1 s^-1", RM_CONST_FRAC, _dieback_k(), FUNGUS, [[FUNGUS, 1.0]],
			[[DETRITUS, 1.0], [ORG_H, 2.0], [ORG_O, 1.0]], 0),

		# Fixing carbon stores the bond energy burning it releases, debited from the absorbed sunlight.
		rec(TB_PER_SECOND, "mol m^-3 driver^-1 s^-1", RM_OPTIMUM_BAND, _photo_k(), LIGHT,
			[[CO2, 1.0], [SOIL_ROOT, 1.0 + transpired], [FERT, organic_n]],
			[[O2, 1.0], [BIOMASS, 1.0],
				[H2O, transpired]],
			GATE_NEAR_GROUND, PHOTO_T_OPT, TEMP, PHOTO_T_WIDTH,
			-1, 0.0, 0.0, -lumped),

		rec(TB_PER_SECOND, "mol m^-3 driver^-1 driver2^-1 s^-1", RM_BILINEAR, _resp_k(), BIOMASS, [[BIOMASS, 1.0], [O2, 1.0]],
			[[CO2, 1.0], [H2O, 1.0],
				[FERT, organic_n]],
			0, 0.0, O2, 0.0, -1, 0.0, 0.0, lumped),

		# Litterfall: shed biomass enters the dead pool at H:C 2, O:C 1.
		rec(TB_PER_SECOND, "mol m^-3 driver^-1 s^-1", RM_CONST_FRAC, _litterfall_k(), BIOMASS, [[BIOMASS, 1.0]],
			[[DETRITUS, 1.0], [ORG_H, 2.0], [ORG_O, 1.0]], 0),
	]
