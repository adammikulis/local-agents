class_name LABioRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## ==============================================================================================
## ==============================================================================================
## O2. Cellulose has a density now (dry wood, 500 kg/m3), one unit of it is 16652 mol/m3 against O2's

# These are global fluxes and stocks, not properties of a material, so they live here beside the records
# that use them rather than in LASubstances — the same place LAPhaseRecords keeps its bulk transfer
# coefficient and its 7 m/s mean ocean wind. Each is one published number with its source named.

# PHOTOSYNTHESIS — Monteith's light-use efficiency (Monteith 1972, 1977): fixed carbon is proportional to
# proportionality. MODIS MOD17 carries eps_max by biome from 0.68 (grassland) to 1.26 (evergreen
# needleleaf) g C per MJ of absorbed PAR (Running et al. 2004; Heinsch et al. 2003). 1.0 is the middle.
const PHOTO_LUE_KG_C_PER_J: float = 1.0e-9        # 1.0 g C / MJ absorbed PAR
# PAR is the 400-700 nm band, 0.45 of incoming shortwave energy (Monteith & Unsworth; the value MOD17
# uses). The substrate's LIGHT slot is a fraction of the SOLAR CONSTANT, so this is the factor that
# turns it into the part a chloroplast can use.
const PAR_FRACTION_OF_SHORTWAVE: float = 0.45
const TRANSPIRATION_MOL_H2O_PER_MOL_C: float = 400.0

# RESPIRATION and LITTERFALL — the specific rates at which standing vegetation burns itself and sheds
# itself, taken as global flux over global stock. Three published aggregates, nothing else:
const GLOBAL_GPP_PG_C_PER_YEAR: float = 123.0       # Beer et al. 2010, Science: 123 +/- 8 Pg C/yr
const GLOBAL_NPP_PG_C_PER_YEAR: float = 56.4        # Field et al. 1998, Science: terrestrial NPP
const GLOBAL_PLANT_CARBON_PG_C: float = 450.0       # Bar-On, Phillips & Milo 2018, PNAS: plant biomass
# DECOMPOSITION — Olson (1963) says litter mass loss is first order, X(t) = X0 * exp(-k t). The measured k
# for the WHOLE dead-organic pool is its heterotrophic respiration over its stock:
const SOIL_HETEROTROPHIC_RESP_PG_C_PER_YEAR: float = 54.0   # Bond-Lamberts & Thomson 2010; Hashimoto 2015
const SOIL_ORGANIC_CARBON_PG_C: float = 1500.0              # Batjes 1996, soil organic C to 1 m
const SOIL_MICROBIAL_C_KG_PER_M2: float = 0.128

const PHOTO_T_OPT: float = (LAPhysical.PROTEIN_DENATURE_C + LAPhysical.WATER_FREEZE_C) * 0.5
const PHOTO_T_WIDTH: float = (LAPhysical.PROTEIN_DENATURE_C - LAPhysical.WATER_FREEZE_C) * 0.5


## Kilograms of a substance in ONE unit of a channel that holds it — a fixed unit conversion, which is why
## it reads the table's REFERENCE value rather than LASubstances.density() at a cell.
static func _density(id: String) -> float:
	return float(LASubstances.table().get(id, {}).get("density", 0.0))


## Simulated seconds one field step stands for. The substrate has ONE step quantum and this is it.
static func _dt() -> float:
	return LAMaterialFieldSphereStep3D.real_seconds_per_step()


##     x = PHOTO_RATE * LIGHT * band(TEMP)
##     PHOTO_RATE = (eps / M_C) * f_PAR * S0 * dt / H
static func _photo_k() -> float:
	var mol_c: float = LAPhysical.MOLAR_MASS_CARBON_KG_MOL
	var h: float = maxf(cell_size_m, 0.001)
	var mpu_co2: float = _density("co2") / LAPhysical.MOLAR_MASS_CO2_KG_MOL
	if mol_c <= 0.0 or mpu_co2 <= 0.0:
		return 0.0
	return (PHOTO_LUE_KG_C_PER_J / mol_c) * PAR_FRACTION_OF_SHORTWAVE \
		* LAPhysical.SOLAR_CONSTANT_W_M2 * _dt() / (h * mpu_co2)


## x = RESP_RATE * biomass * o2 is BILINEAR, so the constant is quoted per unit of O2 — and one unit of O2
static func _resp_k() -> float:
	var per_year: float = (GLOBAL_GPP_PG_C_PER_YEAR - GLOBAL_NPP_PG_C_PER_YEAR) / GLOBAL_PLANT_CARBON_PG_C
	return per_year * _dt() / LAPhysical.SECONDS_PER_YEAR


static func _litterfall_k() -> float:
	var per_year: float = GLOBAL_NPP_PG_C_PER_YEAR / GLOBAL_PLANT_CARBON_PG_C
	return per_year * _dt() / LAPhysical.SECONDS_PER_YEAR


## The decomposer stock the measured decomposition constant corresponds to, in FUNGUS channel units:
## 0.128 kg C/m2 of soil microbial biomass, converted to CH2O, spread through the cell it lives in, and
## divided by the channel unit (a cell full of organic matter at 500 kg/m3). It comes out 4.0e-5.
static func _decomposer_reference() -> float:
	var rho: float = _density("cellulose")
	var h: float = maxf(cell_size_m, 0.001)
	if rho <= 0.0 or LAPhysical.MOLAR_MASS_CARBON_KG_MOL <= 0.0:
		return 0.0
	var ch2o_kg_m2: float = SOIL_MICROBIAL_C_KG_PER_M2 \
		* (LAPhysical.MOLAR_MASS_CH2O_UNIT_KG_MOL / LAPhysical.MOLAR_MASS_CARBON_KG_MOL)
	return ch2o_kg_m2 / (h * rho)


## DECOMPOSE_RATE — Olson's first-order decay constant, per unit of decomposer.
##     k = Rh / SOC = 54 / 1500 = 0.036 per year   (mean residence time 28 years)
static func _decompose_k() -> float:
	var k_per_year: float = SOIL_HETEROTROPHIC_RESP_PG_C_PER_YEAR / SOIL_ORGANIC_CARBON_PG_C
	var ref: float = _decomposer_reference()
	if ref <= 0.0:
		return 0.0
	return (k_per_year * _dt() / LAPhysical.SECONDS_PER_YEAR) / ref


## The records this domain contributes to the live table (see LAMaterialReactions3D).
static func records() -> Array:
	var organic_n: float = float(LAReactionBalance.composition()[DETRITUS]["N"])
	# Transpired water per CO2 fixed. Channel amounts are MOLES, so a measured molar ratio is the
	# coefficient -- it used to be multiplied by a unit bridge, which is how 400 mol H2O per mol C
	# appeared in this file as 0.0617.
	var transpired: float = TRANSPIRATION_MOL_H2O_PER_MOL_C
	return [
		# x = DECOMPOSE_RATE * fungus * detritus, in moles of the pool's CARBON. The rest of the stoichiometry
		# is the cell's own composition: CH_yO_z + (1 + y/4 - z/2) O2 -> CO2 + (y/2) H2O, so rotting peat draws
		# less oxygen and yields less water than rotting leaf litter, out of ONE record.
		rec(BILINEAR, _decompose_k(), FUNGUS,
			[[DETRITUS, 1.0], [ORG_H, 0.0, 1.0, 0.0], [ORG_O, 0.0, 0.0, 1.0],
				[O2, 1.0, 0.25, -0.5]],
			[[CO2, 1.0, TGT_SELF],
				[MOISTURE, 0.0, TGT_SELF, 0.5, 0.0],
				[FERT, organic_n, TGT_SCRATCH]],
			0, 0.0, DETRITUS),

		rec(OPTIMUM_BAND, _photo_k(), LIGHT,
			[[CO2, 1.0], [SOIL_ROOT, 1.0 + transpired], [FERT, organic_n]],
			[[O2, 1.0, TGT_SELF], [BIOMASS, 1.0, TGT_SELF],
				[MOISTURE, transpired, TGT_SELF]],
			GATE_NEAR_GROUND, PHOTO_T_OPT, TEMP, PHOTO_T_WIDTH),

		rec(BILINEAR, _resp_k(), BIOMASS, [[BIOMASS, 1.0], [O2, 1.0]],
			[[CO2, 1.0, TGT_SELF], [MOISTURE, 1.0, TGT_SELF],
				[FERT, organic_n, TGT_SELF]],
			0, 0.0, O2),

		# LITTERFALL. Living tissue is CH2O, so shed biomass enters the dead pool at H:C 2, O:C 1 — the fresh
		# end of the spectrum. Every record after this one only takes H and O away.
		rec(CONST_FRAC, _litterfall_k(), BIOMASS, [[BIOMASS, 1.0]],
			[[DETRITUS, 1.0, TGT_SELF], [ORG_H, 2.0, TGT_SELF], [ORG_O, 1.0, TGT_SELF]], 0),
	]
