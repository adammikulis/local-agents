class_name LAPhysical
extends RefCounted


# --- WATER (H₂O) ------------------------------------------------------------------------------------------
const WATER_FREEZE_C: float = 0.0
const WATER_MELT_C: float = 0.0
const WATER_BOIL_C: float = 100.0
# Liquid water at 25 °C. It is the denominator of every "how much of a cell is water" figure in this
# substrate: the field stores water as a FILL FRACTION (1.0 = a cell full of liquid), so any real density
# has to be divided by this to become a channel value. Same number the volumetric heat capacity below uses.
const WATER_DENSITY_KG_M3: float = 997.0

# --- WATER VAPOUR: THE SATURATION CURVE ---------------------------------------------------------------------
# The curve itself is Clausius-Clapeyron. The closed form used is the AUGUST-ROCHE-MAGNUS approximation with
const MAGNUS_A_PA: float = 610.94
const MAGNUS_B: float = 17.625
const MAGNUS_C_C: float = 243.04
# Specific gas constant of water vapour = universal R (8314.46 J/kmol/K) / molar mass (18.015 kg/kmol).
# Turns that pressure into a DENSITY through the ideal gas law: rho_v = e / (R_v * T_K).
const VAPOUR_GAS_CONST_J_KGK: float = 461.52

# --- THUNDERSTORM CHARGE SEPARATION -----------------------------------------------------------------------
const CHARGE_ZONE_WARM_C: float = -10.0
const CHARGE_ZONE_COLD_C: float = -25.0

# --- ROCK / MAGMA -----------------------------------------------------------------------------------------
const BASALT_LIQUIDUS_C: float = 1200.0
const BASALT_SOLIDUS_C: float = 1000.0

# --- PLANETARY INTERIOR -----------------------------------------------------------------------------------
const INNER_CORE_C: float = 5200.0
const CORE_MANTLE_BOUNDARY_C: float = 3700.0
const UPPER_MANTLE_C: float = 1300.0

# --- UPPER CRUST: THE GEOTHERM A SURFACE SIMULATION ACTUALLY NEEDS ------------------------------------------
const GEOTHERMAL_GRADIENT_C_PER_KM: float = 60.0

const GROUNDWATER_CIRCULATION_M: float = 2000.0

# --- THERMAL TRANSPORT ------------------------------------------------------------------------------------
# Conductivity lambda (W/m/K) and volumetric heat capacity rho*c (J/m^3/K) for the three materials this
# substrate conducts through, plus the diffusivity alpha = lambda/(rho*c) (m^2/s) they imply.
# WHAT THESE NUMBERS SAY ABOUT THIS PLANET, stated once so nobody re-derives it: alpha_rock 1.03e-6 m^2/s
const THERMAL_CONDUCT_ROCK_W_MK: float = 2.5
const THERMAL_CONDUCT_AIR_W_MK: float = 0.026
const THERMAL_CONDUCT_WATER_W_MK: float = 0.60
const ROCK_DENSITY_KG_M3: float = 2900.0
const ROCK_SPECIFIC_HEAT_J_KGK: float = 840.0
const VOL_HEAT_CAP_ROCK_J_M3K: float = ROCK_DENSITY_KG_M3 * ROCK_SPECIFIC_HEAT_J_KGK
const VOL_HEAT_CAP_AIR_J_M3K: float = AIR_DENSITY_KG_M3 * AIR_SPECIFIC_HEAT_J_KGK
const VOL_HEAT_CAP_WATER_J_M3K: float = WATER_DENSITY_KG_M3 * WATER_SPECIFIC_HEAT_J_KGK
const THERMAL_DIFFUSIVITY_ROCK_M2_S: float = 1.026e-6    # 2.5 / 2.436e6
const THERMAL_DIFFUSIVITY_AIR_M2_S: float = 2.192e-5     # 0.026 / 1186
const THERMAL_DIFFUSIVITY_WATER_M2_S: float = 1.438e-7   # 0.60 / 4.171e6

# --- RADIOGENIC HEATING -----------------------------------------------------------------------------------
const RADIOGENIC_W_PER_KG: float = 5.0e-12

# --- ENERGY BUDGET ----------------------------------------------------------------------------------------
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
# brightest. (Earth's ~0.30 PLANETARY albedo includes clouds, which this substrate models separately, so the
# surface values belong here and the cloud contribution does not.)
const ALBEDO_OCEAN: float = 0.06
const ALBEDO_BARE_GROUND: float = 0.15
const ALBEDO_SNOW_ICE: float = 0.65

# --- COMBUSTION -------------------------------------------------------------------------------------------

# BURN_TEMP = 640 — every burning cell on the planet was HELD at one temperature, so a fire in a swamp and a
const HEAT_PER_KG_OXYGEN_J: float = 1.31e7

# 1.18 kg/m³ — the same density VOL_HEAT_CAP_AIR_J_M3K above is built from, so the two agree by construction.
const AIR_O2_MASS_FRACTION: float = 0.2314
const AMBIENT_O2_DENSITY_KG_M3: float = 0.2731


# --- GROUNDWATER: PERMEABILITY IS GEOMETRY, NOT A MATERIAL NAME ---------------------------------------------
# (Freeze & Cherry 1979, Table 2.2): gravel 1e-3..1 m/s, clean sand 1e-5..1e-2, silty sand 1e-7..1e-3,
# and the Kozeny-Carman relation says exactly how:
#     k   = phi^3 * d^2 / (KOZENY_CARMAN_C * (1 - phi)^2)      [intrinsic permeability, m^2]
#     K   = k * rho_w * g / mu                                 [hydraulic conductivity, m/s]
# with phi the porosity and d the representative grain diameter. Kozeny (1927) / Carman (1937); the constant
# 180 is Carman's fit for packed granular beds. Substituting real regolith numbers reproduces the table above
# with nothing fitted: phi 0.35 with d = 0.5 mm gives 1.4e-3 m/s (coarse sand), d = 4 mm gives 8.8e-2 m/s
# (fine gravel), d = 0.05 mm gives 1.4e-5 m/s (silty sand). One relation, the whole range.
const KOZENY_CARMAN_C: float = 180.0
# quantity, two constants, two values. The CGPM-defined figure is the authority and this is now an alias, so
const GRAVITY_M_S2: float = STANDARD_GRAVITY_M_S2
const WATER_DYNAMIC_VISCOSITY_PA_S: float = 1.002e-3    # liquid water at 20 °C
const AIR_DYNAMIC_VISCOSITY_PA_S: float = 1.81e-5       # dry air at 15 °C, 1 atm

const REGOLITH_SURFACE_POROSITY: float = 0.40
const COMPACTION_LENGTH_M: float = 2500.0

## Terminal settling velocity of a grain in a fluid, m/s (Stokes drag): v = (rho_p - rho_f) g d^2 / 18 mu.
## Valid only for Reynolds < 1. At GRAIN_D_UPLAND_M in air Re = 1.2, so this is at the edge of validity and
## reads a little fast; at GRAIN_D_LOWLAND_M it returns 1396 m/s, which is meaningless — a 4 mm grain is not
## airborne and is never passed here.
static func stokes_settling_velocity(grain_d_m: float, fluid_density: float, fluid_viscosity: float) -> float:
	if fluid_viscosity <= 0.0:
		return 0.0
	return (ROCK_DENSITY_KG_M3 - fluid_density) * STANDARD_GRAVITY_M_S2 * grain_d_m * grain_d_m \
		/ (18.0 * fluid_viscosity)


const GRAIN_D_UPLAND_M: float = 6.0e-5      # 0.06 mm — very fine sand / coarse silt (residual saprolite)
const GRAIN_D_LOWLAND_M: float = 4.0e-3     # 4 mm — fine gravel (valley-fill alluvium)

# --- GRANULAR MECHANICS: THE ANGLE OF REPOSE ------------------------------------------------------------------
const REPOSE_TAN_DRY_GRANULAR: float = 0.70


static func saturation_mass_fraction(t_c: float) -> float:
	var t: float = maxf(t_c, -80.0)    # the Magnus fit is stated over -40..+50 and its pole is at -243.04 °C
	var e_sat: float = MAGNUS_A_PA * exp(MAGNUS_B * t / (t + MAGNUS_C_C))
	var rho_v: float = e_sat / (VAPOUR_GAS_CONST_J_KGK * maxf(t + KELVIN_OFFSET, 1.0))
	return rho_v / WATER_DENSITY_KG_M3
# --- LIVING TISSUE ----------------------------------------------------------------------------------------
# muscle ~1060, fat ~920, whole-body ~1010 kg/m³. 1000 is the honest round value and it is why an animal
const ANIMAL_TISSUE_DENSITY_KG_M3: float = 1000.0

const PROTEIN_DENATURE_C: float = 45.0

# of combustion: carbohydrate 16.7 MJ/kg (Atwater, 4 kcal/g), cellulose 17.5, dry cellulosic fuel 18-19
# (higher because of lignin), fat 39, protein 17. 17 MJ/kg is the carbohydrate value and the one the
# material is; the 1 MJ/kg difference is inside the measurement spread for plant matter either way.
const BIOMASS_HEAT_OF_COMBUSTION_J_PER_KG: float = 1.7e7

# Specific heat of animal tissue — again mostly water, measured ~3500 J/kg/K against water's 4184 (tissue is
const ANIMAL_SPECIFIC_HEAT_J_KGK: float = 3500.0
# --- UNIVERSAL CONSTANTS ------------------------------------------------------------------------------------
const STANDARD_GRAVITY_M_S2: float = 9.80665        # CGPM-defined standard gravity
const PLANET_ANGULAR_VELOCITY_RAD_S: float = 7.2921159e-5   # Earth sidereal rotation, 2*pi/86164.1 s
## Coriolis parameter is f = CORIOLIS_TWO_OMEGA_RAD_S * sin(latitude).
const CORIOLIS_TWO_OMEGA_RAD_S: float = PLANET_ANGULAR_VELOCITY_RAD_S * 2.0
const GAS_CONSTANT_J_MOL_K: float = 8.314462618     # CODATA molar gas constant R
const SECONDS_PER_YEAR: float = 3.15576e7           # Julian year, 365.25 days

# --- MOLAR MASSES (IUPAC 2021 standard atomic weights) ------------------------------------------------------
# `o2` is the O₂ in a cell of ambient air (8.5 mol/m³) and one unit of `water` is a cell FULL of liquid water
# (55343 mol/m³), a factor of 6484. Converting between a channel unit and moles is the missing step, and it
const MOLAR_MASS_WATER_KG_MOL: float = 0.018015     # H₂O
const MOLAR_MASS_N2_KG_MOL: float = 0.0280134       # N₂
const MOLAR_MASS_AR_KG_MOL: float = 0.0399480       # Ar
const MOLAR_MASS_O2_KG_MOL: float = 0.0319988       # O₂
const MOLAR_MASS_CO2_KG_MOL: float = 0.0440095      # CO₂
const MOLAR_MASS_CARBON_KG_MOL: float = 0.0120110   # C
const MOLAR_MASS_NITROGEN_KG_MOL: float = 0.0140067  # N
# 0.180156 kg/mol and cellulose is a polymer of it; this is one sixth of that, the per-carbon unit
const MOLAR_MASS_CH2O_UNIT_KG_MOL: float = 0.0300260

#                     (Walker, Hays & Kasting 1981, and every long-term carbon-cycle model since)
const MOLAR_MASS_CASIO3_KG_MOL: float = 0.1161612    # CaSiO3  40.078 + 28.085 + 3*15.9994
const MOLAR_MASS_SIO2_KG_MOL: float = 0.0600838      # SiO2    28.085 + 2*15.9994
const MOLAR_MASS_CACO3_KG_MOL: float = 0.1000872     # CaCO3   40.078 + 12.011 + 3*15.9994
const QUARTZ_DENSITY_KG_M3: float = 2650.0           # alpha-quartz, 2.65 g/cm^3
const CALCITE_DENSITY_KG_M3: float = 2710.0          # calcite, 2.71 g/cm^3

# --- STANDARD-STATE THERMOCHEMISTRY, 298.15 K and 1 bar (Robie & Hemingway 1995; CODATA for CO2) -------------
# Formation enthalpy from the elements and standard molar entropy, per substance. A reaction's dG is derived
# from these over its own stoichiometry — LAReactionThermo — so no reaction carries a direction constant.
const FORMATION_ENTHALPY_CASIO3_J_MOL: float = -1634900.0   # wollastonite
const FORMATION_ENTHALPY_SIO2_J_MOL: float = -910700.0      # alpha-quartz
const FORMATION_ENTHALPY_CACO3_J_MOL: float = -1207600.0    # calcite
const FORMATION_ENTHALPY_CO2_J_MOL: float = -393510.0
const ENTROPY_CASIO3_J_MOL_K: float = 81.69
const ENTROPY_SIO2_J_MOL_K: float = 41.46
const ENTROPY_CACO3_J_MOL_K: float = 91.7

# --- WATER AND ICE DENSITY: WHY ROCK SHATTERS WHEN IT FREEZES -----------------------------------------------
# frost weathering. At 0 C and 1 atm liquid water is 999.84 kg/m^3 and ice Ih is 916.7, so a given mass of
const WATER_DENSITY_0C_KG_M3: float = 999.84
const ICE_DENSITY_KG_M3: float = 916.7
const ICE_FREEZE_EXPANSION: float = 0.0907          # 999.84/916.7 - 1

const ROCK_POROSITY_NEAR_SURFACE: float = 0.05

# --- CHEMICAL WEATHERING: SILICATE DISSOLUTION --------------------------------------------------------------
# Laboratory and field values for plagioclase feldspar and basaltic glass cluster at 50-90 kJ/mol (White &
# Brantley's compilations); 60 kJ/mol sits mid-range for basalt. It is what makes weathering roughly DOUBLE
const SILICATE_DISSOLUTION_EA_J_MOL: float = 60000.0
# DERIVED, and it had already drifted: this stored 7216.9 while its own inputs give 7216.34. A stored
# product that has stopped matching its derivation, in the file whose thesis is that this is how water came
# to freeze at 12.5 C. CELLULOSE_PYROLYSIS_EA_OVER_R_K two hundred lines away was derived correctly; this
const SILICATE_DISSOLUTION_EA_OVER_R_K: float = SILICATE_DISSOLUTION_EA_J_MOL / GAS_CONSTANT_J_MOL_K
# The temperature laboratory dissolution rates are quoted at. Arrhenius needs a reference point; this is the
# standard one, and it is a property of the measurement, not of the rock.
const LAB_REFERENCE_TEMP_C: float = 25.0

# --- LITHIFICATION: A PRESSURE, NOT A DEPTH -----------------------------------------------------------------
#     P = ROCK_DENSITY_KG_M3 * STANDARD_GRAVITY_M_S2 * GROUNDWATER_CIRCULATION_M
const LITHIFICATION_PRESSURE_PA: float = 5.688e7
# Bulk density of unconsolidated wet sediment (sand and mud), measured range 1600-2200 kg/m^3. It is lower
# than rock because sediment is a grain framework with water in the pores — which is exactly why a sediment
# pile has to be thicker than a rock pile to reach the same overburden pressure.
const SEDIMENT_DENSITY_KG_M3: float = 2000.0

# --- PLATE MOTION -------------------------------------------------------------------------------------------
const PLATE_SPEED_MIN_MM_PER_YEAR: float = 10.0
const PLATE_SPEED_MAX_MM_PER_YEAR: float = 100.0
# --- THE COMPOSITION OF AIR -------------------------------------------------------------------------------
const AIR_MOLE_FRAC_N2: float = 0.78084     # NASA/NOAA standard atmosphere, dry air
const AIR_MOLE_FRAC_O2: float = 0.20946
const AIR_MOLE_FRAC_AR: float = 0.00934
const AIR_MOLE_FRAC_CO2: float = 0.000419   # NOAA GML global annual mean, 2023

# ============================================================================================================
const METRES_PER_MODEL_UNIT: float = 168.6

# Dry air, from the mole fractions above and the molar masses above. M_air = sum(x_i * M_i) — a real
# weighted mean, not a stored 0.02896 whose derivation lives in a comment.
const MOLAR_MASS_DRY_AIR_KG_MOL: float = \
	AIR_MOLE_FRAC_N2 * MOLAR_MASS_N2_KG_MOL \
	+ AIR_MOLE_FRAC_O2 * MOLAR_MASS_O2_KG_MOL \
	+ AIR_MOLE_FRAC_AR * MOLAR_MASS_AR_KG_MOL \
	+ AIR_MOLE_FRAC_CO2 * MOLAR_MASS_CO2_KG_MOL
const DRY_AIR_GAS_CONSTANT_J_KGK: float = GAS_CONSTANT_J_MOL_K / MOLAR_MASS_DRY_AIR_KG_MOL


## Atmospheric scale height in METRES at a temperature: H = R_d * T / g, the hydrostatic relation for an
## isothermal ideal-gas column. A FUNCTION, because H is a function of temperature — storing one number for
## it is the defect this file has now hit five times.
static func scale_height_m(t_c: float) -> float:
	return DRY_AIR_GAS_CONSTANT_J_KGK * maxf(t_c + KELVIN_OFFSET, 1.0) / STANDARD_GRAVITY_M_S2


## The same, in MODEL UNITS, which is what a kernel walking radial shells needs.
static func scale_height_model_units(t_c: float) -> float:
	return scale_height_m(t_c) / METRES_PER_MODEL_UNIT


const SCALE_HEIGHT_PER_K_MODEL: float = DRY_AIR_GAS_CONSTANT_J_KGK / STANDARD_GRAVITY_M_S2 / METRES_PER_MODEL_UNIT


static func air_units_to_pascals(column_air_units: float, cell_size_model_units: float) -> float:
	var cell_m: float = cell_size_model_units * METRES_PER_MODEL_UNIT
	return STANDARD_GRAVITY_M_S2 * AIR_DENSITY_KG_M3 * cell_m * column_air_units
# ============================================================================================================

# --- ORGANIC MATTER: THE CARBON-TO-NITROGEN RATIO ---------------------------------------------------------
# (Batjes 1996). 20 is the litter figure this substrate's detritus channel represents.
const LITTER_C_TO_N: float = 20.0
const SOIL_ORGANIC_C_TO_N: float = 12.0
# ============================================================================================================
# Appended as one contiguous block because four lanes were editing this file the same day.
# ============================================================================================================

# --- SHORTWAVE IS NOT LONGWAVE, AND THE DIFFERENCE *IS* THE GREENHOUSE --------------------------------------
# Earth's atmosphere absorbs 78 W/m^2 of the 341 W/m^2 arriving at the top of the atmosphere — 22.9%
# (Trenberth, Fasullo & Kiehl 2009, "Earth's Global Energy Budget", BAMS 90:311). A Beer-Lambert vertical
const ATMOS_SW_OPTICAL_DEPTH: float = 0.2597

const AIR_MASS_HORIZON: float = 38.0

# --- WATER: DENSITY AND THE LATENT HEAT OF VAPORISATION ------------------------------------------------------
const LATENT_HEAT_VAPORISATION_J_KG: float = 2.257e6

# --- SNOW -----------------------------------------------------------------------------------------------------
# Settled seasonal snowpack: rho 300 kg/m^3 (fresh fall 50-100, settled 200-400, firn 500+), c 2090 J/kg/K
# (ice), lambda 0.15 W/m/K (measured range 0.05-0.5 with density; 0.15 is the settled-pack value). The
const SNOWPACK_DENSITY_KG_M3: float = 300.0
const VOL_HEAT_CAP_SNOW_J_M3K: float = WATER_DENSITY_KG_M3 * ICE_SPECIFIC_HEAT_J_KGK
const VOL_HEAT_CAP_ORGANIC_J_M3K: float = DRY_WOOD_DENSITY_KG_M3 * DRY_WOOD_SPECIFIC_HEAT_J_KGK
const THERMAL_CONDUCT_SNOW_W_MK: float = 0.15

# --- THE CARRIERS THAT HELD MATTER AND NO HEAT ----------------------------------------------------------------
const VOL_HEAT_CAP_CARBONATE_J_M3K: float = CALCITE_DENSITY_KG_M3 * CALCITE_SPECIFIC_HEAT_J_KGK
const VOL_HEAT_CAP_SILICA_J_M3K: float = QUARTZ_DENSITY_KG_M3 * QUARTZ_SPECIFIC_HEAT_J_KGK
const VOL_HEAT_CAP_VAPOUR_J_M3K: float = WATER_DENSITY_KG_M3 * VAPOUR_SPECIFIC_HEAT_J_KGK
# ============================================================================================================
# ============================================================================================================

# --- LIGHTNING --------------------------------------------------------------------------------------------
const LIGHTNING_FLASH_J: float = 1.0e9

# --- HEAT OF COMBUSTION -----------------------------------------------------------------------------------

# --- CARBON CONTENT OF DRY PLANT MATTER --------------------------------------------------------------------
const BIOMASS_CARBON_FRACTION: float = 0.47
# ============================================================================================================

# --- WATER: FUSION AND SUBLIMATION --------------------------------------------------------------------------
const LATENT_HEAT_FUSION_J_KG: float = 3.337e5

# SUBLIMATION, ice directly to vapour at 0 °C. By Hess's law it is the sum of the other two AT THAT
const LATENT_HEAT_SUBLIMATION_J_KG: float = 2.834e6

# --- BASALT: THE ENTHALPY OF CRYSTALLISATION ----------------------------------------------------------------
# 3.5-5e5 J/kg across basaltic compositions (Lange, Cashman & Navrotsky 1994, Contrib Mineral Petrol 118:169);
const BASALT_LATENT_HEAT_CRYSTALLISATION_J_KG: float = 4.0e5

# --- BASALT: THERMAL-INFRARED EMISSIVITY ---------------------------------------------------------------------
const BASALT_EMISSIVITY: float = 0.95

# --- THE LIMITING OXYGEN CONCENTRATION -------------------------------------------------------------------------
const LIMITING_OXYGEN_CONCENTRATION_FRAC: float = 0.15
# ============================================================================================================

# --- SPECIFIC HEATS (J/kg/K), the per-mass companions of the VOL_HEAT_CAP_* above ---------------------------
const WATER_SPECIFIC_HEAT_J_KGK: float = 4184.0     # liquid water, 25 C
const ICE_SPECIFIC_HEAT_J_KGK: float = 2090.0       # ice at 0 C — HALF liquid water's, which is why a snowpack
                                                    # swings temperature so much faster than a lake
const VAPOUR_SPECIFIC_HEAT_J_KGK: float = 1996.0    # water vapour at constant pressure, 100 C
const AIR_SPECIFIC_HEAT_J_KGK: float = 1005.0       # dry air at constant pressure, 300 K
# `VOL_HEAT_CAP_AIR_J_M3K = 1186.0 # 1.18 * 1005` carried it in a comment, and AMBIENT_O2_DENSITY_KG_M3's
# 0.2731 is 0.2314 * 1.18 folded into a literal. One name now, and both are products of it.
const AIR_DENSITY_KG_M3: float = 1.18
# The two non-silicate mineral species, so `carbonate` and `silica` can carry heat like every other channel
# that holds matter. Densities were already here (CALCITE / QUARTZ); these are the missing c's.
const CALCITE_SPECIFIC_HEAT_J_KGK: float = 820.0    # CaCO3, calcite, 25 C (0.82 kJ/kg/K)
const QUARTZ_SPECIFIC_HEAT_J_KGK: float = 740.0     # SiO2, alpha-quartz, 25 C (0.74 kJ/kg/K)

# --- WATER: VAPORISATION AT 0 C ------------------------------------------------------------------------------
# 0 C fusion and sublimation left 2.257e6 + 3.337e5 = 2.591e6 against 2.834e6 — short by 2.433e5 J/kg, and
const LATENT_HEAT_VAPORISATION_0C_J_KG: float = 2.501e6

# ============================================================================================================
# The Watson correlation has the right asymptote and is the standard engineering form:
const WATER_TRIPLE_T_C: float = 0.01                 # IAPWS, 273.16 K exactly by definition
const WATER_TRIPLE_P_PA: float = 611.657              # IAPWS triple-point pressure
const WATER_CRITICAL_T_C: float = 373.946            # IAPWS-95 critical temperature, 647.096 K
const WATER_CRITICAL_P_PA: float = 2.2064e7          # IAPWS-95 critical pressure, 220.64 bar
const STANDARD_PRESSURE_PA: float = 101325.0         # one standard atmosphere, the reference boil_c is quoted at
const WATSON_LATENT_EXPONENT: float = 0.38           # Watson correlation exponent for the latent-heat curve

# --- DISSOCIATION AND IONISATION: the two rungs above `gas` ---------------------------------------------
# A molecule breaks into atoms before those atoms ionise, and each step costs real energy. Skipping either
# is a phase change with no latent heat.
const EV_TO_J_PER_MOL: float = 96485.33              # CODATA Faraday constant, J/(mol*V)

# ATOMISATION enthalpy: gas molecule -> free atoms, J/mol at 298 K. Sum of the bond enthalpies in one
# molecule, quoted as the measured atomisation rather than per-bond so no bond graph is needed.
const ATOMISATION_H2O_J_MOL: float = 9.269e5         # 2 x O-H, 926.9 kJ/mol (from dfH of H2O, H, O)
const ATOMISATION_O2_J_MOL: float = 4.9834e5         # O=O, 498.34 kJ/mol
const ATOMISATION_CO2_J_MOL: float = 1.5980e6        # 2 x C=O, 1598 kJ/mol
const ATOMISATION_N2_J_MOL: float = 9.4533e5         # N#N, 945.33 kJ/mol
const ATOMISATION_CH2O_J_MOL: float = 1.5117e6       # formaldehyde-unit carbohydrate, 2 C-H + C=O
const ATOMISATION_SIO2_J_MOL: float = 1.8646e6       # 2 x Si-O, 1864.6 kJ/mol
const ATOMISATION_CACO3_J_MOL: float = 2.8990e6      # CaCO3 -> Ca + C + 3 O

# FIRST IONISATION ENERGY per element, eV (NIST Atomic Spectra Database). A substance derives its own from
# `formula`, the same way it derives its stoichiometry — one number per element, never one per compound.
const IONISATION_EV_H: float = 13.598
const IONISATION_EV_O: float = 13.618
const IONISATION_EV_C: float = 11.260
const IONISATION_EV_N: float = 14.534
const IONISATION_EV_SI: float = 8.152
const IONISATION_EV_CA: float = 6.113
const IONISATION_EV_FE: float = 7.902
const IONISATION_EV_MG: float = 7.646
const IONISATION_EV_AL: float = 5.986

# ONSET TEMPERATURES FOR THE TWO HIGH RUNGS. DECLARED MODELLING CHOICES, NOT MEASUREMENTS: real thermal
# dissociation and ionisation are gradual equilibria (Saha), not the sharp plateaus this ladder uses. A
# plateau at a stated temperature keeps the ENERGY exact — the full bond and ionisation enthalpy is still
# absorbed — while placing it at a single temperature instead of spreading it over a range.
# See docs/MODEL_PARAMETERS.md.
const DISSOCIATION_ONSET_C: float = 2226.85           # 2500 K, where H2O dissociation becomes significant
# --- SAHA AND LAW OF MASS ACTION: the equilibria the two high rungs actually obey ------------------------
const PLANCK_J_S: float = 6.62607015e-34             # CODATA, exact
const BOLTZMANN_J_K: float = 1.380649e-23            # CODATA, exact
const ELECTRON_MASS_KG: float = 9.1093837015e-31     # CODATA
const AVOGADRO_PER_MOL: float = 6.02214076e23        # CODATA, exact

# GROUND-STATE ELECTRONIC DEGENERACIES, neutral then singly-ionised (NIST ASD term symbols).
# Saha carries the ratio 2*g_ion/g_neutral.
const DEGEN_H_0: float = 2.0     # H  2S(1/2)
const DEGEN_H_1: float = 1.0     # H+ bare proton
const DEGEN_O_0: float = 9.0     # O  3P(2)
const DEGEN_O_1: float = 4.0     # O+ 4S(3/2)
const DEGEN_C_0: float = 9.0     # C  3P(0)
const DEGEN_C_1: float = 6.0     # C+ 2P(1/2)
const DEGEN_N_0: float = 4.0     # N  4S(3/2)
const DEGEN_N_1: float = 9.0     # N+ 3P(0)

# STANDARD MOLAR ENTROPIES at 298.15 K, 1 bar, J/(mol K) — NIST-JANAF. The dissociation equilibrium needs
# dG = dH - T dS, and dS comes from these: products (free atoms) minus the reactant molecule.
const ENTROPY_H_ATOM_J_MOLK: float = 114.717
const ENTROPY_O_ATOM_J_MOLK: float = 161.058
const ENTROPY_C_ATOM_J_MOLK: float = 158.100
const ENTROPY_N_ATOM_J_MOLK: float = 153.301
# The linear fit, as a CONSTANT rather than a sentence in a comment, so the relation between the two
# measured latent heats is checkable instead of asserted. Valid 0-100 C; use the Watson form outside it.
const LATENT_VAPORISATION_SLOPE_J_KGK: float = 2361.0
# ============================================================================================================

# --- EMISSIVITY -----------------------------------------------------------------------------------------------
# Thermal-infrared emissivity of a water surface. Near-blackbody, which is why the ocean radiates so
# efficiently and why sea-surface temperature can be measured from orbit at all.
const EMISSIVITY_WATER: float = 0.96

# --- DRY WOOD / CELLULOSIC FUEL -------------------------------------------------------------------------------
# Oven-dry softwood: 400-600 kg/m3 across species (denser hardwoods reach 900); 500 is the mid value for the
# conifer and grass litter that carries a wildfire. Specific heat of dry wood is 1300-1700 J/kg/K over normal
const DRY_WOOD_DENSITY_KG_M3: float = 500.0
const DRY_WOOD_SPECIFIC_HEAT_J_KGK: float = 1500.0

# 200-250 kJ/mol by thermogravimetry (Antal & Varhegyi 1995 review the spread and its causes); 230 kJ/mol is
# form an Arrhenius rate wants — the same form SILICATE_DISSOLUTION_EA_OVER_R_K already takes.
const CELLULOSE_PYROLYSIS_EA_J_MOL: float = 2.30e5
const CELLULOSE_PYROLYSIS_EA_OVER_R_K: float = CELLULOSE_PYROLYSIS_EA_J_MOL / GAS_CONSTANT_J_MOL_K

# --- ALBEDO OF VEGETATION ---------------------------------------------------------------------------------
const ALBEDO_VEGETATION: float = 0.12

# --- CANOPY LIGHT INTERCEPTION ------------------------------------------------------------------------------
# LEAF MASS PER AREA is the measured quantity of the leaf-economics spectrum (Wright et al. 2004, Nature
# It spans about 0.014 (soft herbaceous) to 1.5 (sclerophyll) kg/m^2, log-mean near 0.08. Dividing an areal
const LEAF_MASS_PER_AREA_KG_M2: float = 0.080

# carry the mass, leaves carry the area. Globally, plant biomass is ~450 GtC (Bar-On, Phillips & Milo 2018)
# asserts a plant made entirely of leaves: at this planet's measured 8.2 kg/m^2 of ground-cell biomass that
const FOLIAGE_FRACTION_OF_PLANT_MASS: float = 0.03

const CANOPY_EXTINCTION_COEFF: float = 0.5

# --- DINITROGEN -----------------------------------------------------------------------------------------
# N2 is 78.084% of dry air by mole and was absent from the substance table entirely. Every value below is
# from the NIST Chemistry WebBook (nitrogen, CAS 7727-37-9) unless another source is named.
const N2_BOIL_C: float = -195.795                    # normal boiling point 77.355 K
const N2_TRIPLE_T_C: float = -210.0                  # triple point 63.15 K
const N2_TRIPLE_P_PA: float = 12520.0                # triple-point pressure 12.52 kPa
const N2_CRITICAL_T_C: float = -146.958              # critical point 126.192 K
const N2_CRITICAL_P_PA: float = 3.3958e6             # critical pressure 3.3958 MPa
const VAP_ENTHALPY_N2_J_MOL: float = 5577.0          # dHvap at 77.355 K
const FUS_ENTHALPY_N2_J_MOL: float = 710.0           # dHfus at the triple point (CRC Handbook, 97th ed.)
const LATENT_HEAT_VAPORISATION_N2_J_KG: float = VAP_ENTHALPY_N2_J_MOL / MOLAR_MASS_N2_KG_MOL
const LATENT_HEAT_FUSION_N2_J_KG: float = FUS_ENTHALPY_N2_J_MOL / MOLAR_MASS_N2_KG_MOL
const MOLAR_HEAT_CAP_N2_GAS_J_MOLK: float = 29.124   # cp of the gas at 298.15 K, 1 bar
const N2_GAS_SPECIFIC_HEAT_J_KGK: float = MOLAR_HEAT_CAP_N2_GAS_J_MOLK / MOLAR_MASS_N2_KG_MOL
const N2_LIQUID_SPECIFIC_HEAT_J_KGK: float = 2042.0  # cp of the saturated liquid at 77.355 K
const THERMAL_CONDUCT_N2_GAS_W_MK: float = 0.02583   # gas at 300 K, 1 bar
const ENTROPY_N2_GAS_J_MOLK: float = 191.609         # standard molar entropy, CODATA Key Values

# --- LIGHTNING NITROGEN FIXATION ------------------------------------------------------------------------
# Schumann & Huntrieser 2007 (Atmos. Chem. Phys. 7:3823) put the global lightning NOx source at 5 Tg(N)/yr
# (range 2-8) and quote a best estimate of 250 mol NO per flash; Christian et al. 2003 (JGR 108:4005,
# OTD/LIS) give the global flash rate of 44 s^-1, and 5e12 g/yr / 14.0067 g/mol / (44 * SECONDS_PER_YEAR)
# returns 257 mol N per flash, so the two are the same number. Per JOULE it is that divided by the energy
# of one flash.
const LIGHTNING_N_FIXED_MOL_PER_FLASH: float = 250.0
const LIGHTNING_N_FIXED_MOL_PER_J: float = LIGHTNING_N_FIXED_MOL_PER_FLASH / LIGHTNING_FLASH_J

