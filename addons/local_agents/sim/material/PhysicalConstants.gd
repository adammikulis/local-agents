class_name LAPhysical
extends RefCounted

## THE MEASURED PROPERTIES OF REAL MATTER — the one place they are written down.
##
## Every value here is a physical fact with a source, not a tuning knob. Hardcoding them is CORRECT and is
## the point of the file: water freezes at 0 °C, basalt erupts near 1200 °C, iron melts. Those numbers do not
## get "balanced". What they replaced is the opposite thing — constants fitted to make a broken simulation
## produce a nice-looking output, which is how this project ended up with WATER FREEZING AT 12.5 °C.
##
## That one is worth recording so it is never re-derived. `MaterialReactions3D.FREEZE_TEMP` was 12.5 with a
## comment explaining itself: "TUNED to the sim's ACTUAL open-cell temperature range (~11-21 °C) ... A literal
## 0 °C freeze can never fire here." The planet could not get cold, so the freezing point of water was moved
## up to meet it, in FIVE places, at THREE different values (12.5 in MaterialReactions3D and
## snowice_sphere3d, 13.0 in charge_accum_sphere3d and activity_sphere3d, melting at 14.0). Snow then
## "worked", and every measurement taken against it was meaningless.
##
## THE RULE THIS FILE ENFORCES: if a physical constant has to move for the simulation to look right, the
## simulation is wrong. Fix the simulation. A value may only live here if you can cite what it is a property
## OF. Anything else is a model parameter and belongs next to the model that uses it.
##
## GLSL kernels cannot read GDScript, so each kernel still declares its own copy. `scripts/check_physical_constants.sh`
## is the gate that keeps them equal to these — drift fails the build rather than silently re-introducing a 12.5.
## (Explicit types only, no ':=' inferred typing.)

# --- WATER (H₂O) ------------------------------------------------------------------------------------------
# At 1 atm. The phase diagram is not negotiable and there is no hysteresis in it: ice and liquid water
# coexist at exactly one temperature, so freeze and melt are the SAME number. The old 12.5/14.0 split was a
# 1.5 °C hysteresis band added to stop the snow line flickering; if flicker returns, damp it in the kernel's
# rate, never by moving the phase boundary.
const WATER_FREEZE_C: float = 0.0
const WATER_MELT_C: float = 0.0
const WATER_BOIL_C: float = 100.0
# Liquid water at 25 °C. It is the denominator of every "how much of a cell is water" figure in this
# substrate: the field stores water as a FILL FRACTION (1.0 = a cell full of liquid), so any real density
# has to be divided by this to become a channel value. Same number the volumetric heat capacity below uses.
const WATER_DENSITY_KG_M3: float = 997.0

# --- WATER VAPOUR: THE SATURATION CURVE ---------------------------------------------------------------------
# HOW MUCH WATER AIR CAN HOLD IS NOT A TUNING KNOB — it is the saturation vapour pressure, and it is the one
# fact that decides how much of a planet's water is in its sky. Earth's atmosphere holds ~12,900 km³ of water
# against ~1.34e9 km³ of ocean: one part in a hundred thousand. This simulation held THIRTY PERCENT of its
# mobile water in the air, four orders of magnitude out, because `SAT_BASE = 0.06` — the saturation mass
# fraction at 22 °C — was written by hand instead of computed. The real value is 1.95e-5. It was 3080x too big,
# and every cloud, rain and snow number ever measured here was measured against it.
#
# The curve itself is Clausius-Clapeyron. The closed form used is the AUGUST-ROCHE-MAGNUS approximation with
# the coefficients of Alduchov & Eskridge (1996), which is within 0.4% of the exact integration over
# -40..+50 °C:
#     e_sat(T) = MAGNUS_A * exp(MAGNUS_B * T / (T + MAGNUS_C))     [Pa, T in °C, over liquid water]
# Its logarithmic slope at 20 °C is 6.2%/°C — the familiar "7% more water vapour per degree".
const MAGNUS_A_PA: float = 610.94
const MAGNUS_B: float = 17.625
const MAGNUS_C_C: float = 243.04
# Specific gas constant of water vapour = universal R (8314.46 J/kmol/K) / molar mass (18.015 kg/kmol).
# Turns that pressure into a DENSITY through the ideal gas law: rho_v = e / (R_v * T_K).
const VAPOUR_GAS_CONST_J_KGK: float = 461.52

# --- THUNDERSTORM CHARGE SEPARATION -----------------------------------------------------------------------
# Cloud electrification happens in the MIXED-PHASE region, where supercooled droplets, ice crystals and
# graupel coexist and collisional (non-inductive) charge transfer occurs. Measured in real storms at roughly
# -10 to -25 °C, with the main negative charge centre near -15 °C. It is a property of the riming process,
# NOT of the snow line, which is why the old "just above the snow line — warm-planet calibrated" comment was
# doubly wrong: it tied an atmospheric microphysics band to a fitted surface constant.
const CHARGE_ZONE_WARM_C: float = -10.0
const CHARGE_ZONE_COLD_C: float = -25.0

# --- ROCK / MAGMA -----------------------------------------------------------------------------------------
# Basalt, the ocean-floor and shield-volcano rock this planet mostly makes. Erupting basaltic lava is
# measured at 1100-1250 °C; it becomes fully solid below its solidus. "All magma is 1300 °C" is not a
# material property — magma temperature depends on composition and depth, and these two bracket the basaltic
# case rather than asserting a single value for everything molten.
const BASALT_LIQUIDUS_C: float = 1200.0
const BASALT_SOLIDUS_C: float = 1000.0

# --- PLANETARY INTERIOR -----------------------------------------------------------------------------------
# Earth's own geotherm. The inner core is solid iron at ~5200 °C and the core-mantle boundary sits near
# 3700 °C — the core is roughly FOUR TIMES hotter than erupting lava, which is why pinning this simulation's
# "core" at 1300 °C (an eruption temperature) made it a warm mantle, not a core.
const INNER_CORE_C: float = 5200.0
const CORE_MANTLE_BOUNDARY_C: float = 3700.0
const UPPER_MANTLE_C: float = 1300.0

# --- UPPER CRUST: THE GEOTHERM A SURFACE SIMULATION ACTUALLY NEEDS ------------------------------------------
# The core above is the wrong referent for the top few hundred metres of a shell. What sets ground
# temperature, spring temperature and where a geothermal reservoir sits is the NEAR-SURFACE GRADIENT, and it
# is a measured quantity with a wide, well-documented spread:
#   stable continental craton  ~ 20-25 °C/km   (the global continental average)
#   active volcanic province   ~ 50-100 °C/km  (Iceland, the Basin and Range, the Taupo Volcanic Zone)
# This planet is not a craton. It runs 3-5 eruptions and continuous plate activity per 80 simulated seconds,
# so 60 °C/km — a standard mid value for an active province — is the honest one to model it with. Cratonic 25
# is the alternative and would give a planet with no hot springs outside a magma body; that is also a real
# planet, just not this one. The choice is a claim about what kind of planet this is, and the eruption rate
# is the evidence for it.
const GEOTHERMAL_GRADIENT_C_PER_KM: float = 60.0

# Depth to which meteoric groundwater circulates before porosity closes under lithostatic load — the base of
# the permeable zone, and the bottom of every hot-spring and geyser system on Earth. Real range 1-3 km
# (deeper, 2-3 km, in the volcanic fields that make boiling springs); 2 km is the conservative mid value.
#
# WHY THIS IS HERE AND NOT JUST A NUMBER IN THE MODULE: it is what fixes this planet's vertical scale.
# LAMaterialFieldGeotherm3D reads it against the field's own REGOLITH band (the code's name for exactly this
# zone) to derive the vertical exaggeration, so the gradient above lands in model metres without anybody
# choosing a scale factor by eye — and it re-derives correctly at any grid resolution.
const GROUNDWATER_CIRCULATION_M: float = 2000.0

# --- THERMAL TRANSPORT ------------------------------------------------------------------------------------
# Conductivity lambda (W/m/K) and volumetric heat capacity rho*c (J/m^3/K) for the three materials this
# substrate conducts through, plus the diffusivity alpha = lambda/(rho*c) (m^2/s) they imply.
#
# THE TWO ORDERINGS ARE DIFFERENT, AND CONFUSING THEM IS HOW THIS KERNEL GOT FITTED. Heat flows with lambda:
# rock conducts about 100x better than air (2.5 against 0.026). TEMPERATURE spreads with alpha, and there air
# beats rock 21x (2.19e-5 against 1.03e-6), because air carries almost no heat per degree. A kernel that
# evolves temperature needs alpha; heat_sphere3d.glsl's old pair of numbers was neither, it was a pair fitted
# "so a 1300 C core coexists with a temperate surface".
#
# WHAT THESE NUMBERS SAY ABOUT THIS PLANET, stated once so nobody re-derives it: alpha_rock 1.03e-6 m^2/s
# means solid rock moves heat 1 metre in about 10 days and 1 kilometre in 30,000 years. Conduction through
# rock is NEGLIGIBLE on every timescale this simulation runs. A planet's interior heat does not reach its
# surface by conduction and never did — it rides magma. That is why the substrate has magma_buoy_sphere3d,
# and why replacing these with the real values makes the geothermal gradient an advective phenomenon instead
# of a conductive one.
#   basalt / crustal rock : lambda 2.5 (crustal rocks span 1.7-3.5), rho 2900, c 840
#   dry air, 300 K, 1 atm : lambda 0.026, rho 1.18, c_p 1005
#   liquid water, 300 K   : lambda 0.60,  rho 997,  c 4184
const THERMAL_CONDUCT_ROCK_W_MK: float = 2.5
const THERMAL_CONDUCT_AIR_W_MK: float = 0.026
const THERMAL_CONDUCT_WATER_W_MK: float = 0.60
const ROCK_DENSITY_KG_M3: float = 2900.0
const ROCK_SPECIFIC_HEAT_J_KGK: float = 840.0
const VOL_HEAT_CAP_ROCK_J_M3K: float = 2.436e6      # 2900 * 840
const VOL_HEAT_CAP_AIR_J_M3K: float = 1186.0        # 1.18 * 1005
const VOL_HEAT_CAP_WATER_J_M3K: float = 4.171e6     # 997 * 4184
const THERMAL_DIFFUSIVITY_ROCK_M2_S: float = 1.026e-6    # 2.5 / 2.436e6
const THERMAL_DIFFUSIVITY_AIR_M2_S: float = 2.192e-5     # 0.026 / 1186
const THERMAL_DIFFUSIVITY_WATER_M2_S: float = 1.438e-7   # 0.60 / 4.171e6

# --- RADIOGENIC HEATING -----------------------------------------------------------------------------------
# Heat produced per kilogram of silicate rock by the long-lived decay chains (238U, 235U, 232Th, 40K) at
# present-day bulk-silicate-Earth abundances. Over Earth's ~4e24 kg of mantle plus crust this is the ~20 TW
# radiogenic half of the planet's ~47 TW surface heat flow, and it is the ONLY reason a planetary interior is
# still hot after 4.5 Gyr — secular cooling alone would have run out. It scales with MASS while the loss
# scales with AREA, which is the whole reason small bodies are cold rock and large ones are molten inside.
const RADIOGENIC_W_PER_KG: float = 5.0e-12

# --- ENERGY BUDGET ----------------------------------------------------------------------------------------
# Solar irradiance at 1 AU, measured by satellite. Using the real number means the surface temperature is a
# PREDICTION of the model rather than an input to it: S/4 x (1 - albedo) against sigma x epsilon x T^4 lands
# an Earth-albedo planet at ~288 K on its own, with nothing fitted.
const SOLAR_CONSTANT_W_M2: float = 1361.0
const STEFAN_BOLTZMANN: float = 5.670374419e-8
const KELVIN_OFFSET: float = 273.15

# Mean geothermal heat flux out of Earth's surface, against ~340 W/m² of mean absorbed sunlight — a ratio
# near 1:4000. Any build where the interior is a comparable term to the sun has its crust conductivity wrong,
# and that measurement is the check for it.
const GEOTHERMAL_FLUX_W_M2: float = 0.087

# Greybody optical depth of a sea-level air column, back-derived from Earth's own greenhouse: a 288 K surface
# against a 255 K effective radiating temperature gives (288/255)^4 = 1.626 = 1 + 0.75*tau.
const ATMOS_OPTICAL_DEPTH: float = 0.835
const TWO_STREAM_COEFF: float = 0.75

# --- SURFACE ALBEDO ---------------------------------------------------------------------------------------
# Measured shortwave reflectance. Open ocean is one of the darkest natural surfaces; snow one of the
# brightest. (Earth's ~0.30 PLANETARY albedo includes clouds, which this substrate models separately, so the
# surface values belong here and the cloud contribution does not.)
const ALBEDO_OCEAN: float = 0.06
const ALBEDO_BARE_GROUND: float = 0.15
const ALBEDO_SNOW_ICE: float = 0.65

# --- COMBUSTION -------------------------------------------------------------------------------------------
# Piloted ignition temperature of dry cellulosic fuel (wood, leaf litter, cured grass).
const VEGETATION_IGNITION_C: float = 300.0

# HOW MUCH HEAT A FIRE RELEASES, WITHOUT NEEDING TO KNOW WHAT IS BURNING.
# Huggett (1980) measured that burning almost any organic fuel releases 13.1 MJ per KILOGRAM OF OXYGEN
# CONSUMED, within about 5 % across wood, cellulose, plastics and hydrocarbons — because the energy comes out
# of the O=O bond, not the fuel's. It is why oxygen-consumption calorimetry works, and it is the right anchor
# for this substrate: the field carries an `o2` channel with a defined ambient, and no bulk density for its
# `fuel` channel, so heat per unit oxygen is measurable here while heat per unit fuel is not.
#
# It replaced a THERMOSTAT. fire_sphere3d.glsl used to execute `if (temp < BURN_TEMP) temp = BURN_TEMP;` with
# BURN_TEMP = 640 — every burning cell on the planet was HELD at one temperature, so a fire in a swamp and a
# fire in dry litter read the same, and `ext_open_hot` in SIM_REPORT was pinned at exactly 640.0. A fire's
# temperature is a RESULT: the heat its combustion releases, against the heat capacity of what is burning,
# minus what it radiates away.
const HEAT_PER_KG_OXYGEN_J: float = 1.31e7

# The oxygen in a cell of ambient air, as a DENSITY — what a field value of `o2` = 1.0 (GasRecords.O2_AMBIENT)
# physically stands for. Dry air is 23.14 % oxygen by mass (standard composition) and sea-level air at 300 K is
# 1.18 kg/m³ — the same density VOL_HEAT_CAP_AIR_J_M3K above is built from, so the two agree by construction.
# 1.18 * 0.2314 = 0.2731 kg of O₂ per cubic metre of air.
const AIR_O2_MASS_FRACTION: float = 0.2314
const AMBIENT_O2_DENSITY_KG_M3: float = 0.2731

# The fraction of its heat release a wildland flame loses as RADIATION rather than keeping in its own plume.
# Measured at 0.2-0.4 for free-burning vegetation fires (the spread is mostly flame depth and soot loading);
# 0.30 is the mid value. This is the whole of flame SPREAD in this substrate: a burning cell radiates this
# share of its own combustion energy to the open cells around it, they warm, and the ones carrying fuel reach
# VEGETATION_IGNITION_C and light. There is no separate "ember" constant any more — spread is a property of
# the heat release, not a number of its own.
const FLAME_RADIATIVE_FRACTION: float = 0.30

# --- GROUNDWATER: PERMEABILITY IS GEOMETRY, NOT A MATERIAL NAME ---------------------------------------------
# Saturated hydraulic conductivity K spans roughly TWELVE orders of magnitude across geologic materials
# (Freeze & Cherry 1979, Table 2.2): gravel 1e-3..1 m/s, clean sand 1e-5..1e-2, silty sand 1e-7..1e-3,
# silt 1e-9..1e-5, marine clay 1e-13..1e-9. This substrate used ONE number, `CONDUCT = 0.35`, for all of it.
#
# The fix is not a table of material names. K is not a property of a name; it is a property of PORE GEOMETRY,
# and the Kozeny-Carman relation says exactly how:
#     k   = phi^3 * d^2 / (KOZENY_CARMAN_C * (1 - phi)^2)      [intrinsic permeability, m^2]
#     K   = k * rho_w * g / mu                                 [hydraulic conductivity, m/s]
# with phi the porosity and d the representative grain diameter. Kozeny (1927) / Carman (1937); the constant
# 180 is Carman's fit for packed granular beds. Substituting real regolith numbers reproduces the table above
# with nothing fitted: phi 0.35 with d = 0.5 mm gives 1.4e-3 m/s (coarse sand), d = 4 mm gives 8.8e-2 m/s
# (fine gravel), d = 0.05 mm gives 1.4e-5 m/s (silty sand). One relation, the whole range.
const KOZENY_CARMAN_C: float = 180.0
const GRAVITY_M_S2: float = 9.81
const WATER_DYNAMIC_VISCOSITY_PA_S: float = 1.002e-3    # liquid water at 20 °C

# Porosity of unconsolidated near-surface granular deposits, and how it CLOSES with burial. Freeze & Cherry
# put sand and gravel at 0.25-0.50; 0.40 is the mid value for a loose, poorly-sorted weathering mantle. Athy
# (1930) established that porosity decays exponentially with depth as the overburden compacts the grain pack,
# phi(z) = phi_0 * exp(-z / z_c); Sclater & Christie (1980) fit z_c = 3.7 km for sandstone and 2.0 km for
# shale. 2.5 km is the granular-clastic mid value, and over this planet's 2 km circulating zone it closes
# porosity from 0.40 to 0.18 — the reason the water table is a table and not a uniform sponge.
const REGOLITH_SURFACE_POROSITY: float = 0.40
const COMPACTION_LENGTH_M: float = 2500.0

# The grain sizes the regolith is made of, as sieve diameters (Wentworth scale). The planet does not carry a
# lithology map, so what it varies K with is the one thing it does know and that really does sort grain size:
# where the material SITS. Coarse sand and gravel accumulate as valley-fill alluvium where running water drops
# its bedload; upland regolith is residual saprolite, weathered in place and fine. Alluvial valley aquifers
# being the coarse, productive ones and upland residuum the tight one is standard hydrogeology (Freeze &
# Cherry ch. 4), and it puts the permeable rock exactly where the springs are.
const GRAIN_D_UPLAND_M: float = 6.0e-5      # 0.06 mm — very fine sand / coarse silt (residual saprolite)
const GRAIN_D_LOWLAND_M: float = 4.0e-3     # 4 mm — fine gravel (valley-fill alluvium)

# --- GRANULAR MECHANICS: THE ANGLE OF REPOSE ------------------------------------------------------------------
# Added 2026-08-09. The steepest slope a pile of DRY, COHESIONLESS grains stands at before it avalanches. It is a
# measured property of the material — grain friction, angularity and interlock decide it, not how the pile was
# built — and it is why every dune, scree cone, spoil heap and hourglass pile of one material has the same face
# angle. Measured: dry sand 30-35 deg, angular gravel and crushed rock 35-40, smooth glass beads ~24, wet or
# cohesive material higher and not this number at all (Beakawi Al-Hashemi & Baghabra Al-Amoudi 2018, "A review of
# the angle of repose of granular materials", Powder Technology 330:397; Carrigy 1970 on natural sands). 35 deg is
# the standard value for the dry sand-and-gravel mixture this substrate's `sediment` channel represents, and it
# sits in the overlap of both ranges.
#
# THE TANGENT IS WHAT IS DECLARED, because a slope threshold on a grid is a RISE OVER A RUN and that is the form
# the property enters in. tan(35 deg) = 0.7002; atan(0.70) = 34.99 deg. Two decimals, deliberately: the underlying
# measurement is a 30-37 deg band, and +-3 deg is +-0.07 in tangent, so a third decimal would assert a precision
# the material does not have.
#
# WHAT IT REPLACED: nothing at all. `slump_sphere3d.glsl:38` carried `REPOSE_TAN = 0.70` as a bare literal whose
# only stated authority was "MUST match MaterialSlump3D.gd", a file deleted with the CPU oracle — so a value
# HANDOFF.md lists as settled had no checkable source. Sourcing it does not make the substrate's use of it
# correct: the kernel compares a mass difference against this tangent, which is only a slope if a cell is as wide
# as it is tall, and on the shipped cubed-sphere grid it is not. See the note at that line.
const REPOSE_TAN_DRY_GRANULAR: float = 0.70


## Saturation vapour density as a FRACTION OF A CELL FULL OF LIQUID WATER — the substrate's own unit.
## This is the phase rule's whole content: it is how much water air at `t_c` can hold, and nothing else may
## decide that. Liquid evaporates while the local air is below it and the excess above it is condensate.
## 1.95e-5 at 22 °C, 5.99e-4 at 100 °C (where e_sat reaches 1 atm and the liquid boils — no BOIL branch needed).
static func saturation_mass_fraction(t_c: float) -> float:
	var t: float = maxf(t_c, -80.0)    # the Magnus fit is stated over -40..+50 and its pole is at -243.04 °C
	var e_sat: float = MAGNUS_A_PA * exp(MAGNUS_B * t / (t + MAGNUS_C_C))
	var rho_v: float = e_sat / (VAPOUR_GAS_CONST_J_KGK * maxf(t + KELVIN_OFFSET, 1.0))
	return rho_v / WATER_DENSITY_KG_M3
# --- LIVING TISSUE ----------------------------------------------------------------------------------------
# Soft animal tissue is mostly water, and its bulk density is measured within a few percent of water's:
# muscle ~1060, fat ~920, whole-body ~1010 kg/m³. 1000 is the honest round value and it is why an animal
# floats or sinks only marginally. This is what turns a body's LINEAR size into a MASS, which is the only
# reason metabolism can scale with anything at all.
const ANIMAL_TISSUE_DENSITY_KG_M3: float = 1000.0

# THE TWO TEMPERATURES THAT BOUND LIFE, and they are properties of matter, not of a species.
#   * Below the freezing point of water, intracellular water crystallises and the cell's chemistry stops.
#     That bound is WATER_FREEZE_C above — the SAME 0 °C, not a second constant.
#   * Above ~45 °C the structural and enzymatic proteins of animals begin to denature irreversibly. This is
#     the measured onset of thermal protein unfolding for mammalian proteins (heat-shock response begins
#     ~41-43 °C; gross denaturation and thermal death follow by ~45-50 °C), and it is why the upper lethal
#     temperature of animals is so tightly clustered whatever their habitat: a desert beetle and an arctic
#     fox are built from proteins with the same peptide chemistry.
# Together they bracket the temperature range in which animal metabolism can run at all. A per-species
# "comfort band" is not needed to express this and never was: what differs between a beetle and a fox is
# not the chemistry's limits, it is whether the animal spends energy holding its body away from ambient.
const PROTEIN_DENATURE_C: float = 45.0

# HEAT OF COMBUSTION OF BIOMASS — one material, one number.
#
# WHAT IT IS A PROPERTY OF: the organic matter this substrate is made of, which its own chemistry writes as
# CH₂O — carbohydrate — in the photosynthesis/respiration identity R19/R20 (see LABioRecords). Measured heats
# of combustion: carbohydrate 16.7 MJ/kg (Atwater, 4 kcal/g), cellulose 17.5, dry cellulosic fuel 18-19
# (higher because of lignin), fat 39, protein 17. 17 MJ/kg is the carbohydrate value and the one the
# substrate's own formula commits it to.
#
# IT USED TO BE DECLARED TWICE, AT TWO VALUES, AND THAT IS THE DRIFT PATTERN THAT FROZE WATER AT 12.5 °C.
# `BIOMASS_HEAT_OF_COMBUSTION_J_PER_KG = 1.7e7` (carbohydrate, cited to the respiration identity) and
# `BIOMASS_HEAT_OF_COMBUSTION_J_KG = 1.8e7` (dry cellulosic, cited to forest fuels) sat 160 lines apart in
# this file after two branches added one each. In this substrate `biomass` and `fuel` are the SAME material
# in different states — a standing plant and the cured litter it becomes — so they cannot have two heats of
# combustion. Resolved to the carbohydrate value, because that is the molecule the reaction table says the
# material is; the 1 MJ/kg difference is inside the measurement spread for plant matter either way.
#
# NOTHING READS IT YET, AND THAT IS ALSO TRUE OF BOTH THE CONSTANTS IT REPLACED. The fire kernel's heat is
# `EMBER_HEAT`, a °C throw, and `LAMaterialFieldBiota3D.HEAT_C_PER_MASS` is a unit conversion; neither
# derives its heat from the fuel it consumes. Binding those to this constant is a real physics change to the
# fire and thermal balance and is NOT done here. NO KERNEL COPIES THIS CONSTANT TODAY — grep says so, and it
# was true of both the names it replaces. scripts/check_physical_constants.sh already binds any copy that
# carries a `// LAPhysical.BIOMASS_HEAT_OF_COMBUSTION_J_PER_KG` comment (its rule 1, an explicit reference is
# a binding contract), so the first kernel to want this value is checked against it. What is NOT covered is a
# kernel adding an unannotated heat-of-combustion constant: the name heuristic (rule 2) watches the water
# phase points and the charge band only, and widening it is a separate change to the gate.
const BIOMASS_HEAT_OF_COMBUSTION_J_PER_KG: float = 1.7e7

# Specific heat of animal tissue — again mostly water, measured ~3500 J/kg/K against water's 4184 (tissue is
# ~70% water plus solids of lower heat capacity). This sets how much a given metabolic heat output actually
# RAISES body temperature, and with the mass/area ratio it is what makes a small body track its surroundings
# within minutes while a large one holds its own temperature for hours.
const ANIMAL_SPECIFIC_HEAT_J_KGK: float = 3500.0
# --- UNIVERSAL CONSTANTS ------------------------------------------------------------------------------------
const STANDARD_GRAVITY_M_S2: float = 9.80665        # CGPM-defined standard gravity
const GAS_CONSTANT_J_MOL_K: float = 8.314462618     # CODATA molar gas constant R
const SECONDS_PER_YEAR: float = 3.15576e7           # Julian year, 365.25 days

# --- MOLAR MASSES (IUPAC 2021 standard atomic weights) ------------------------------------------------------
# Added 2026-08-07 because the conservation gate needed them and did not have them. It declares each channel
# as "the ELEMENTS one unit of it contains" and holds molecular FORMULAS, which are elements per MOLE — the
# two agree only if one channel unit is one mole for every channel, and they are not even close: one unit of
# `o2` is the O₂ in a cell of ambient air (8.5 mol/m³) and one unit of `water` is a cell FULL of liquid water
# (55343 mol/m³), a factor of 6484. Converting between a channel unit and moles is the missing step, and it
# cannot be done without these.
#
# They also fix a second instance of the same confusion. LITTER_C_TO_N is a MASS ratio, and the composition
# table spends it as a mole count (`N: 1.0 / LITTER_C_TO_N` = 0.0500). Nitrogen per mole of CH₂O is
# (CARBON_MOLAR_MASS / LITTER_C_TO_N) / NITROGEN_MOLAR_MASS = 0.0429 — 16% lower.
const MOLAR_MASS_WATER_KG_MOL: float = 0.018015     # H₂O
const MOLAR_MASS_O2_KG_MOL: float = 0.0319988       # O₂
const MOLAR_MASS_CO2_KG_MOL: float = 0.0440095      # CO₂
const MOLAR_MASS_CARBON_KG_MOL: float = 0.0120110   # C
const MOLAR_MASS_NITROGEN_KG_MOL: float = 0.0140067  # N
# CH₂O — the EMPIRICAL FORMULA UNIT of a carbohydrate, not any actual carbohydrate. Glucose is C₆H₁₂O₆ at
# 0.180156 kg/mol and cellulose is a polymer of it; this is one sixth of that, the per-carbon unit
# LAReactionBalance.composition() models all organic matter as so that photosynthesis and respiration
# balance as CO₂ + H₂O <-> CH₂O + O₂. Naming it "carbohydrate" would be six times wrong for glucose.
const MOLAR_MASS_CH2O_UNIT_KG_MOL: float = 0.0300260

# --- THE THREE MINERAL SPECIES, AND WHY THE ROCK NEEDED A CHEMISTRY -----------------------------------------
# Added 2026-08-08. Until then every mineral phase in the substrate — bedrock, lava, loose sediment, airborne
# dust, waterborne suspension — was declared as one lumped mass `M` with no stoichiometry, and the reason given
# was that "nothing converts between M and C/H/O/N". That was circular: it was true only because chemical
# weathering was written with WATER as its driver and CO2 as a second driver, both CATALYSTS, consumed by
# neither. The real reaction consumes CO2 and locks it in carbonate rock:
#     CaSiO3 + CO2 -> CaCO3 + SiO2
# — the net Urey reaction, the long-term carbon sink that has regulated Earth's climate for four billion
# years. A lumped mineral mass cannot express it, so the rock gets a chemistry.
#
# THE STANDARD PETROLOGICAL TRIPLE that every carbon-cycle model uses:
#   silicate  CaSiO3  wollastonite, the standard proxy for the calcium silicate the mantle makes
#                     (Walker, Hays & Kasting 1981, and every long-term carbon-cycle model since)
#   silica    SiO2    quartz — the weathering residue, which does not weather further
#   carbonate CaCO3   calcite — where weathered carbon goes, and the only place it can go
#
# MOLAR MASSES from the IUPAC 2021 standard atomic weights used above (Ca 40.078, Si 28.085, O 15.9994,
# C 12.011), so they cannot drift from MOLAR_MASS_CARBON_KG_MOL and its siblings.
const MOLAR_MASS_CASIO3_KG_MOL: float = 0.1161612    # CaSiO3  40.078 + 28.085 + 3*15.9994
const MOLAR_MASS_SIO2_KG_MOL: float = 0.0600838      # SiO2    28.085 + 2*15.9994
const MOLAR_MASS_CACO3_KG_MOL: float = 0.1000872     # CaCO3   40.078 + 12.011 + 3*15.9994
# DENSITIES of the two new species, measured crystal densities of the named minerals. The silicate species has
# NO density constant of its own on purpose: wollastonite measures 2.86-3.09 g/cm^3 and ROCK_DENSITY_KG_M3
# above is 2900, inside that range and already the substrate's one crustal-rock density. Declaring a second
# number for the same physical quantity is exactly the drift this file exists to prevent.
const QUARTZ_DENSITY_KG_M3: float = 2650.0           # alpha-quartz, 2.65 g/cm^3
const CALCITE_DENSITY_KG_M3: float = 2710.0          # calcite, 2.71 g/cm^3

# --- METAMORPHIC DECARBONATION: THE RETURN LEG OF THE CARBON CYCLE ------------------------------------------
# A sink with no source strips an atmosphere. The Urey reaction runs BACKWARDS when the rock gets hot —
#     CaCO3 + SiO2 -> CaSiO3 + CO2
# — which is the wollastonite-forming reaction of contact and regional metamorphism, and it is how subducted
# and buried limestone returns its carbon to the air. Volcanic CO2 outgassing is this reaction, not a separate
# mechanism, so the substrate gets it as a record rather than as a scripted emission.
#
# ITS TEMPERATURE IS DERIVED, NOT PICKED. At equilibrium dG = 0, so T_eq = dH / dS, from the standard-state
# enthalpies and entropies of the four phases (Robie & Hemingway; CODATA for CO2):
#   dH = (-1634.9 - 393.51) - (-1207.6 - 910.7) = +89.89 kJ/mol
#   dS = ( 81.69 + 213.79) - (  91.7 +  41.46) = +162.32 J/mol/K
#   T_eq = 89890 / 162.32 = 553.8 K = 280.7 C
# at one bar of CO2. Real metamorphic rocks cross the wollastonite isograd higher than this (500-600 C at
# crustal pressure, because P raises T_eq) and lower where H2O dilutes the fluid; the one-bar value is the
# right one for a substrate whose reacting cells are open to the atmosphere.
const CALCITE_QUARTZ_DECARB_ENTHALPY_J_MOL: float = 89890.0
const CALCITE_QUARTZ_DECARB_ENTROPY_J_MOL_K: float = 162.32
const DECARBONATION_TEMP_C: float = 280.7     # 89890 / 162.32 - 273.15

# --- WATER AND ICE DENSITY: WHY ROCK SHATTERS WHEN IT FREEZES -----------------------------------------------
# Water is one of very few substances that EXPANDS on freezing, and that expansion is the entire mechanism of
# frost weathering. At 0 C and 1 atm liquid water is 999.84 kg/m^3 and ice Ih is 916.7, so a given mass of
# water occupies 999.84/916.7 = 1.0907 times the volume once frozen. In a confined pore that surplus volume
# has to come out of the surrounding rock, which is what breaks it.
#
# NOTE the 0 C liquid density is its own constant and is NOT WATER_DENSITY_KG_M3 above, which is the 25 C
# value the field uses as its cell-fill denominator. Freezing happens at 0 C, so that is the temperature the
# expansion has to be quoted at; the two differ by 0.3 % and conflating them would be a small lie in the one
# place where the whole mechanism is a density difference.
const WATER_DENSITY_0C_KG_M3: float = 999.84
const ICE_DENSITY_KG_M3: float = 916.7
const ICE_FREEZE_EXPANSION: float = 0.0907          # 999.84/916.7 - 1

# Porosity of NEAR-SURFACE crustal rock: the fraction of its volume that is pore and microfracture space, and
# therefore the fraction that can hold the water frost weathering needs. Intact crystalline basalt measures
# 0.5-3 %; the weathered, microfractured skin of an outcrop — which is the material that actually shatters —
# runs 5-15 %. 0.05 is the bottom of the weathered range, i.e. the conservative end for a number that sets an
# upper bound on a rate.
const ROCK_POROSITY_NEAR_SURFACE: float = 0.05

# --- CHEMICAL WEATHERING: SILICATE DISSOLUTION --------------------------------------------------------------
# Apparent activation energy of silicate mineral dissolution, the reaction that chemically weathers rock.
# Laboratory and field values for plagioclase feldspar and basaltic glass cluster at 50-90 kJ/mol (White &
# Brantley's compilations); 60 kJ/mol sits mid-range for basalt. It is what makes weathering roughly DOUBLE
# per +10 C near room temperature — exp((Ea/R)(1/298.15 - 1/308.15)) = 2.2 — so that textbook rule of thumb is
# a consequence of this number rather than something anyone typed in.
const SILICATE_DISSOLUTION_EA_J_MOL: float = 60000.0
const SILICATE_DISSOLUTION_EA_OVER_R_K: float = 7216.9    # 60000 / 8.314462618, in kelvin
# The temperature laboratory dissolution rates are quoted at. Arrhenius needs a reference point; this is the
# standard one, and it is a property of the measurement, not of the rock.
const LAB_REFERENCE_TEMP_C: float = 25.0

# --- LITHIFICATION: A PRESSURE, NOT A DEPTH -----------------------------------------------------------------
# Sediment becomes rock by COMPACTION and CEMENTATION under the weight of what buries it. The stress that does
# it is the weight of the SOLID overburden only: by Terzaghi's effective-stress principle pore fluid carries
# its own weight and does not compact the grain framework, which is why a sediment bed under 4 km of ocean is
# not lithified by the water above it.
#
# GROUNDWATER_CIRCULATION_M above is already defined as the depth "to which meteoric groundwater circulates
# before POROSITY CLOSES UNDER LITHOSTATIC LOAD". Porosity closing IS lithification, so the same 2 km sets the
# threshold and no second number is introduced:
#     P = ROCK_DENSITY_KG_M3 * STANDARD_GRAVITY_M_S2 * GROUNDWATER_CIRCULATION_M
#       = 2900 * 9.80665 * 2000 = 5.688e7 Pa (56.9 MPa)
# which is the right order for the onset of pervasive cementation in real basins (1-3 km, 20-70 MPa).
const LITHIFICATION_PRESSURE_PA: float = 5.688e7
# Bulk density of unconsolidated wet sediment (sand and mud), measured range 1600-2200 kg/m^3. It is lower
# than rock because sediment is a grain framework with water in the pores — which is exactly why a sediment
# pile has to be thicker than a rock pile to reach the same overburden pressure.
const SEDIMENT_DENSITY_KG_M3: float = 2000.0

# --- PLATE MOTION -------------------------------------------------------------------------------------------
# Present-day plate speeds from space geodesy (GPS/VLBI, and the NUVEL/MORVEL plate-motion models): 10-100
# mm/yr. The fast oceanic plates (Pacific, Nazca, Cocos) run 70-100; the slow continental ones (Eurasia,
# Africa, Antarctica) run 10-25. These are the two ends of the real distribution, and LAPlateTectonics draws
# each plate's speed from between them instead of from a made-up angular rate.
const PLATE_SPEED_MIN_MM_PER_YEAR: float = 10.0
const PLATE_SPEED_MAX_MM_PER_YEAR: float = 100.0
# --- THE COMPOSITION OF AIR -------------------------------------------------------------------------------
# Dry-air mole fractions. N₂ and O₂ are fixed properties of the atmosphere; Ar is next and is inert; CO₂ is
# the 2023 NOAA global annual mean (419 ppm) and is the only one of the four that moves on a human timescale.
#
# WHY THESE ARE HERE AND WHAT THEY REPLACED. This simulation had no atmosphere. `_o2` was filled to a
# constant 1.0 and `_co2` was `resize()`d with NO `.fill()` at all — clean air with zero carbon in it — and
# both were then held near a target by a reaction record with NO REACTANT, so the product credit ran and
# nothing was ever debited. Every carbon atom that has ever existed in this simulation was conjured by that
# one record, at a measured +6.5 units per field step, and `carbon_total` had grown from 720 to about 5820
# over a 600-frame run. A planet does not manufacture its own air: it was assembled with an atmosphere and
# has been rearranging it ever since. These four numbers are what "assembled with an atmosphere" means.
#
# THE ABSOLUTE UNIT IS A FREE CHOICE; THE RATIOS ARE THE PHYSICS. The substrate's gas channels are in an
# arbitrary substance unit, and one unit is DEFINED as the amount of O₂ in a cell of ambient air — which is
# what `LAMaterialField3D.O2_AMBIENT = 1.0` already meant, and keeps every existing O₂ threshold
# (CreatureMetabolism.BREATHE_MIN_O2 0.3, fire_sphere3d O2_MIN 0.35) valid. Everything else in the air
# follows from that choice by its mole fraction, with nothing left to tune. In particular CO₂ per cell is
# O2_AMBIENT x (AIR_MOLE_FRAC_CO2 / AIR_MOLE_FRAC_O2) = 0.00200, which is 25x SMALLER than the 0.05 "ambient
# trace" the deleted record relaxed toward. That 0.05 was not a measurement of anything; the ratio is.
const AIR_MOLE_FRAC_N2: float = 0.78084     # NASA/NOAA standard atmosphere, dry air
const AIR_MOLE_FRAC_O2: float = 0.20946
const AIR_MOLE_FRAC_AR: float = 0.00934
const AIR_MOLE_FRAC_CO2: float = 0.000419   # NOAA GML global annual mean, 2023

# --- ORGANIC MATTER: THE CARBON-TO-NITROGEN RATIO ---------------------------------------------------------
# Measured mass ratios of carbon to nitrogen. They are properties of the material, and they are what makes
# "mineralisation releases the nitrogen that was ALREADY in the litter" a structural fact instead of a
# coincidence between two constants somebody set equal by hand: the nitrogen a decomposer releases, and the
# nitrogen a plant takes up to build the same tissue, are the SAME ratio because they are the same matter.
# Fresh leaf litter runs 20-60:1 depending on species; well-humified soil organic matter converges near 10-12:1
# (Batjes 1996). 20 is the litter figure this substrate's detritus channel represents.
const LITTER_C_TO_N: float = 20.0
const SOIL_ORGANIC_C_TO_N: float = 12.0
# ============================================================================================================
# SURFACE ENERGY BALANCE — added 2026-08-03 by the conservation repair of the solar/buoyancy/conduction chain.
# Appended as one contiguous block because four lanes were editing this file the same day.
# ============================================================================================================

# --- SHORTWAVE IS NOT LONGWAVE, AND THE DIFFERENCE *IS* THE GREENHOUSE --------------------------------------
# ATMOS_OPTICAL_DEPTH above (0.835) is the LONGWAVE greybody depth of a sea-level air column. Reusing it for
# sunlight would be a physical error, not an approximation: an atmosphere that absorbed 57% of the incoming
# beam and 57% of the outgoing infrared would have no greenhouse effect at all. The whole mechanism is that
# air is nearly transparent to the visible and nearly opaque to the thermal infrared, so the two optical
# depths are separate measured quantities.
#
# Earth's atmosphere absorbs 78 W/m^2 of the 341 W/m^2 arriving at the top of the atmosphere — 22.9%
# (Trenberth, Fasullo & Kiehl 2009, "Earth's Global Energy Budget", BAMS 90:311). A Beer-Lambert vertical
# path reproducing that absorption has tau = -ln(1 - 0.2287) = 0.2597.
const ATMOS_SW_OPTICAL_DEPTH: float = 0.2597

# Relative optical air mass at a 90 deg zenith angle. The naive slant path 1/cos(z) diverges at the horizon;
# the real one saturates near 38 because the atmosphere is a curved shell, not a slab (Kasten & Young 1989,
# "Revised optical air mass tables and approximation formula", Applied Optics 28:4735). It is what bounds the
# terminator's air mass instead of an arbitrary epsilon.
const AIR_MASS_HORIZON: float = 38.0

# --- WATER: DENSITY AND THE LATENT HEAT OF VAPORISATION ------------------------------------------------------
# Liquid water at 300 K. The latent heat is at 100 C / 1 atm. Their ratio to water's specific heat is the
# number that makes boiling such a violent heat sink: L/c = 2.257e6 / 4184 = 539 K. Flashing a hundredth of a
# cell's water to steam costs the same sensible heat as cooling that water by 5.4 K, which is why a boiling
# spring pins itself at 100 C and why seawater quenches lava to pillow basalt in seconds.
# (WATER_DENSITY_KG_M3 is declared once at the top of this file — 997.0, liquid water at 300 K — so the
# duplicate that stood here on the conservation branch is dropped rather than shadowed.)
const LATENT_HEAT_VAPORISATION_J_KG: float = 2.257e6

# --- SNOW -----------------------------------------------------------------------------------------------------
# Settled seasonal snowpack: rho 300 kg/m^3 (fresh fall 50-100, settled 200-400, firn 500+), c 2090 J/kg/K
# (ice), lambda 0.15 W/m/K (measured range 0.05-0.5 with density; 0.15 is the settled-pack value). The
# conductivity is why a snow blanket keeps the soil under it above freezing.
const VOL_HEAT_CAP_SNOW_J_M3K: float = 6.27e5       # 300 * 2090
const THERMAL_CONDUCT_SNOW_W_MK: float = 0.15
# ============================================================================================================
# APPENDED 2026-08-03 — the energies a conserving substrate needs, so a deposit of heat can name what it came
# out of instead of being conjured. Each is a measured property of the real process, cited the same way as
# everything above it.
# ============================================================================================================

# --- LIGHTNING --------------------------------------------------------------------------------------------
# Total energy dissipated by one negative cloud-to-ground flash. Measured flashes span roughly 1-5 GJ
# (a ~5 C charge transfer across a ~100 MV potential difference, plus the return-stroke sequence); 1 GJ is
# the conservative low end and the value usually quoted for a "typical" flash.
#
# THIS IS A PROPERTY OF THE DISCHARGE, NOT A TUNING KNOB FOR HOW HOT THE GROUND GETS. What the substrate does
# with it is arithmetic: E / (heat capacity of the cells the channel spans). That is why a bolt in this model
# now heats AIR strongly and wet ground barely, and why a bolt with no accumulated charge behind it delivers
# nothing at all. The number this replaced was a flat `STRIKE_HEAT = 900` °C added to every cell in a radius,
# which is heat created from nothing at a rate set by nothing.
const LIGHTNING_FLASH_J: float = 1.0e9

# --- HEAT OF COMBUSTION -----------------------------------------------------------------------------------
# `BIOMASS_HEAT_OF_COMBUSTION_J_KG = 1.8e7` STOOD HERE AND IS DELETED. It was the same physical quantity as
# BIOMASS_HEAT_OF_COMBUSTION_J_PER_KG above under a second name at a second value — `fuel` and `biomass` are
# one material in two states here — which is exactly how the freezing point of water ended up declared in
# five places at three values. See the note on the surviving constant for which value won and why.

# --- CARBON CONTENT OF DRY PLANT MATTER --------------------------------------------------------------------
# Dry plant biomass is close to half carbon by mass — measured at 45-50% across woody and herbaceous species,
# with 0.47 the value the IPCC uses for forest carbon accounting. The substrate's `biomass` channel and its
# `fuel` channel are the SAME material in different states (standing vegetation, and the flammable litter it
# becomes), so converting between them is a change of state, not a change of substance, and must move mass
# one-for-one rather than manufacture it.
const BIOMASS_CARBON_FRACTION: float = 0.47
# ============================================================================================================
# APPENDED 2026-08-07 — THE ENERGY OF A PHASE CHANGE, and the oxygen a flame needs.
#
# Every phase transition in this substrate moves mass between two states of one substance, and every one of
# them costs or releases a measured enthalpy. Exactly ONE was ever charged — vaporisation, at the boiling
# point, by heat3d_cool_sphere3d.glsl, at a rate that "MUST match atmos_evap_sphere3d.glsl", a file that had
# already been deleted. So water could freeze, melt, sublimate and deposit for free, basalt could crystallise
# for free, and rock could melt for free. These are properties of the materials. They are not rates, and the
# rate a transition proceeds at is a separate question answered by the record that performs it.
# ============================================================================================================

# --- WATER: FUSION AND SUBLIMATION --------------------------------------------------------------------------
# The two enthalpies the water cycle was missing; LATENT_HEAT_VAPORISATION_J_KG above is the third.
#
# FUSION, at 0 °C and 1 atm. Against water's specific heat the ratio is L_f/c = 3.337e5 / 4184 = 79.8 K, so
# freezing a hundredth of a cell's water releases the heat of warming that water by 0.8 K. Small beside
# vaporisation and not negligible: it is why a lake sits near 0 °C for weeks while it freezes instead of
# dropping straight through, and why a snowpack survives the first warm afternoon.
const LATENT_HEAT_FUSION_J_KG: float = 3.337e5

# SUBLIMATION, ice directly to vapour at 0 °C. By Hess's law it is the sum of the other two AT THAT
# TEMPERATURE — 2.501e6 (vaporisation at 0 °C) + 3.337e5 — which is why it is stated rather than derived
# from the 2.257e6 above: that figure is quoted at 100 °C, and adding a 100 °C vaporisation to a 0 °C fusion
# would be adding two numbers that describe different temperatures. A sublimating snowpack pays the full
# 2.834e6, which is why alpine sublimation is a large share of ablation.
const LATENT_HEAT_SUBLIMATION_J_KG: float = 2.834e6

# --- BASALT: THE ENTHALPY OF CRYSTALLISATION ----------------------------------------------------------------
# Released when basaltic melt crystallises through its solidus, absorbed again when rock melts. Measured at
# 3.5-5e5 J/kg across basaltic compositions (Lange, Cashman & Navrotsky 1994, Contrib Mineral Petrol 118:169);
# 4e5 is the value Turcotte & Schubert's Geodynamics uses. Against rock's specific heat that is 4.0e5 / 840 =
# 476 K — comparable to the whole sensible heat of a flow between its liquidus and the surface. It is what
# makes a lava flow crust over and hold its interior molten, rather than cooling smoothly to ambient.
const BASALT_LATENT_HEAT_CRYSTALLISATION_J_KG: float = 4.0e5

# --- BASALT: THERMAL-INFRARED EMISSIVITY ---------------------------------------------------------------------
# A lava surface is very nearly a blackbody in the thermal infrared: 0.95-0.98 measured on fresh basalt
# (Ball & Pinkerton 2006, J Geophys Res 111:B11203, on the emissivity assumptions thermal cameras make in
# volcanology). This is what an exposed molten cell radiates WITH. It replaces a Newtonian relax toward a
# prescribed 40 °C ambient, which deleted the heat instead of emitting it — no cell received it, and the
# planet's energy books could not see it leave.
const BASALT_EMISSIVITY: float = 0.95

# --- THE LIMITING OXYGEN CONCENTRATION -------------------------------------------------------------------------
# The minimum oxygen MOLE FRACTION that sustains flaming combustion of cellulosic fuel — measured near
# 0.13-0.16 for wood and cellulose (ASTM D2863 oxygen-index method; Babrauskas, Ignition Handbook, 2003).
# 0.15 is the mid value. Below it a flame goes out however hot it is, which is why a fire in a sealed room
# self-extinguishes long before the oxygen is gone, and why an anoxic planet cannot burn.
#
# IT IS A PROPERTY OF THE FUEL AND THE OXIDISER, NOT A DIFFICULTY SETTING. The O₂ channel is in units of
# modern ambient air (see AIR_MOLE_FRAC_O2), so a kernel comparing against it wants
# LIMITING_OXYGEN_CONCENTRATION_FRAC / AIR_MOLE_FRAC_O2 = 0.716 channel units.
const LIMITING_OXYGEN_CONCENTRATION_FRAC: float = 0.15
# ============================================================================================================
# APPENDED 2026-08-08 — the measured properties LASubstances needs to describe each material completely.
#
# These are not new physics. Most were already in this substrate as bare literals inside a kernel, bound to
# nothing, or implied by a volumetric heat capacity that had already multiplied a density and a specific heat
# together so neither could be read back out. A substance table needs them separately, because a material's
# density and its specific heat are two different facts about it.
# ============================================================================================================

# --- SPECIFIC HEATS (J/kg/K), the per-mass companions of the VOL_HEAT_CAP_* above ---------------------------
# The volumetric figures are rho*c products: VOL_HEAT_CAP_WATER_J_M3K = 997 * 4184. Storing only the product
# means a cell that is half water cannot be given the right capacity without dividing by a density that was
# never written down. These are the c's.
const WATER_SPECIFIC_HEAT_J_KGK: float = 4184.0     # liquid water, 25 C
const ICE_SPECIFIC_HEAT_J_KGK: float = 2090.0       # ice at 0 C — HALF liquid water's, which is why a snowpack
                                                    # swings temperature so much faster than a lake
const VAPOUR_SPECIFIC_HEAT_J_KGK: float = 1996.0    # water vapour at constant pressure, 100 C
const AIR_SPECIFIC_HEAT_J_KGK: float = 1005.0       # dry air at constant pressure, 300 K

# --- WATER: VAPORISATION AT 0 C ------------------------------------------------------------------------------
# A DIFFERENT NUMBER from LATENT_HEAT_VAPORISATION_J_KG above, which is quoted at 100 C. The latent heat of
# vaporisation falls with temperature — the standard linear fit L_v(T) = 2.501e6 - 2361*T_C reproduces the
# boiling-point figure to 0.35% — so a substrate that evaporates at ambient temperature and boils at 100 C is
# reading two points on one curve.
#
# IT EXISTS BECAUSE ITS ABSENCE BROKE HESS'S LAW IN SHIPPED CODE. A closed cycle water -> vapour -> snow ->
# water nets to zero only if L_sub = L_vap + L_fus AT ONE TEMPERATURE. Pairing the 100 C vaporisation with the
# 0 C fusion and sublimation left 2.257e6 + 3.337e5 = 2.591e6 against 2.834e6 — short by 2.433e5 J/kg, and
# every traverse of that loop released the difference from nothing while its mirror absorbed it.
# LASubstances derives sublimation as the sum rather than declaring it, so the three can no longer disagree.
const LATENT_HEAT_VAPORISATION_0C_J_KG: float = 2.501e6

# --- EMISSIVITY -----------------------------------------------------------------------------------------------
# Thermal-infrared emissivity of a water surface. Near-blackbody, which is why the ocean radiates so
# efficiently and why sea-surface temperature can be measured from orbit at all.
const EMISSIVITY_WATER: float = 0.96

# --- DRY WOOD / CELLULOSIC FUEL -------------------------------------------------------------------------------
# Oven-dry softwood: 400-600 kg/m3 across species (denser hardwoods reach 900); 500 is the mid value for the
# conifer and grass litter that carries a wildfire. Specific heat of dry wood is 1300-1700 J/kg/K over normal
# temperatures.
const DRY_WOOD_DENSITY_KG_M3: float = 500.0
const DRY_WOOD_SPECIFIC_HEAT_J_KGK: float = 1500.0

# THE ACTIVATION ENERGY OF CELLULOSE PYROLYSIS, AND WHY IT REPLACES AN IGNITION TEMPERATURE.
# A solid fuel has no ignition point the way water has a freezing point. It pyrolyses — heat drives off
# combustible volatiles at a rate that rises exponentially with temperature — and "ignition" is the name for
# the moment that release outruns the losses. The threshold quoted in handbooks (300 C piloted, 400-500 C
# unpiloted for wood) is an artefact of the apparatus it was measured in: it moves with moisture content,
# particle size, oxygen concentration and exposure time, none of which a single constant can carry.
#
# What IS a property of the material is the activation energy. Cellulose pyrolysis is measured at
# 200-250 kJ/mol by thermogravimetry (Antal & Varhegyi 1995 review the spread and its causes); 230 kJ/mol is
# the mid value for the primary decomposition. Divided by the gas constant it is a temperature, which is the
# form an Arrhenius rate wants — the same form SILICATE_DISSOLUTION_EA_OVER_R_K already takes.
#
# This is what lets fire be a thermal runaway instead of a branch, and lets a damp fuel resist lighting
# because the water in the cell is absorbing the heat, with no per-case code.
const CELLULOSE_PYROLYSIS_EA_J_MOL: float = 2.30e5
const CELLULOSE_PYROLYSIS_EA_OVER_R_K: float = CELLULOSE_PYROLYSIS_EA_J_MOL / GAS_CONSTANT_J_MOL_K

# --- ALBEDO OF VEGETATION ---------------------------------------------------------------------------------
# A forest canopy is DARKER than bare ground — 0.08-0.15 for conifers, 0.15-0.20 for grassland and crops.
# 0.12 is a mid value for mixed vegetation. This is the biological half of the ice-albedo feedback, and its
# absence is why a forest currently warms its planet no differently from the sand it grows on.
const ALBEDO_VEGETATION: float = 0.12

# --- CANOPY LIGHT INTERCEPTION ------------------------------------------------------------------------------
# An albedo alone cannot darken a planet: a cell reflects at the canopy's albedo only over the fraction of its
# ground the canopy actually COVERS, and that fraction has to come from the mass the cell carries. These three
# are what turns a mass into a cover fraction. They are properties of a CANOPY — a structure — in the same way
# ATMOS_OPTICAL_DEPTH and TWO_STREAM_COEFF above are properties of an air column, which is why they live here
# and not on `cellulose` in LASubstances: dry litter and cured fuel are the same substance and have no leaf
# area at all, so hanging leaf geometry on the polymer would assert something false about three other channels.
#
# LEAF MASS PER AREA is the measured quantity of the leaf-economics spectrum (Wright et al. 2004, Nature
# 428:821, GLOPNET, 2548 species): how many kilograms of dry leaf stand behind a square metre of leaf surface.
# It spans about 0.014 (soft herbaceous) to 1.5 (sclerophyll) kg/m^2, log-mean near 0.08. Dividing an areal
# dry mass by it gives LEAF AREA INDEX directly, so no reciprocal "specific leaf area" is declared — one
# number, in the form it is measured in.
const LEAF_MASS_PER_AREA_KG_M2: float = 0.080

# WHAT FRACTION OF STANDING PLANT MATTER IS FOLIAGE. A plant is mostly structure: stems, branches and roots
# carry the mass, leaves carry the area. Globally, plant biomass is ~450 GtC (Bar-On, Phillips & Milo 2018)
# of which leaves are a few percent; the ratio runs 0.01-0.03 in mature forest, 0.05-0.15 in shrubland and
# 0.4-0.6 in grassland, where nearly all the tissue photosynthesises. 0.03 is the global figure.
#
# THIS EXISTS BECAUSE THE SUBSTRATE HAS ONE ORGANIC POOL, NOT TWO. `biomass` is not split into wood and leaf,
# so the conversion from standing mass to leaf area has to carry the ratio explicitly. Without it the model
# asserts a plant made entirely of leaves: at this planet's measured 8.2 kg/m^2 of ground-cell biomass that
# is a leaf area index of 102, against 4-6 for a real closed forest. The day `biomass` grows a structural
# fraction, this constant is what that fraction replaces.
const FOLIAGE_FRACTION_OF_PLANT_MASS: float = 0.03

# BEER-LAMBERT EXTINCTION THROUGH A CANOPY (Monsi & Saeki 1953). The fraction of a beam intercepted by leaf
# area L is 1 - exp(-k*L), and k is the mean projection of a leaf onto the beam direction. For a spherical
# leaf-angle distribution — leaves pointing every way, the standard default — that projection is exactly 1/2
# by geometry, being the mean of |cos| between a random unit normal and a fixed direction.
#
# It is also what makes "the canopy closes" a measured thing rather than a chosen saturation point: at the
# observed closure of LAI 3-4 the interception is 0.78-0.86, and it approaches 1 asymptotically, so nothing
# has to be clamped.
const CANOPY_EXTINCTION_COEFF: float = 0.5

# THE MINERAL MOLAR MASSES ARE NOT REPEATED HERE. MOLAR_MASS_CASIO3_KG_MOL, MOLAR_MASS_SIO2_KG_MOL and
# MOLAR_MASS_CACO3_KG_MOL are already declared above with the same atomic weights. This block briefly held
# WOLLASTONITE/SILICA/CALCITE aliases for them — the same three facts under second names, which is exactly
# how the freezing point of water came to be declared in five places at three values. Deleted the same day.
