class_name LABioRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## LIVING-CARBON records — R15 decompose, R19 photosynthesis, R20a respiration, R20b litterfall.
##
## ==============================================================================================
## EVERY RATE IN THIS FILE IS DERIVED FROM A MEASURED BIOLOGICAL FLUX. NONE IS FITTED TO AN OUTPUT.
## ==============================================================================================
##
## WHAT THE OLD RATES WERE, and why they had to go. `DECOMPOSE_RATE 0.05`, `PHOTO_RATE 0.05` and
## `RESP_RATE 0.01` were each arrived at by running the sim and picking the value whose `biomass_total`
## looked best — the file said so outright ("0.12 was tried to lift the total back toward the 3271-4306
## baseline. It did the OPPOSITE: biomass_total 320"; "cost 0.05 -> biomass_ground 1143 … More vegetation,
## six times the wet/dry contrast"). They were then fitted against stoichiometry that was WRONG: organic
## matter had no declared density, so a unit of detritus was assumed to hold the same moles as a unit of
## O2. Cellulose has a density now (dry wood, 500 kg/m3), one unit of it is 16652 mol/m3 against O2's
## 8.535, and every cross-substance coefficient moved by 1951x. A rate fitted to the old extents means
## nothing against the new ones.
##
## SO THEY ARE NOT RE-FITTED. Each is now a measured flux divided by the measured stock it acts on, put
## into this substrate's units by its own clock (LAMaterialFieldSphereStep3D.real_seconds_per_step, 43.2 s)
## and cell height (LAReactionDefs.cell_size_m, 16 m) and the substance table's molar bases. The pattern is
## LAPhaseRecords' — its evaporation coefficient is a bulk aerodynamic transfer coefficient times a wind
## speed times dt over H, with no free parameter — and it is the only pattern that survives a change of
## stoichiometry, because nothing in it was ever chosen to make an output look a particular way.
##
## THE HONEST CONSEQUENCE, STATED UP FRONT: this substrate's biology now runs at REAL biological speed, and
## real biological speed is very slow next to a 600-frame run. One field step is 43.2 real seconds, so a
## 600-frame run at --fast=8 is 590 steps = 25 488 s = 7.1 hours of planet time. In 7 hours a canopy fixes a
## few grams of carbon per square metre and litter loses 0.003 % of its mass. MEASURED on exactly that run,
## starting from the bare ground the world seeds: `biomass_ground` 0.00191 over 4430 ground cells = 3.4 g of
## dry matter per square metre, against the 4.0 g/m2 the derivation predicts — the record does what the
## arithmetic says it does. Expect the biosphere totals to look FLAT over any run anyone will actually
## do. That is not the rates being wrong; it is what "a year takes a year" means. Geology has the same
## problem and answers it with a declared multiplier (LAPlateTectonics.GEOLOGIC_TIME_ACCELERATION = 3.0e5,
## which is why weathering is quoted in "accelerated years"). Biology gets NO such multiplier here, and
## must not get one silently: photosynthesis is driven by the LIGHT slot, which is the real terminator on
## the real day, so a biological clock running faster than the solar one would put plants out of step with
## their own sun. If the project wants a visible biosphere in one run, that is a decision about the whole
## substrate's clock, not a number to raise in this file.
## (Explicit types only, no ':=' inferred typing.)

# --- THE MEASURED QUANTITIES THE RATES BELOW ARE DERIVED FROM ------------------------------------------
# These are global fluxes and stocks, not properties of a material, so they live here beside the records
# that use them rather than in LASubstances — the same place LAPhaseRecords keeps its bulk transfer
# coefficient and its 7 m/s mean ocean wind. Each is one published number with its source named.

# PHOTOSYNTHESIS — Monteith's light-use efficiency (Monteith 1972, 1977): fixed carbon is proportional to
# ABSORBED photosynthetically active radiation, GPP = eps * APAR, and eps is the measured constant of that
# proportionality. MODIS MOD17 carries eps_max by biome from 0.68 (grassland) to 1.26 (evergreen
# needleleaf) g C per MJ of absorbed PAR (Running et al. 2004; Heinsch et al. 2003). 1.0 is the middle.
const PHOTO_LUE_KG_C_PER_J: float = 1.0e-9        # 1.0 g C / MJ absorbed PAR
# PAR is the 400-700 nm band, a measured 45 % of incoming shortwave energy (Monteith & Unsworth; the value
# MOD17 uses). The substrate's LIGHT slot is a fraction of the SOLAR CONSTANT, so this is the factor that
# turns it into the part a chloroplast can use.
const PAR_FRACTION_OF_SHORTWAVE: float = 0.45
# TRANSPIRATION — the measured water cost of fixing carbon. A C3 canopy moves 200-1000 moles of water per
# mole of CO2 fixed (the inverse of water-use efficiency, ~2-5 mmol CO2 per mol H2O); 400 is mid-range.
# *(This REPLACES a fitted `PHOTO_WATER_COST = 0.05`. Its own comment recorded the fit: "MEASURED at 0.2,
# 0.45 and 0.0 … 0.2 wins outright", then "RE-MEASURED AT 0.05, WHICH BEATS 0.2 ON EVERY AXIS … biomass_ground
# 708 -> 1143, lit wet/dry 1.14 -> 6.86". Picking a transpiration ratio because it produces more vegetation
# and more contrast is fitting a physical quantity to an output. The number it landed on happened to be
# defensible — 0.05 water-channel units per CO2 unit is 324 mol H2O per mol C — but it was defensible by
# accident, and the reasoning is what has to be right. Derived, it comes out 0.0617.)*
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
# …and the decomposer community that k is measured WITH. R15 is first order in the decomposer stock as well
# as in the substrate, so its constant is a rate PER UNIT OF DECOMPOSER and needs the decomposer density the
# measurement corresponds to. Global soil microbial biomass carbon is 16.7 Pg C over 1.30e14 m2 of land
# (Xu, Thornton & Post 2013, Global Ecol. Biogeogr.) = 0.128 kg C/m2.
const SOIL_MICROBIAL_C_KG_PER_M2: float = 0.128

# THE TEMPERATURE BAND is bracketed by two constants already declared as properties of matter, so this file
# states no third temperature of its own. Photosynthesis stops when the cell's water freezes
# (LAPhysical.WATER_FREEZE_C) and stops when its enzymes denature (LAPhysical.PROTEIN_DENATURE_C, 45 C, the
# onset of irreversible thermal unfolding). OPTIMUM_BAND is a symmetric parabola, so the optimum is the
# MIDPOINT of those two — a consequence of the model's shape, not a fourth measurement. It lands at 22.5 C,
# inside the measured 20-30 C optimum of C3 photosynthesis, which is the check rather than the input.
# *(This replaces PHOTO_T_OPT 24.0 / PHOTO_T_WIDTH 24.0, whose upper zero was 48 C — a fourth version of
# "the temperature at which life stops", 3 C away from the one PhysicalConstants declares. The same
# quantity written down twice at two values is the drift pattern that froze water at 12.5 C.)*
# The real response is ASYMMETRIC — a gentle rise and a sharp fall — and a parabola cannot say that. The
# substrate has no rate model that can; noting it is more use than pretending otherwise.
const PHOTO_T_OPT: float = (LAPhysical.PROTEIN_DENATURE_C + LAPhysical.WATER_FREEZE_C) * 0.5
const PHOTO_T_WIDTH: float = (LAPhysical.PROTEIN_DENATURE_C - LAPhysical.WATER_FREEZE_C) * 0.5


## Kilograms of a substance in ONE unit of a channel that holds it — the channel unit IS the substance's
## condensed density (LAReactionBalance.mol_per_unit), so this is that density, read from the one table.
static func _density(id: String) -> float:
	return float(LASubstances.table().get(id, {}).get("density", 0.0))


## Real seconds one field step stands for. The substrate has ONE clock and this is it.
static func _dt() -> float:
	return LAMaterialFieldSphereStep3D.real_seconds_per_step()


## PHOTO_RATE — the per-step extent, in CO2 channel units, of a fully-absorbing canopy in full sun.
##
##     x = PHOTO_RATE * LIGHT * band(TEMP)
##     PHOTO_RATE = (eps / M_C) * f_PAR * S0 * dt / (H * mol_per_unit(CO2))
##
## Every factor is measured: eps is the light-use efficiency above, f_PAR the PAR share of shortwave, S0 the
## solar constant (LAPhysical.SOLAR_CONSTANT_W_M2, the SAME one the solar kernel heats with), dt the field
## step and H the cell height — the last two being exactly how LAPhaseRecords._evap_k turns an areal flux
## into a per-cell fill. It comes out 1.61e-5, against the fitted 0.05 it replaces: 3100x slower.
##
## WHAT fAPAR IS DOING HERE, since eps is defined per unit ABSORBED PAR: it is 1. The record therefore
## computes the POTENTIAL gross primary production of a cell whose canopy absorbs everything, and the
## substrate's own limits bring it down — the temperature band, and the three Liebig reactants (CO2, root
## water, nutrient). Checked against Earth: at this planet's measured mean ground insolation the potential
## works out near 2 kg C/m2/yr where Earth's terrestrial mean GPP is 0.8, i.e. the right order and on the
## generous side, which is what "potential, before local limitation" should look like.
##
## AND THE MISSING MECHANISM, NAMED RATHER THAN HIDDEN: real fAPAR is 1 - exp(-k*LAI), so it depends on how
## much leaf is standing there. This record has no biomass term at all — BIOMASS is not a reactant, not a
## driver and not a cap — so bare rock fixes carbon at the same rate as a forest. That is photosynthesis
## without a photosynthesiser, and it is a REALISM defect, not a rate defect: it would still be there at any
## value of this constant. It is not fixed here because the fix has two halves and only one of them is in
## this file — capping the extent by BIOMASS (rec() already takes cap_slot/cap_coeff, so no kernel change)
## sterilises the planet permanently unless something seeds a starting biomass, and the seed lives in
## LAMaterialSurfaceSeed3D, which seeds detritus and fuel and deliberately leaves biomass at zero.
static func _photo_k() -> float:
	var mol_c: float = LAPhysical.MOLAR_MASS_CARBON_KG_MOL
	var h: float = maxf(cell_size_m, 0.001)
	var mpu_co2: float = _density("co2") / LAPhysical.MOLAR_MASS_CO2_KG_MOL
	if mol_c <= 0.0 or mpu_co2 <= 0.0:
		return 0.0
	return (PHOTO_LUE_KG_C_PER_J / mol_c) * PAR_FRACTION_OF_SHORTWAVE \
		* LAPhysical.SOLAR_CONSTANT_W_M2 * _dt() / (h * mpu_co2)


## RESP_RATE — specific autotrophic respiration of standing vegetation, per step, at ambient oxygen.
##
##     Ra / B = (GPP - NPP) / B = (123 - 56.4) / 450 = 0.148 per year
##
## x = RESP_RATE * biomass * o2 is BILINEAR, so the constant is quoted per unit of O2 — and one unit of O2
## is, by the definition of the channel, the O2 in a cell of AMBIENT AIR (LAPhysical.AMBIENT_O2_DENSITY_KG_M3).
## So the reference oxygen concentration is exactly 1.0 and no number has to be chosen for it. Below ambient
## the rate falls, which is right in direction if not in shape: real maintenance respiration is near
## zero-order in O2 until oxygen gets scarce, so first order overstates how much a mildly hypoxic cell slows.
static func _resp_k() -> float:
	var per_year: float = (GLOBAL_GPP_PG_C_PER_YEAR - GLOBAL_NPP_PG_C_PER_YEAR) / GLOBAL_PLANT_CARBON_PG_C
	return per_year * _dt() / LAPhysical.SECONDS_PER_YEAR


## LITTERFALL_RATE — the specific rate at which standing vegetation becomes dead organic matter.
##
##     litterfall / B = NPP / B = 56.4 / 450 = 0.125 per year
##
## At steady state every gram of net primary production eventually falls, so the litterfall flux IS NPP.
## This is a SEPARATE RECORD from respiration and it has to be: they are two different measured processes
## with two different rates, and while they shared one record neither could be derived. The old table put
## them together and split the output 0.6 CO2 / 0.4 detritus by assertion — worth saying that the derived
## split, 0.148 / (0.148 + 0.125) = 0.54, lands close to it, so the old ratio was about right and the way it
## was arrived at was not. Splitting also removes an O2 dependence that never belonged: litterfall was
## inside an O2-capped record, so leaves stopped falling when the air ran short of oxygen.
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
##
##     k = Rh / SOC = 54 / 1500 = 0.036 per year   (mean residence time 28 years)
##     DECOMPOSE_RATE = k * dt / SECONDS_PER_YEAR / (decomposer stock k was measured with)
##
## It comes out 1.23e-3, against the fitted 0.05: 41x slower.
##
## READ THE FOLLOWING BEFORE TRUSTING THE REALISED RATE. This constant is honest; the realised rate is not,
## and the remaining error is not here. R15 is BILINEAR on (fungus x detritus), so what actually runs is
## `DECOMPOSE_RATE * fungus`, and this substrate's decomposer stock is much larger than a real soil's.
## Measured on a 600-frame --planet-only run with these rates in place: `fungus_total` 25.01 over 4430 ground
## cells is 0.0056 per cell, against the 4.0e-5 a real soil's microbial community weighs — 141x — and
## `fungus_peak` 0.0244 is 610x. So litter still rots 141-610 times faster than Olson, and the file to fix is
## `kernels3d/fungus_sphere3d.glsl`, whose GROW_RATE of 0.06 per step is 4.4e4 per year and whose FUNGUS_MAX
## ceiling of 3.0 would be 75 000x a real soil's microbial biomass. Those are model constants with no
## measurement behind them, in a file this track does not own.
static func _decompose_k() -> float:
	var k_per_year: float = SOIL_HETEROTROPHIC_RESP_PG_C_PER_YEAR / SOIL_ORGANIC_CARBON_PG_C
	var ref: float = _decomposer_reference()
	if ref <= 0.0:
		return 0.0
	return (k_per_year * _dt() / LAPhysical.SECONDS_PER_YEAR) / ref


## The records this domain contributes to the live table (see LAMaterialReactions3D).
static func records() -> Array:
	# EVERY CROSS-SUBSTANCE COEFFICIENT GOES THROUGH unit_ratio, AND THE COEFFICIENTS ARE PURE STOICHIOMETRY.
	# `unit_ratio(a, b)` is how many units of `a` hold the moles that one unit of `b` holds, read off the
	# substance table, so a coefficient reads as the mole count a chemist writes and the conversion cannot be
	# mistyped. Each record is denominated in its ORGANIC reactant, because that is what its rate is in.
	var o2_per_org: float = LAReactionBalance.unit_ratio(O2, DETRITUS)
	var co2_per_org: float = LAReactionBalance.unit_ratio(CO2, DETRITUS)
	var w_per_org: float = LAReactionBalance.unit_ratio(MOISTURE, DETRITUS)
	var fert_per_org: float = LAReactionBalance.unit_ratio(FERT, DETRITUS)
	var o2_per_co2: float = LAReactionBalance.unit_ratio(O2, CO2)
	var soil_per_co2: float = LAReactionBalance.unit_ratio(SOIL_ROOT, CO2)
	var org_per_co2: float = LAReactionBalance.unit_ratio(BIOMASS, CO2)
	var fert_per_co2: float = LAReactionBalance.unit_ratio(FERT, CO2)
	# Nitrogen per unit of organic matter, read off the composition table rather than restated, so a record
	# cannot disagree with the gate about what litter is made of. It is MOLAR: LITTER_C_TO_N is a ratio of
	# MASSES, and (CARBON_MOLAR_MASS / 20) / NITROGEN_MOLAR_MASS = 0.0429 mol N per mol CH2O — not the 0.0500
	# that spending the mass ratio directly produced.
	var organic_n: float = float(LAReactionBalance.composition()[DETRITUS]["N"])
	# TRANSPIRED WATER per unit of CO2 fixed, in water-channel units: a measured molar ratio put through the
	# same unit bridge as everything else. 400 mol H2O per mol C is 0.0617 here.
	var transpired: float = TRANSPIRATION_MOL_H2O_PER_MOL_C * soil_per_co2
	return [
		# R15 — FUNGUS DECOMPOSE: detritus + O2 -> CO2 (self) + water + fertility (scratch).
		# BILINEAR: x = DECOMPOSE_RATE * fungus * detritus, capped by the detritus and O2 present — the
		# aerobic limit falls out of listing O2 as a reactant rather than being a branch anywhere.
		#
		# THE STOICHIOMETRY IS FULL OXIDATION and every coefficient below is a literal 1 in moles:
		#     CH2O + O2 -> CO2 + H2O,  releasing the nitrogen the carbon leg leaves behind.
		# *(Three constants — CO2_PER_DECOMPOSE, O2_PER_DECOMPOSE, DECOMPOSE_WATER_YIELD — are DELETED. All
		# three were 1.0 and all three restated one equation. They existed because the table once shipped
		# O2 at 0.8 against CO2 at 1.0, an 18 % under-oxidation that created oxygen every cycle, and setting
		# two constants equal by hand was the fix available at the time. LAReactionBalance enforces it
		# structurally now: an unbalanced oxygen column refuses the whole table at load.)*
		rec(BILINEAR, _decompose_k(), FUNGUS,
			[[DETRITUS, 1.0], [O2, o2_per_org]],
			[[CO2, co2_per_org, TGT_SELF],
				[MOISTURE, w_per_org, TGT_SELF],
				[FERT, organic_n * fert_per_org, TGT_SCRATCH]],
			0, 0.0, DETRITUS),

		# R19 — PHOTOSYNTHESIS: light + CO2 + soil water + nutrient -> biomass + O2 + transpired vapour, on
		# the GROUND. OPTIMUM_BAND: x = PHOTO_RATE * LIGHT * band(TEMP; PHOTO_T_OPT, PHOTO_T_WIDTH). LIGHT
		# drives it because light is what drives photosynthesis, and it is the real per-cell insolation the
		# solar kernel uses, so there is one sun. TEMP is a BAND because the reaction has an optimum: the
		# upper edge is also what stops a lava flow growing plants, with no "is it lava" test anywhere.
		#
		# THREE Liebig reactants cap the extent — x <= min(co2, root_water/(1 + transpired), fert/uptake) —
		# so growth is limited by whichever input is actually scarce: carbon on a drawn-down leaf, water on a
		# plateau, nutrient on barren rock. No branch decides which; the min does.
		#
		# GATE_NEAR_GROUND is where a plant is — the ground-hugging open cell with rock beneath it, roots in
		# the soil below and leaves in the air. (It was GATE_SURFACE, which on a shell is the TOP OF THE
		# ATMOSPHERE: measured 2026-07-29, biomass at the sky skin 2334 and at the ground skin 0.0.)
		# GATE_NOT_STATIC keeps it out of the infinite sea reservoir, which is an unsimulated abstraction.
		#
		# THE WATER LEGS ARE TWO DIFFERENT QUANTITIES. `soil_per_co2` is the H2O SPLIT by the reaction — one
		# molecule per carbon, whose hydrogen becomes the sugar and whose oxygen leaves as the O2 — and it is
		# consumed. `transpired` is the water the plant moves through itself to do it, and it is a CONSERVING
		# PHASE TRANSFER: SOIL_ROOT is debited by exactly what MOISTURE is credited, so h2o_total does not
		# see it. That is what couples the aquifer to the forest and the forest to its own humidity.
		rec(OPTIMUM_BAND, _photo_k(), LIGHT,
			[[CO2, 1.0], [SOIL_ROOT, soil_per_co2 + transpired], [FERT, organic_n * fert_per_co2]],
			[[O2, o2_per_co2, TGT_SELF], [BIOMASS, org_per_co2, TGT_SELF],
				[MOISTURE, transpired, TGT_SELF]],
			GATE_NEAR_GROUND | GATE_NOT_STATIC, PHOTO_T_OPT, TEMP, PHOTO_T_WIDTH),

		# R20a — MAINTENANCE RESPIRATION: biomass + O2 -> CO2 + water + mineral nitrogen, everywhere biomass
		# exists. BILINEAR: x = RESP_RATE * biomass * o2; the BIOMASS reactant caps it (nothing can respire
		# more than is present) and the O2 reactant makes it aerobic. Full oxidation, CH2O + O2 -> CO2 + H2O,
		# so the carbon and water coefficients are ones in moles.
		#
		# THE NITROGEN LEG IS NOT OPTIONAL. Burning the carbon off a molecule does not destroy the nitrogen
		# in it, and this substrate's organic matter carries a FIXED C:N ratio, so nitrogen cannot stay
		# behind in a smaller amount of tissue — it has to go somewhere, and the somewhere is the soil's
		# plant-available pool. Plants really do resorb nitrogen before shedding tissue and the rest really
		# is mineralised. Without this product the record destroyed the nitrogen of everything it touched.
		rec(BILINEAR, _resp_k(), BIOMASS, [[BIOMASS, 1.0], [O2, o2_per_org]],
			[[CO2, co2_per_org, TGT_SELF], [MOISTURE, w_per_org, TGT_SELF],
				[FERT, organic_n * fert_per_org, TGT_SELF]],
			0, 0.0, O2),

		# R20b — LITTERFALL: biomass -> detritus. CONST_FRAC: x = LITTERFALL_RATE * biomass, capped by the
		# biomass present. Living tissue and dead litter are the SAME substance in two places, so this is a
		# pure one-for-one move with no chemistry in it — which is exactly why it must not have been sharing
		# a record, and an oxygen cap, with the oxidation above.
		rec(CONST_FRAC, _litterfall_k(), BIOMASS, [[BIOMASS, 1.0]], [[DETRITUS, 1.0, TGT_SELF]], 0),
	]
