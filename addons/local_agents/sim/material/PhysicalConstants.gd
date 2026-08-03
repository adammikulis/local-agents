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
const WATER_DENSITY_KG_M3: float = 997.0
const LATENT_HEAT_VAPORISATION_J_KG: float = 2.257e6

# --- SNOW -----------------------------------------------------------------------------------------------------
# Settled seasonal snowpack: rho 300 kg/m^3 (fresh fall 50-100, settled 200-400, firn 500+), c 2090 J/kg/K
# (ice), lambda 0.15 W/m/K (measured range 0.05-0.5 with density; 0.15 is the settled-pack value). The
# conductivity is why a snow blanket keeps the soil under it above freezing.
const VOL_HEAT_CAP_SNOW_J_M3K: float = 6.27e5       # 300 * 2090
const THERMAL_CONDUCT_SNOW_W_MK: float = 0.15
