class_name LAPhysical
extends RefCounted


# --- WATER (H₂O) ------------------------------------------------------------------------------------------
const WATER_FREEZE_C: float = 0.0
const WATER_MELT_C: float = 0.0
const WATER_BOIL_C: float = 100.0
# Liquid water at 25 °C.
const WATER_DENSITY_KG_M3: float = 997.0
## Volumetric thermal expansivity of liquid water at 25 °C, 1/K (Kell 1975, J. Chem. Eng. Data 20:97).
const WATER_VOLUME_EXPANSION_PER_K: float = 2.57e-4
## Isothermal compressibility of liquid water at 25 °C, 1/Pa (Kell 1975), and its reciprocal.
const WATER_ISOTHERMAL_COMPRESSIBILITY_PER_PA: float = 4.525e-10
const WATER_BULK_MODULUS_PA: float = 1.0 / WATER_ISOTHERMAL_COMPRESSIBILITY_PER_PA

# --- WATER VAPOUR: THE SATURATION CURVE ---------------------------------------------------------------------
# Specific gas constant of water vapour = universal R (8314.46 J/kmol/K) / molar mass (18.015 kg/kmol).
# Turns that pressure into a DENSITY through the ideal gas law: rho_v = e / (R_v * T_K).
const VAPOUR_GAS_CONST_J_KGK: float = 461.52

# --- ELECTROSTATICS ---------------------------------------------------------------------------------------
const VACUUM_PERMITTIVITY_F_M: float = 8.8541878128e-12   # CODATA eps0

# --- THUNDERSTORM CHARGE SEPARATION -------------------------------------------------------------------------
# Non-inductive graupel/ice riming charges only between these two temperatures (Takahashi 1978,
# Saunders & Peck 1998); outside the band the sign reverses or the mechanism stops.
const CHARGE_ZONE_WARM_C: float = -10.0
const CHARGE_ZONE_COLD_C: float = -25.0
# Volumetric charge separation rate in the mixed-phase zone at full drive, C/m^3/s. Lab-constrained NIC
# parameterisations put the charging zone at 0.1-1 nC/m^3/s; this is the top of that range.
const NIC_CHARGE_RATE_C_M3_S: float = 1.0e-9
# The two drivers the rate saturates against: a mature convective updraft, and the cloud liquid water
# content above which the riming rate stops climbing.
const CONVECTIVE_UPDRAFT_M_S: float = 10.0
const CHARGING_LWC_KG_M3: float = 1.0e-3
# Relativistic runaway electron avalanche threshold at sea-level air density (Dwyer 2003, GRL 30:2055).
# Scales with air density, so it is ~5x lower at 10 km than at the ground; conventional 3 MV/m breakdown
# is never reached in a storm and is not what initiates a flash.
const RREA_THRESHOLD_V_M: float = 2.84e5
# Conductivity of a return-stroke channel, S/m (Rakov & Uman 2003, ch. 12). Eighteen orders above the air
# it replaces: past RREA_THRESHOLD_V_M the dielectric is a conductor.
const LIGHTNING_CHANNEL_CONDUCTIVITY_S_M: float = 1.0e4

# --- ROCK / MAGMA -----------------------------------------------------------------------------------------
const BASALT_LIQUIDUS_C: float = 1200.0
const BASALT_SOLIDUS_C: float = 1000.0
# Crystal-free basaltic melt at its liquidus, Pa s (Giordano, Russell & Dingwell 2008, EPSL 271:123).
const BASALT_MELT_VISCOSITY_PA_S: float = 100.0
# Einstein-Roscoe suspension viscosity, mu = mu_melt * (1 - phi/phi_max)^-n (Roscoe 1952, Br J Appl Phys
# 3:267); n is Einstein's own 2.5 for rigid spheres, not a fitted exponent.
const EINSTEIN_ROSCOE_EXPONENT: float = 2.5

# --- UPPER CRUST ------------------------------------------------------------------------------------------
const GROUNDWATER_CIRCULATION_M: float = 2000.0

# --- THERMAL TRANSPORT ------------------------------------------------------------------------------------
# Conductivity lambda, W/m/K. Volumetric heat capacity rho*c, J/m^3/K.
const THERMAL_CONDUCT_ROCK_W_MK: float = 2.5
const THERMAL_CONDUCT_WATER_W_MK: float = 0.60
const ROCK_DENSITY_KG_M3: float = 2900.0
## Volumetric thermal expansivity of rock, 1/K. Skinner 1966, GSA Memoir 97, puts rocks at 15-33e-6 /°C;
## basalt carries no quartz (3.3e-5, Fei 1995) and sits at the low end of that span.
const ROCK_VOLUME_EXPANSION_PER_K: float = 1.5e-5
## Isothermal bulk modulus of the basalt mineral matrix, Pa. Adam & Otheim 2013, JGR Solid Earth 118, give
## Voigt-Reuss-Hill mineral moduli of 80.1 and 84.1 GPa on two basalt samples.
const ROCK_BULK_MODULUS_PA: float = 8.0e10
const ROCK_SPECIFIC_HEAT_J_KGK: float = 840.0
const VOL_HEAT_CAP_AIR_J_M3K: float = AIR_DENSITY_KG_M3 * AIR_SPECIFIC_HEAT_J_KGK
const VOL_HEAT_CAP_WATER_J_M3K: float = WATER_DENSITY_KG_M3 * WATER_SPECIFIC_HEAT_J_KGK

# --- RADIOGENIC HEATING -----------------------------------------------------------------------------------
# Bulk silicate Earth abundance, kg of element per kg of rock. McDonough & Sun 1995, Chem. Geol. 120:223
# (U 20.3 ng/g, Th 79.5 ng/g, K 240 ug/g).
const BSE_U_KG_PER_KG: float = 20.3e-9
const BSE_TH_KG_PER_KG: float = 79.5e-9
const BSE_K_KG_PER_KG: float = 240.0e-6
# The four nuclides that produce essentially all of it. Half-lives, years — Audi et al. 2003, Nucl. Phys.
# A729:3 (NUBASE). Decay energy per decay, MeV, summed over each chain to its stable daughter and NET of
# the neutrino energy that escapes the planet — Ruedas 2017, Geochem. Geophys. Geosyst. 18:3530.
const HALF_LIFE_U238_YEARS: float = 4.468e9
const HALF_LIFE_U235_YEARS: float = 7.04e8
const HALF_LIFE_TH232_YEARS: float = 1.405e10
const HALF_LIFE_K40_YEARS: float = 1.248e9
const DECAY_ENERGY_U238_MEV: float = 47.31
const DECAY_ENERGY_U235_MEV: float = 44.63
const DECAY_ENERGY_TH232_MEV: float = 40.29
const DECAY_ENERGY_K40_MEV: float = 0.6485
# Present-day isotopic abundance of the natural element, kg of nuclide per kg of element. Uranium and
# potassium — Meija et al. 2016, Pure Appl. Chem. 88:293 (IUPAC). Thorium is monoisotopic.
const ISOTOPE_FRAC_U238: float = 0.992742
const ISOTOPE_FRAC_U235: float = 0.007204
const ISOTOPE_FRAC_TH232: float = 1.0
const ISOTOPE_FRAC_K40: float = 1.17e-4
const MOLAR_MASS_U238_KG_MOL: float = 0.238051
const MOLAR_MASS_U235_KG_MOL: float = 0.235044
const MOLAR_MASS_TH232_KG_MOL: float = 0.232038
const MOLAR_MASS_K40_KG_MOL: float = 0.0399640
const MEV_J: float = 1.602176634e-13            # CODATA 2018, exact from the elementary charge

# --- ENERGY BUDGET ----------------------------------------------------------------------------------------
const SOLAR_CONSTANT_W_M2: float = 1361.0
const STEFAN_BOLTZMANN: float = 5.670374419e-8
## Newton's constant, m^3 kg^-1 s^-2 (CODATA 2018).
const GRAVITATIONAL_CONSTANT: float = 6.67430e-11
const KELVIN_OFFSET: float = 273.15

# Mean geothermal heat flux out of Earth's surface, against ~340 W/m² of mean absorbed sunlight — a ratio
# near 1:4000. Any build where the interior is a comparable term to the sun has its crust conductivity wrong,
# and that measurement is the check for it.
const GEOTHERMAL_FLUX_W_M2: float = 0.087

# Greybody optical depth of a sea-level air column, back-derived from Earth's own greenhouse: a 288 K surface
# against a 255 K effective radiating temperature gives (288/255)^4 = 1.626 = 1 + 0.75*tau.
const ATMOS_OPTICAL_DEPTH: float = 0.835

# --- SURFACE ALBEDO ---------------------------------------------------------------------------------------
# brightest. (Earth's ~0.30 PLANETARY albedo includes clouds, which this substrate models separately, so the
# surface values belong here and the cloud contribution does not.)
const ALBEDO_OCEAN: float = 0.06
const ALBEDO_BARE_GROUND: float = 0.15
const ALBEDO_SNOW_ICE: float = 0.65

## O2 mass in a cubic metre of ambient air, kg/m^3 — the air density times the O2 mass fraction, both
## already declared in this file, so this cannot disagree with them.
const AMBIENT_O2_DENSITY_KG_M3: float = AIR_DENSITY_KG_M3 * AIR_MOLE_FRAC_O2 \
	* MOLAR_MASS_O2_KG_MOL / MOLAR_MASS_DRY_AIR_KG_MOL

# --- REGOLITH ---------------------------------------------------------------------------------------------
const REGOLITH_SURFACE_POROSITY: float = 0.40
const COMPACTION_LENGTH_M: float = 2500.0

const GRAIN_D_UPLAND_M: float = 6.0e-5      # 0.06 mm — very fine sand / coarse silt (residual saprolite)
const GRAIN_D_LOWLAND_M: float = 4.0e-3     # 4 mm — fine gravel (valley-fill alluvium)

# --- GRANULAR MECHANICS: THE ANGLE OF REPOSE ------------------------------------------------------------------
const REPOSE_TAN_DRY_GRANULAR: float = 0.70


## Saturation vapour concentration, mol/m^3: Magnus e_sat put through the ideal gas law, n = e / (R T).
static func saturation_vapour_mol_m3(t_c: float) -> float:
	var e_sat: float = LASubstances.saturation_p_at("h2o", t_c)
	return e_sat / (GAS_CONSTANT_J_MOL_K * maxf(t_c + KELVIN_OFFSET, 1.0))
# --- LIVING TISSUE ----------------------------------------------------------------------------------------
# muscle ~1060, fat ~920, whole-body ~1010 kg/m³. 1000 is the honest round value and it is why an animal
const ANIMAL_TISSUE_DENSITY_KG_M3: float = 1000.0

const PROTEIN_DENATURE_C: float = 45.0

# --- UNIVERSAL CONSTANTS ------------------------------------------------------------------------------------
const PLANET_ANGULAR_VELOCITY_RAD_S: float = 7.2921159e-5   # Earth sidereal rotation, 2*pi/86164.1 s
## Coriolis parameter is f = CORIOLIS_TWO_OMEGA_RAD_S * sin(latitude).
const CORIOLIS_TWO_OMEGA_RAD_S: float = PLANET_ANGULAR_VELOCITY_RAD_S * 2.0
const GAS_CONSTANT_J_MOL_K: float = 8.314462618     # CODATA molar gas constant R
const SECONDS_PER_YEAR: float = 3.15576e7           # Julian year, 365.25 days

# --- MOLAR MASSES (IUPAC 2021 standard atomic weights) ------------------------------------------------------
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
## Volumetric thermal expansivity at 300 K, 1/K (Fei 1995, AGU Reference Shelf 2:29).
const QUARTZ_VOLUME_EXPANSION_PER_K: float = 3.3e-5
const CALCITE_VOLUME_EXPANSION_PER_K: float = 1.4e-5
## Adiabatic bulk modulus of alpha-quartz, Pa (Bass 1995, AGU Reference Shelf 2:45). Calcite has no
## companion here: the single-crystal C_ij are published but no aggregate modulus was found to cite.
const QUARTZ_BULK_MODULUS_PA: float = 3.78e10

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
## Volumetric thermal expansivity of ice Ih near 265 K, 1/K (Röttger et al. 1994, Acta Cryst B50:644).
const ICE_VOLUME_EXPANSION_PER_K: float = 1.6e-4
## Isothermal bulk modulus of ice Ih at 273 K, Pa (Neumeier 2018, J. Phys. Chem. Ref. Data 47:033101).
const ICE_BULK_MODULUS_PA: float = 8.4e9

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
#     P = ROCK_DENSITY_KG_M3 * g * GROUNDWATER_CIRCULATION_M
const LITHIFICATION_PRESSURE_PA: float = 5.688e7
# Per step per Pa of pressure above the threshold, the share of a cell's uncemented silicate that
# consolidates. Inherited, unreviewed — docs/MODEL_PARAMETERS.md.
const LITHIFICATION_RATE_PER_PA: float = 1.0e-9

# --- PLATE MOTION -------------------------------------------------------------------------------------------
const PLATE_SPEED_MIN_MM_PER_YEAR: float = 10.0
const PLATE_SPEED_MAX_MM_PER_YEAR: float = 100.0
# --- THE COMPOSITION OF AIR -------------------------------------------------------------------------------
const AIR_MOLE_FRAC_N2: float = 0.78084     # NASA/NOAA standard atmosphere, dry air
const AIR_MOLE_FRAC_O2: float = 0.20946
const AIR_MOLE_FRAC_AR: float = 0.00934
const AIR_MOLE_FRAC_CO2: float = 0.000419   # NOAA GML global annual mean, 2023

# ============================================================================================================
# Dry air, from the mole fractions above and the molar masses above. M_air = sum(x_i * M_i) — a real
# weighted mean, not a stored 0.02896 whose derivation lives in a comment.
const MOLAR_MASS_DRY_AIR_KG_MOL: float = \
	AIR_MOLE_FRAC_N2 * MOLAR_MASS_N2_KG_MOL \
	+ AIR_MOLE_FRAC_O2 * MOLAR_MASS_O2_KG_MOL \
	+ AIR_MOLE_FRAC_AR * MOLAR_MASS_AR_KG_MOL \
	+ AIR_MOLE_FRAC_CO2 * MOLAR_MASS_CO2_KG_MOL
const DRY_AIR_GAS_CONSTANT_J_KGK: float = GAS_CONSTANT_J_MOL_K / MOLAR_MASS_DRY_AIR_KG_MOL
## Molar density of air at ISA sea level, mol/m^3: n = rho / M. Multiply by a mole fraction above for the
## concentration of one of its gases, which is what a gas channel carries.
const AIR_MOLAR_DENSITY_MOL_M3: float = AIR_DENSITY_KG_M3 / MOLAR_MASS_DRY_AIR_KG_MOL


# --- ORGANIC MATTER: THE CARBON-TO-NITROGEN RATIO ---------------------------------------------------------
# Litter, mol C per mol N (Batjes 1996).
const LITTER_C_TO_N: float = 20.0
# --- SHORTWAVE IS NOT LONGWAVE, AND THE DIFFERENCE *IS* THE GREENHOUSE --------------------------------------
# Beer-Lambert vertical optical depth for shortwave, from the 78 of 341 W/m^2 Earth's atmosphere absorbs
# at the top of the atmosphere (Trenberth, Fasullo & Kiehl 2009, BAMS 90:311).
const ATMOS_SW_OPTICAL_DEPTH: float = 0.2597

const AIR_MASS_HORIZON: float = 38.0

# --- LIGHTNING --------------------------------------------------------------------------------------------
const LIGHTNING_FLASH_J: float = 1.0e9

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

# --- SPECIFIC HEATS, J/kg/K ---------------------------------------------------------------------------------
const WATER_SPECIFIC_HEAT_J_KGK: float = 4184.0     # liquid water, 25 C
const ICE_SPECIFIC_HEAT_J_KGK: float = 2090.0       # ice at 0 C — HALF liquid water's, which is why a snowpack
                                                    # swings temperature so much faster than a lake
const VAPOUR_SPECIFIC_HEAT_J_KGK: float = 1996.0    # water vapour at constant pressure, 100 C
const AIR_SPECIFIC_HEAT_J_KGK: float = 1005.0       # dry air at constant pressure, 300 K
const AIR_DENSITY_KG_M3: float = 1.225            # ISA sea level: 101325 Pa, 15 C, dry
## Specific heat of dry air at constant VOLUME, by Mayer's relation cv = cp - R.
const AIR_SPECIFIC_HEAT_CV_J_KGK: float = AIR_SPECIFIC_HEAT_J_KGK - DRY_AIR_GAS_CONSTANT_J_KGK
## Ratio of specific heats. It is what makes the speed of sound sqrt(gamma * R * T), not sqrt(R * T).
const AIR_ADIABATIC_INDEX: float = AIR_SPECIFIC_HEAT_J_KGK / AIR_SPECIFIC_HEAT_CV_J_KGK
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

# Thermal-infrared emissivity of a water surface. Near-blackbody, which is why sea-surface temperature
# can be measured from orbit at all.
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

# Foliage as a fraction of standing plant mass. Stems and roots carry the mass, leaves carry the area
# (Bar-On, Phillips & Milo 2018).
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
const LIGHTNING_N_FIXED_MOL_PER_FLASH: float = 250.0
const LIGHTNING_N_FIXED_MOL_PER_J: float = LIGHTNING_N_FIXED_MOL_PER_FLASH / LIGHTNING_FLASH_J


# --- THE ATOMS ORGANIC MATTER IS MADE OF ------------------------------------------------------------------
# Atomic, not molecular: the dead organic pool is stored as element stocks (LASubstances organic_c/h/o) so
# its C:H:O ratio is per-cell state. IUPAC 2021 standard atomic weights, g/mol -> kg/mol.
const MOLAR_MASS_HYDROGEN_KG_MOL: float = 0.00100794   # H
const MOLAR_MASS_OXYGEN_KG_MOL: float = 0.0159994      # O

# --- COALIFICATION KINETICS -------------------------------------------------------------------------------
# Burial heats organic matter and it loses H2O, then CO2, then CH4, drifting toward carbon. Sweeney & Burnham
const VITRINITE_FREQUENCY_FACTOR_PER_S: float = 1.0e13
const KCAL_PER_MOL_TO_J_MOL: float = 4184.0
const COAL_DEHYDRATION_EA_J_MOL: float = 34.0 * KCAL_PER_MOL_TO_J_MOL
const COAL_DEHYDRATION_EA_OVER_R_K: float = COAL_DEHYDRATION_EA_J_MOL / GAS_CONSTANT_J_MOL_K
const COAL_DECARBOXYLATION_EA_J_MOL: float = 36.0 * KCAL_PER_MOL_TO_J_MOL
const COAL_DECARBOXYLATION_EA_OVER_R_K: float = COAL_DECARBOXYLATION_EA_J_MOL / GAS_CONSTANT_J_MOL_K

# --- RADIATIVE TRANSFER -------------------------------------------------------------------------------------
const SPEED_OF_LIGHT_M_S: float = 299792458.0        # CODATA, exact by definition of the metre
## Second radiation constant h*c/k, in cm K, so it pairs with a wavenumber in cm^-1: x = PLANCK_C2_CM_K*nu/T.
const PLANCK_C2_CM_K: float = PLANCK_J_S * SPEED_OF_LIGHT_M_S / BOLTZMANN_J_K * 100.0
## Diffusivity factor: the secant of the effective slant angle a hemispheric flux takes through a plane
## layer. Elsasser (1942); the standard two-stream value, reproduced in Goody & Yung ch. 2.
const TWO_STREAM_DIFFUSIVITY: float = 1.66
## Pressure the absorption coefficients in LAAbsorptionBands are stated at. Pierrehumbert, Principles of
## Planetary Climate section 4.4.7 adopts 100 mb, 260 K, air-broadened as the standard state.
const ABSORPTION_REF_PRESSURE_PA: float = 1.0e4
## Density one unit of the `co2` channel carries. The gas channels are defined so that one unit is the same
## MOLAR concentration as one unit of `o2`, so this is that concentration expressed as a CO2 mass.
const CO2_UNIT_DENSITY_KG_M3: float = AMBIENT_O2_DENSITY_KG_M3 * MOLAR_MASS_CO2_KG_MOL / MOLAR_MASS_O2_KG_MOL
## Thermal-infrared emissivity of snow and ice. Near-blackbody: Warren (1982, Rev. Geophys. 20:67) and
## Dozier & Warren (1982) put broadband 8-14 um emissivity of snow at 0.98-0.99.
const EMISSIVITY_SNOW: float = 0.99
## Specific gas constant of CO2 = universal R / molar mass. Turns a CO2 mass density into its partial
## pressure, which is what broadens the CO2-CO2 collision-induced absorption.
const CO2_GAS_CONST_J_KGK: float = GAS_CONSTANT_J_MOL_K / MOLAR_MASS_CO2_KG_MOL
## Solar effective temperature, K. IAU 2015 Resolution B3 nominal solar luminosity and radius give
## 5772 K. Used as the blackbody whose spectrum splits the solar constant across absorption bands.
const SOLAR_EFFECTIVE_TEMPERATURE_K: float = 5772.0


# Rheological critical melt fraction: the framework locks near 0.6 crystals and does not remobilise until
# melt is back to 0.4 (Marsh 1981; Vigneresse, Barbey & Cuney 1996). Real hysteresis, not a guard.
const RHEOLOGICAL_LOCKUP_CRYSTAL_FRAC: float = 0.6
const RHEOLOGICAL_MOBILE_CRYSTAL_FRAC: float = 0.4

# --- VISCOSITY AND SUBGRID MOMENTUM FLUX ---------------------------------------------------------------
# Dynamic viscosity: the transport laws divide by it, so a mobility is a material property rather than a
# dial. Kestin, Sokolov & Wakeham 1978, J. Phys. Chem. Ref. Data 7:941 (water); Kadoya, Matsunaga &
# Nagashima 1985, ibid. 14:947 (air).
const WATER_DYNAMIC_VISCOSITY_PA_S: float = 1.002e-3    # liquid water at 20 C
const AIR_DYNAMIC_VISCOSITY_PA_S: float = 1.81e-5       # dry air at 15 C, 1 atm
# Kozeny-Carman shape factor for packed beds. Carman 1937, Trans. Inst. Chem. Eng. 15:150.
const KOZENY_CARMAN_C: float = 180.0
# Smagorinsky 1963 eddy viscosity, nu = (C_s * grid)^2 * |S|. Lilly 1967 DERIVES C_s from the Kolmogorov
# constant rather than fitting it: C_s = (1/pi) * (3 * C_K / 2)^(-3/4).
const KOLMOGOROV_CONSTANT: float = 1.6
const SMAGORINSKY_COEFF: float = (1.0 / PI) * pow(1.5 * KOLMOGOROV_CONSTANT, -0.75)

# Air conductivity. Charge relaxes ohmically with time constant eps0/sigma, so these ARE the leak: ~885 s
# inside cloud (droplets and ice scavenge the small ions that carry the current), ~89 s in clear air.
# Gringel, Rosen & Hofmann 1986, in The Earth's Electrical Environment (NAS), fair-weather profile.
const CLOUD_CONDUCTIVITY_S_M: float = 1.0e-14
const CLEAR_AIR_CONDUCTIVITY_S_M: float = 1.0e-13

# Thermal conductivity lambda, W/m/K, at 300 K and 1 bar for the gases. Lemmon & Jacobsen 2004,
# Int. J. Thermophys. 25:21 (O2); Huber et al. 2016, J. Phys. Chem. Ref. Data 45:013102 (CO2).
const THERMAL_CONDUCT_O2_GAS_W_MK: float = 0.02658
const THERMAL_CONDUCT_CO2_GAS_W_MK: float = 0.01665
# Dry cell-wall material along the grain. Wood is a cellular solid, so a real board conducts less than
# this by its porosity; the substrate carries that porosity separately. Sonderegger et al. 2011,
# Holzforschung 65:369.
const THERMAL_CONDUCT_CELLULOSE_W_MK: float = 0.40
# Amorphous carbon / dry soil organic matter. Farouki 1981, CRREL Monograph 81-1.
const THERMAL_CONDUCT_ORGANIC_W_MK: float = 0.25
