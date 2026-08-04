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
