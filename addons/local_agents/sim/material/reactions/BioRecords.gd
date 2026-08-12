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
const MICROBIAL_CUE: float = 0.3                  # Sinsabaugh et al. 2013; Manzoni et al. 2012

const PHOTO_T_OPT: float = (LAPhysical.PROTEIN_DENATURE_C + LAPhysical.WATER_FREEZE_C) * 0.5
const PHOTO_T_WIDTH: float = (LAPhysical.PROTEIN_DENATURE_C - LAPhysical.WATER_FREEZE_C) * 0.5


## Reference density of a substance, kg/m3.
static func _density(id: String) -> float:
	return float(LASubstances.table().get(id, {}).get("density", 0.0))


## Simulated seconds one field step stands for.
static func _dt() -> float:
	return LAMaterialFieldSphereStep3D.real_seconds_per_step()


## Photosynthesis rate coefficient: (eps / M_C) * f_PAR * S0 * dt / H.
static func _photo_k() -> float:
	var mol_c: float = LAPhysical.MOLAR_MASS_CARBON_KG_MOL
	var h: float = cell_height_m()
	var mpu_co2: float = _density("co2") / LAPhysical.MOLAR_MASS_CO2_KG_MOL
	if mol_c <= 0.0 or mpu_co2 <= 0.0 or h <= 0.0:
		return 0.0
	return (PHOTO_LUE_KG_C_PER_J / mol_c) * PAR_FRACTION_OF_SHORTWAVE \
		* LAPhysical.SOLAR_CONSTANT_W_M2 * _dt() / (h * mpu_co2)


## Autotrophic respiration rate per step: (GPP - NPP) / plant carbon.
static func _resp_k() -> float:
	var per_year: float = (GLOBAL_GPP_PG_C_PER_YEAR - GLOBAL_NPP_PG_C_PER_YEAR) / GLOBAL_PLANT_CARBON_PG_C
	return per_year * _dt() / LAPhysical.SECONDS_PER_YEAR


static func _litterfall_k() -> float:
	var per_year: float = GLOBAL_NPP_PG_C_PER_YEAR / GLOBAL_PLANT_CARBON_PG_C
	return per_year * _dt() / LAPhysical.SECONDS_PER_YEAR


## Soil microbial biomass expressed in FUNGUS channel units.
static func _decomposer_reference() -> float:
	var rho: float = _density("cellulose")
	var h: float = cell_height_m()
	if rho <= 0.0 or LAPhysical.MOLAR_MASS_CARBON_KG_MOL <= 0.0 or h <= 0.0:
		return 0.0
	var ch2o_kg_m2: float = SOIL_MICROBIAL_C_KG_PER_M2 \
		* (LAPhysical.MOLAR_MASS_CH2O_UNIT_KG_MOL / LAPhysical.MOLAR_MASS_CARBON_KG_MOL)
	return ch2o_kg_m2 / (h * rho)


## First-order decay constant per unit of decomposer; gross uptake is Rh / (1 - CUE).
static func _decompose_k() -> float:
	var k_per_year: float = SOIL_HETEROTROPHIC_RESP_PG_C_PER_YEAR / SOIL_ORGANIC_CARBON_PG_C
	var ref: float = _decomposer_reference()
	if ref <= 0.0 or MICROBIAL_CUE >= 1.0:
		return 0.0
	return (k_per_year * _dt() / LAPhysical.SECONDS_PER_YEAR) / ((1.0 - MICROBIAL_CUE) * ref)


## Decomposer die-back rate per step: CUE/(1 - CUE) * Rh / MBC.
static func _dieback_k() -> float:
	if MICROBIAL_CUE >= 1.0 or SOIL_MICROBIAL_C_KG_PER_M2 <= 0.0:
		return 0.0
	var rh: float = SOIL_HETEROTROPHIC_RESP_PG_C_PER_YEAR * PG_TO_KG / ICE_FREE_LAND_AREA_M2
	var per_year: float = (MICROBIAL_CUE / (1.0 - MICROBIAL_CUE)) * rh / SOIL_MICROBIAL_C_KG_PER_M2
	return per_year * _dt() / LAPhysical.SECONDS_PER_YEAR


## Reaction records this domain contributes to the live table.
static func records() -> Array:
	var organic_n: float = float(LAReactionBalance.composition()[DETRITUS]["N"])
	var transpired: float = TRANSPIRATION_MOL_H2O_PER_MOL_C
	var cue: float = MICROBIAL_CUE
	return [
		# Decomposition, in moles of the dead pool's carbon taken up; CUE of it becomes mycelium.
		rec(RM_BILINEAR, _decompose_k(), FUNGUS,
			[[DETRITUS, 1.0], [ORG_H, 0.0, 1.0, 0.0], [ORG_O, 0.0, 0.0, 1.0],
				[O2, 1.0 - cue, 0.25, -0.5]],
			[[FUNGUS, cue, TGT_SELF],
				[CO2, 1.0 - cue, TGT_SELF],
				[H2O, -cue, TGT_SELF, 0.5, 0.0],
				[FERT, organic_n * (1.0 - cue), TGT_SCRATCH]],
			0, 0.0, DETRITUS),

		# Die-back: dead mycelium is CH2O, re-entering the dead pool at H:C 2, O:C 1.
		rec(RM_CONST_FRAC, _dieback_k(), FUNGUS, [[FUNGUS, 1.0]],
			[[DETRITUS, 1.0, TGT_SELF], [ORG_H, 2.0, TGT_SELF], [ORG_O, 1.0, TGT_SELF]], 0),

		rec(RM_OPTIMUM_BAND, _photo_k(), LIGHT,
			[[CO2, 1.0], [SOIL_ROOT, 1.0 + transpired], [FERT, organic_n]],
			[[O2, 1.0, TGT_SELF], [BIOMASS, 1.0, TGT_SELF],
				[H2O, transpired, TGT_SELF]],
			GATE_NEAR_GROUND, PHOTO_T_OPT, TEMP, PHOTO_T_WIDTH),

		rec(RM_BILINEAR, _resp_k(), BIOMASS, [[BIOMASS, 1.0], [O2, 1.0]],
			[[CO2, 1.0, TGT_SELF], [H2O, 1.0, TGT_SELF],
				[FERT, organic_n, TGT_SELF]],
			0, 0.0, O2),

		# Litterfall: shed biomass enters the dead pool at H:C 2, O:C 1.
		rec(RM_CONST_FRAC, _litterfall_k(), BIOMASS, [[BIOMASS, 1.0]],
			[[DETRITUS, 1.0, TGT_SELF], [ORG_H, 2.0, TGT_SELF], [ORG_O, 1.0, TGT_SELF]], 0),
	]
