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
