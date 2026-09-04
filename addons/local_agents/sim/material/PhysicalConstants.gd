class_name LAPhysical
extends RefCounted


const WATER_FREEZE_C: float = 0.0
const WATER_MELT_C: float = 0.0
const WATER_BOIL_C: float = 100.0
const WATER_DENSITY_KG_M3: float = 997.0    # liquid water at 25 C
## Volumetric thermal expansivity of liquid water at 25 °C, 1/K (Kell 1975, J. Chem. Eng. Data 20:97).
const WATER_VOLUME_EXPANSION_PER_K: float = 2.57e-4
# Saturated liquid water, rho/rho_c = 1 + sum b_i tau^(k_i), tau = 1 - T/T_c: IAPWS SR1-86 (1992).
const WATER_CRITICAL_DENSITY_KG_M3: float = 322.0   # IAPWS SR1-86 (1992)
const IAPWS_SAT_RHO_B1: float = 1.99274064   # IAPWS SR1-86 (1992)
const IAPWS_SAT_RHO_B2: float = 1.09965342   # IAPWS SR1-86 (1992)
const IAPWS_SAT_RHO_B3: float = -0.510839303   # IAPWS SR1-86 (1992)
const IAPWS_SAT_RHO_B4: float = -1.75493479   # IAPWS SR1-86 (1992)
const IAPWS_SAT_RHO_B5: float = -45.5170352   # IAPWS SR1-86 (1992)
const IAPWS_SAT_RHO_B6: float = -6.74694450e5   # IAPWS SR1-86 (1992)
## Isothermal compressibility of liquid water at 25 °C, 1/Pa (Kell 1975), and its reciprocal.
const WATER_ISOTHERMAL_COMPRESSIBILITY_PER_PA: float = 4.525e-10
const WATER_BULK_MODULUS_PA: float = 1.0 / WATER_ISOTHERMAL_COMPRESSIBILITY_PER_PA

## Specific gas constant of water vapour, J/kg/K = R / molar mass.
const VAPOUR_GAS_CONST_J_KGK: float = 461.52

const VACUUM_PERMITTIVITY_F_M: float = 8.8541878128e-12   # CODATA eps0

## Non-inductive riming charge-separation band (Takahashi 1978; Saunders & Peck 1998).
const CHARGE_ZONE_WARM_C: float = -10.0
const CHARGE_ZONE_COLD_C: float = -25.0
## Volumetric charge separation rate in the mixed-phase zone at full drive, C/m^3/s.
const NIC_CHARGE_RATE_C_M3_S: float = 1.0e-9
## Updraft speed and cloud liquid water content the charging rate saturates against.
const CONVECTIVE_UPDRAFT_M_S: float = 10.0
const CHARGING_LWC_KG_M3: float = 1.0e-3
## Relativistic runaway electron avalanche threshold at sea-level air density (Dwyer 2003, GRL 30:2055).
const RREA_THRESHOLD_V_M: float = 2.84e5
## Conductivity of a return-stroke channel, S/m (Rakov & Uman 2003, ch. 12).
const LIGHTNING_CHANNEL_CONDUCTIVITY_S_M: float = 1.0e4

const BASALT_LIQUIDUS_C: float = 1200.0
const BASALT_SOLIDUS_C: float = 1000.0
## Crystal-free basaltic melt at its liquidus, Pa s (Giordano, Russell & Dingwell 2008, EPSL 271:123).
const BASALT_MELT_VISCOSITY_PA_S: float = 100.0
## Exponent n of mu = mu_melt * (1 - phi/phi_max)^-n (Roscoe 1952, Br J Appl Phys 3:267).
const EINSTEIN_ROSCOE_EXPONENT: float = 2.5

const GROUNDWATER_CIRCULATION_M: float = 2000.0

## Thermal conductivity lambda, W/m/K.
const THERMAL_CONDUCT_ROCK_W_MK: float = 2.5
const THERMAL_CONDUCT_WATER_W_MK: float = 0.60
const ROCK_DENSITY_KG_M3: float = 2900.0
## Volumetric thermal expansivity of rock, 1/K. Skinner 1966, GSA Memoir 97, puts rocks at 15-33e-6 /°C;
## basalt carries no quartz (3.3e-5, Fei 1995) and sits at the low end of that span.
const ROCK_VOLUME_EXPANSION_PER_K: float = 1.5e-5
## Isothermal bulk modulus of the basalt mineral matrix, Pa. Adam & Otheim 2013, JGR Solid Earth 118, give
## Voigt-Reuss-Hill mineral moduli of 80.1 and 84.1 GPa on two basalt samples.
const ROCK_BULK_MODULUS_PA: float = 8.0e10
## Uniaxial tensile strength of intact basalt, Pa (Schultz 1995, Rock Mech. Rock Eng. 28:1, 14.5±3.3 MPa).
const BASALT_TENSILE_STRENGTH_PA: float = 1.45e7
const ROCK_SPECIFIC_HEAT_J_KGK: float = 840.0
const VOL_HEAT_CAP_AIR_J_M3K: float = AIR_DENSITY_KG_M3 * AIR_SPECIFIC_HEAT_J_KGK
const VOL_HEAT_CAP_WATER_J_M3K: float = WATER_DENSITY_KG_M3 * WATER_SPECIFIC_HEAT_J_KGK

## Limestone and sandstone, kg of element per kg of rock (Turekian & Wedepohl 1961, GSA Bull. 72:175).
const LIMESTONE_U_KG_PER_KG: float = 2.2e-6
const LIMESTONE_TH_KG_PER_KG: float = 1.7e-6
const LIMESTONE_K_KG_PER_KG: float = 2700.0e-6
const SANDSTONE_U_KG_PER_KG: float = 0.45e-6
const SANDSTONE_TH_KG_PER_KG: float = 1.7e-6
const SANDSTONE_K_KG_PER_KG: float = 10700.0e-6
## Age of the Earth, years: Pb-Pb isochron over meteorites and terrestrial lead (Patterson 1956, Geochim.
## Cosmochim. Acta 10:230; Dalrymple 1991, The Age of the Earth, 4.54 +/- 0.05 Ga).
const EARTH_FORMATION_AGE_YEARS: float = 4.54e9
## Half-lives, years (Audi et al. 2003, NUBASE). Decay energy per decay, MeV, net of neutrino loss
## (Ruedas 2017, Geochem. Geophys. Geosyst. 18:3530).
const HALF_LIFE_U238_YEARS: float = 4.468e9
const HALF_LIFE_U235_YEARS: float = 7.04e8
const HALF_LIFE_TH232_YEARS: float = 1.405e10
const HALF_LIFE_K40_YEARS: float = 1.248e9
const DECAY_ENERGY_U238_MEV: float = 47.31
const DECAY_ENERGY_U235_MEV: float = 44.63
const DECAY_ENERGY_TH232_MEV: float = 40.29
const DECAY_ENERGY_K40_MEV: float = 0.6485
## Present-day isotopic abundance, kg of nuclide per kg of element (Meija et al. 2016, IUPAC).
const ISOTOPE_FRAC_U238: float = 0.992742
const ISOTOPE_FRAC_U235: float = 0.007204
const ISOTOPE_FRAC_TH232: float = 1.0
const ISOTOPE_FRAC_K40: float = 1.17e-4
const MOLAR_MASS_U238_KG_MOL: float = 0.238051
const MOLAR_MASS_U235_KG_MOL: float = 0.235044
const MOLAR_MASS_TH232_KG_MOL: float = 0.232038
const MOLAR_MASS_K40_KG_MOL: float = 0.0399640
## K40 branching: beta-minus to Ca40, electron capture to Ar40 (Renne et al. 2010, GCA 74:5349).
const K40_BETA_FRAC: float = 0.8928
const K40_EC_FRAC: float = 0.1072
## Core / Earth mass fraction (McDonough 2003, Treatise on Geochemistry 2.15, Table 1).
const EARTH_CORE_MASS_FRACTION: float = 0.323
const MEV_J: float = 1.602176634e-13            # CODATA 2018, exact from the elementary charge

## THE ONE EPOCH — the Jack Hills zircon age (Wilde et al. 2001, Nature 409:175). Luminosity and
## rotation derive from it, so moving the world in time is this one edit.
const PLANET_EPOCH_YEARS_BEFORE_PRESENT: float = 4.404e9
## Share of absorbed XUV that powers escape (Erkaev et al. 2013, Astrobiology 13:1011; bounded near
## 0.2 by Shematovich, Ionov & Lammer 2014, A&A 571:A94).
const XUV_HEATING_EFFICIENCY: float = 0.15
## Escape parameter below which thermal escape turns hydrodynamic (Volkov et al. 2011, ApJL 729:L24).
const ESCAPE_PARAM_HYDRODYNAMIC: float = 3.0
const STEFAN_BOLTZMANN: float = 5.670374419e-8
## Newton's constant, m^3 kg^-1 s^-2 (CODATA 2018).
const GRAVITATIONAL_CONSTANT: float = 6.67430e-11
const KELVIN_OFFSET: float = 273.15

## Surface albedo, cloud contribution excluded.
const ALBEDO_OCEAN: float = 0.06
const ALBEDO_BARE_GROUND: float = 0.15
const ALBEDO_SNOW_ICE: float = 0.65

## Molar density of an ideal gas at STP (0 degC, 1 atm), mol/m^3: p / (R T).
const STP_MOLAR_DENSITY_MOL_M3: float = STANDARD_PRESSURE_PA / (GAS_CONSTANT_J_MOL_K * KELVIN_OFFSET)

const REGOLITH_SURFACE_POROSITY: float = 0.40
const COMPACTION_LENGTH_M: float = 2500.0

const GRAIN_D_UPLAND_M: float = 6.0e-5      # very fine sand / coarse silt
const GRAIN_D_LOWLAND_M: float = 4.0e-3     # fine gravel

const REPOSE_TAN_DRY_GRANULAR: float = 0.70


const ANIMAL_TISSUE_DENSITY_KG_M3: float = 1000.0

const PROTEIN_DENATURE_C: float = 45.0

const GAS_CONSTANT_J_MOL_K: float = 8.314462618     # CODATA molar gas constant R
const SECONDS_PER_YEAR: float = 3.15576e7           # Julian year, 365.25 days

# Molar masses, kg/mol (IUPAC 2021 standard atomic weights).
const MOLAR_MASS_WATER_KG_MOL: float = 0.018015     # H₂O
const MOLAR_MASS_N2_KG_MOL: float = 0.0280134       # N₂
const MOLAR_MASS_AR_KG_MOL: float = 0.0399480       # Ar
const MOLAR_MASS_O2_KG_MOL: float = 0.0319988       # O₂
const MOLAR_MASS_CO2_KG_MOL: float = 0.0440095      # CO₂
const MOLAR_MASS_CARBON_KG_MOL: float = 0.0120110   # C
const MOLAR_MASS_NITROGEN_KG_MOL: float = 0.0140067  # N
const MOLAR_MASS_CH2O_UNIT_KG_MOL: float = 0.0300260  # CH2O, the per-carbon cellulose unit

const MOLAR_MASS_CASIO3_KG_MOL: float = 0.1161612    # CaSiO3  40.078 + 28.085 + 3*15.9994
const MOLAR_MASS_SIO2_KG_MOL: float = 0.0600838      # SiO2    28.085 + 2*15.9994
const MOLAR_MASS_CACO3_KG_MOL: float = 0.1000872     # CaCO3   40.078 + 12.011 + 3*15.9994
const QUARTZ_DENSITY_KG_M3: float = 2650.0           # alpha-quartz, 2.65 g/cm^3
const CALCITE_DENSITY_KG_M3: float = 2710.0          # calcite, 2.71 g/cm^3
## Volumetric thermal expansivity at 300 K, 1/K (Fei 1995, AGU Reference Shelf 2:29).
const QUARTZ_VOLUME_EXPANSION_PER_K: float = 3.3e-5
const CALCITE_VOLUME_EXPANSION_PER_K: float = 1.4e-5
## Adiabatic bulk modulus of alpha-quartz, Pa (Bass 1995, AGU Reference Shelf 2:45).
const QUARTZ_BULK_MODULUS_PA: float = 3.78e10

# Formation enthalpy and standard molar entropy at 298.15 K, 1 bar (Robie & Hemingway 1995; CODATA for CO2).
const FORMATION_ENTHALPY_CASIO3_J_MOL: float = -1634900.0   # wollastonite
const FORMATION_ENTHALPY_SIO2_J_MOL: float = -910700.0      # alpha-quartz
const FORMATION_ENTHALPY_CACO3_J_MOL: float = -1207600.0    # calcite
const FORMATION_ENTHALPY_CO2_J_MOL: float = -393510.0
const ENTROPY_CASIO3_J_MOL_K: float = 81.69
const ENTROPY_SIO2_J_MOL_K: float = 41.46
const ENTROPY_CACO3_J_MOL_K: float = 91.7

const ICE_DENSITY_KG_M3: float = 916.7
## Volumetric thermal expansivity of ice Ih near 265 K, 1/K (Röttger et al. 1994, Acta Cryst B50:644).
const ICE_VOLUME_EXPANSION_PER_K: float = 1.6e-4
## Isothermal bulk modulus of ice Ih at 273 K, Pa (Neumeier 2018, J. Phys. Chem. Ref. Data 47:033101).
const ICE_BULK_MODULUS_PA: float = 8.4e9

const ROCK_POROSITY_NEAR_SURFACE: float = 0.05

## Wollastonite dissolution, neutral mechanism at 25 C: log10 k in mol/m^2/s and its activation energy
## (Palandri & Kharaka 2004, USGS Open-File Report 2004-1068).
const WOLLASTONITE_DISSOLUTION_LOG10_K: float = -8.88
const SILICATE_DISSOLUTION_EA_J_MOL: float = 54700.0
const SILICATE_DISSOLUTION_EA_OVER_R_K: float = SILICATE_DISSOLUTION_EA_J_MOL / GAS_CONSTANT_J_MOL_K
## Temperature laboratory dissolution rates are quoted at.
const LAB_REFERENCE_TEMP_C: float = 25.0

# Effective stress at which quartz pressure solution cements sand. Bjorlykke & Egeberg 1993, AAPG 77:1538.
const LITHIFICATION_PRESSURE_PA: float = 6.0e7
# Share of a cell's uncemented silicate that consolidates, per step per Pa above the threshold.
# Inherited, unreviewed — docs/MODEL_PARAMETERS.md.
const LITHIFICATION_RATE_PER_PA: float = 1.0e-9

const AIR_MOLE_FRAC_N2: float = 0.78084     # NASA/NOAA standard atmosphere, dry air
const AIR_MOLE_FRAC_O2: float = 0.20946
const AIR_MOLE_FRAC_AR: float = 0.00934
const AIR_MOLE_FRAC_CO2: float = 0.000419   # NOAA GML global annual mean, 2023

## Dry air molar mass, kg/mol: sum(x_i * M_i) over the mole fractions above.
const MOLAR_MASS_DRY_AIR_KG_MOL: float = \
	AIR_MOLE_FRAC_N2 * MOLAR_MASS_N2_KG_MOL \
	+ AIR_MOLE_FRAC_O2 * MOLAR_MASS_O2_KG_MOL \
	+ AIR_MOLE_FRAC_AR * MOLAR_MASS_AR_KG_MOL \
	+ AIR_MOLE_FRAC_CO2 * MOLAR_MASS_CO2_KG_MOL
const DRY_AIR_GAS_CONSTANT_J_KGK: float = GAS_CONSTANT_J_MOL_K / MOLAR_MASS_DRY_AIR_KG_MOL
## Molar density of air at ISA sea level, mol/m^3.
const AIR_MOLAR_DENSITY_MOL_M3: float = AIR_DENSITY_KG_M3 / MOLAR_MASS_DRY_AIR_KG_MOL


## Litter, mol C per mol N (Batjes 1996).
const LITTER_C_TO_N: float = 20.0
const AIR_MASS_HORIZON: float = 38.0

const LIGHTNING_FLASH_J: float = 1.0e9

const LATENT_HEAT_FUSION_J_KG: float = 3.337e5
const LATENT_HEAT_SUBLIMATION_J_KG: float = 2.834e6

## Basalt enthalpy of crystallisation, J/kg (Lange, Cashman & Navrotsky 1994, CMP 118:169).
const BASALT_LATENT_HEAT_CRYSTALLISATION_J_KG: float = 4.0e5
## Basaltic melt at its liquidus, kg/m^3 (Lange & Carmichael 1987, Rev. Mineral. 24:25).
const BASALT_MELT_DENSITY_KG_M3: float = 2650.0

const BASALT_EMISSIVITY: float = 0.95

const LIMITING_OXYGEN_CONCENTRATION_FRAC: float = 0.15

# Specific heats, J/kg/K.
const WATER_SPECIFIC_HEAT_J_KGK: float = 4184.0     # liquid water, 25 C
const ICE_SPECIFIC_HEAT_J_KGK: float = 2090.0       # ice at 0 C
const VAPOUR_SPECIFIC_HEAT_J_KGK: float = 1996.0    # water vapour at constant pressure, 100 C
const AIR_SPECIFIC_HEAT_J_KGK: float = 1005.0       # dry air at constant pressure, 300 K
const AIR_DENSITY_KG_M3: float = 1.225            # ISA sea level: 101325 Pa, 15 C, dry
## Specific heat of dry air at constant VOLUME, by Mayer's relation cv = cp - R.
const AIR_SPECIFIC_HEAT_CV_J_KGK: float = AIR_SPECIFIC_HEAT_J_KGK - DRY_AIR_GAS_CONSTANT_J_KGK
## Ratio of specific heats, cp/cv.
const AIR_ADIABATIC_INDEX: float = AIR_SPECIFIC_HEAT_J_KGK / AIR_SPECIFIC_HEAT_CV_J_KGK
const CALCITE_SPECIFIC_HEAT_J_KGK: float = 820.0    # CaCO3, calcite, 25 C
const QUARTZ_SPECIFIC_HEAT_J_KGK: float = 740.0     # SiO2, alpha-quartz, 25 C

const LATENT_HEAT_VAPORISATION_0C_J_KG: float = 2.501e6

const WATER_TRIPLE_T_C: float = 0.01                 # IAPWS, 273.16 K exactly by definition
const WATER_TRIPLE_P_PA: float = 611.657              # IAPWS triple-point pressure
const WATER_CRITICAL_T_C: float = 373.946            # IAPWS-95 critical temperature, 647.096 K
const WATER_CRITICAL_P_PA: float = 2.2064e7          # IAPWS-95 critical pressure, 220.64 bar
const STANDARD_PRESSURE_PA: float = 101325.0         # one standard atmosphere, the reference boil_c is quoted at
const WATSON_LATENT_EXPONENT: float = 0.38           # Watson correlation exponent for the latent-heat curve

const EV_TO_J_PER_MOL: float = 96485.33              # CODATA Faraday constant, J/(mol*V)

# Atomisation enthalpy: gas molecule -> free atoms, J/mol at 298 K.
const ATOMISATION_H2O_J_MOL: float = 9.269e5         # 2 x O-H, 926.9 kJ/mol (from dfH of H2O, H, O)
const ATOMISATION_O2_J_MOL: float = 4.9834e5         # O=O, 498.34 kJ/mol
const ATOMISATION_CO2_J_MOL: float = 1.5980e6        # 2 x C=O, 1598 kJ/mol
const ATOMISATION_N2_J_MOL: float = 9.4533e5         # N#N, 945.33 kJ/mol

# First ionisation energy per element, eV (NIST Atomic Spectra Database).
const IONISATION_EV_H: float = 13.598
const IONISATION_EV_O: float = 13.618
const IONISATION_EV_C: float = 11.260
const IONISATION_EV_N: float = 14.534
const IONISATION_EV_S: float = 10.360
const IONISATION_EV_SI: float = 8.152
const IONISATION_EV_CA: float = 6.113
const IONISATION_EV_FE: float = 7.902
const IONISATION_EV_MG: float = 7.646
const IONISATION_EV_AL: float = 5.986

const PLANCK_J_S: float = 6.62607015e-34             # CODATA, exact
const BOLTZMANN_J_K: float = 1.380649e-23            # CODATA, exact
const N2_KINETIC_DIAMETER_M: float = 3.64e-10   # kinetic diameter of N2, m: Ismail, Khulbe & Matsuura 2015, table 2.1
const KNUDSEN_CONTINUUM_LIMIT: float = 0.1      # slip flow ends, the transition regime begins: Schaaf & Chambre 1961; Bird 1994
const ELECTRON_MASS_KG: float = 9.1093837015e-31     # CODATA
const AVOGADRO_PER_MOL: float = 6.02214076e23        # CODATA, exact

# Ground-state electronic degeneracies, neutral then singly-ionised (NIST ASD term symbols).
const DEGEN_H_0: float = 2.0     # H  2S(1/2)
const DEGEN_H_1: float = 1.0     # H+ bare proton
const DEGEN_O_0: float = 9.0     # O  3P(2)
const DEGEN_O_1: float = 4.0     # O+ 4S(3/2)
const DEGEN_C_0: float = 9.0     # C  3P(0)
const DEGEN_C_1: float = 6.0     # C+ 2P(1/2)
const DEGEN_N_0: float = 4.0     # N  4S(3/2)
const DEGEN_N_1: float = 9.0     # N+ 3P(0)
const DEGEN_S_0: float = 5.0     # S  3P(2)
const DEGEN_S_1: float = 4.0     # S+ 4S(3/2)

# Standard molar entropies at 298.15 K, 1 bar, J/(mol K) (NIST-JANAF).
const ENTROPY_H_ATOM_J_MOLK: float = 114.717
const ENTROPY_O_ATOM_J_MOLK: float = 161.058
const ENTROPY_C_ATOM_J_MOLK: float = 158.100
const ENTROPY_N_ATOM_J_MOLK: float = 153.301
const ENTROPY_S_ATOM_J_MOLK: float = 167.829

## Thermal-infrared emissivity of a water surface.
const EMISSIVITY_WATER: float = 0.96

## Oven-dry softwood, kg/m3; measured span 400-600 across species.
const DRY_WOOD_DENSITY_KG_M3: float = 500.0
const DRY_WOOD_SPECIFIC_HEAT_J_KGK: float = 1500.0

## Cellulose pyrolysis, first-order Arrhenius pair from one fit of ten Avicel TG runs
## (Antal, Varhegyi & Jakab 1998, Ind. Eng. Chem. Res. 37:1267): E = 237 kJ/mol, log10 A/s^-1 = 18.0.
const CELLULOSE_PYROLYSIS_EA_J_MOL: float = 2.37e5
const CELLULOSE_PYROLYSIS_A_PER_S: float = 1.0e18   # Antal, Varhegyi & Jakab 1998
const CELLULOSE_PYROLYSIS_EA_OVER_R_K: float = CELLULOSE_PYROLYSIS_EA_J_MOL / GAS_CONSTANT_J_MOL_K

const ALBEDO_VEGETATION: float = 0.12

# Dinitrogen, from the NIST Chemistry WebBook (CAS 7727-37-9) unless another source is named.
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

# Dioxygen, NIST Chemistry WebBook (CAS 7782-44-7) unless another source is named.
const O2_BOIL_C: float = -182.962                    # normal boiling point 90.188 K
const O2_TRIPLE_T_C: float = -218.789                # triple point 54.361 K
const O2_TRIPLE_P_PA: float = 146.3                  # triple-point pressure
const O2_CRITICAL_T_C: float = -118.569              # critical point 154.581 K
const O2_CRITICAL_P_PA: float = 5.043e6
const VAP_ENTHALPY_O2_J_MOL: float = 6820.0          # dHvap at 90.188 K
const FUS_ENTHALPY_O2_J_MOL: float = 444.0           # dHfus at the triple point (CRC 97th ed.)
const LATENT_HEAT_VAPORISATION_O2_J_KG: float = VAP_ENTHALPY_O2_J_MOL / MOLAR_MASS_O2_KG_MOL
const LATENT_HEAT_FUSION_O2_J_KG: float = FUS_ENTHALPY_O2_J_MOL / MOLAR_MASS_O2_KG_MOL
const MOLAR_HEAT_CAP_O2_GAS_J_MOLK: float = 29.378   # cp of the gas at 298.15 K, 1 bar
const O2_GAS_SPECIFIC_HEAT_J_KGK: float = MOLAR_HEAT_CAP_O2_GAS_J_MOLK / MOLAR_MASS_O2_KG_MOL
const O2_LIQUID_SPECIFIC_HEAT_J_KGK: float = 1699.0  # saturated liquid at 90.188 K (Lemmon et al.)

# Carbon dioxide, Span & Wagner 1996, J. Phys. Chem. Ref. Data 25:1509, unless another source is named.
const CO2_TRIPLE_T_C: float = -56.558                # triple point 216.592 K
const CO2_TRIPLE_P_PA: float = 5.1795e5              # 0.51795 MPa: above 1 atm, so dry ice sublimes
const CO2_CRITICAL_T_C: float = 30.978               # critical point 304.128 K
const CO2_CRITICAL_P_PA: float = 7.3773e6
# CO2 has no 1-atm boiling point; the vapour curve's second measured anchor is saturation at 0 C.
const CO2_SAT_REF_T_C: float = 0.0
const CO2_SAT_REF_P_PA: float = 3.4851e6
const FUS_ENTHALPY_CO2_J_MOL: float = 9020.0         # dHfus at the triple point (CRC 97th ed.)
const LATENT_HEAT_FUSION_CO2_J_KG: float = FUS_ENTHALPY_CO2_J_MOL / MOLAR_MASS_CO2_KG_MOL
const CO2_LATENT_VAPORISATION_J_KG: float = 3.481e5  # saturated liquid at the triple point
const MOLAR_HEAT_CAP_CO2_GAS_J_MOLK: float = 37.129  # cp of the gas at 298.15 K, 1 bar
const CO2_GAS_SPECIFIC_HEAT_J_KGK: float = MOLAR_HEAT_CAP_CO2_GAS_J_MOLK / MOLAR_MASS_CO2_KG_MOL
const CO2_LIQUID_SPECIFIC_HEAT_J_KGK: float = 1962.0 # saturated liquid at 220 K
const DRY_ICE_DENSITY_KG_M3: float = 1562.0          # solid CO2 at 194.7 K (CRC 97th ed.)

# Dihydrogen, NIST Chemistry WebBook (CAS 1333-74-0); liquid cp from Leachman et al. 2009,
# J. Phys. Chem. Ref. Data 38:721.
const MOLAR_MASS_H2_KG_MOL: float = 2.0 * MOLAR_MASS_HYDROGEN_KG_MOL
const H2_BOIL_C: float = -252.879                    # normal boiling point 20.271 K
const H2_TRIPLE_T_C: float = -259.347                # triple point 13.803 K
const H2_TRIPLE_P_PA: float = 7041.0
const H2_CRITICAL_T_C: float = -240.005              # critical point 33.145 K
const H2_CRITICAL_P_PA: float = 1.2964e6
const VAP_ENTHALPY_H2_J_MOL: float = 898.8           # dHvap at 20.271 K
const FUS_ENTHALPY_H2_J_MOL: float = 117.0           # dHfus at the triple point (CRC 97th ed.)
const LATENT_HEAT_VAPORISATION_H2_J_KG: float = VAP_ENTHALPY_H2_J_MOL / MOLAR_MASS_H2_KG_MOL
const LATENT_HEAT_FUSION_H2_J_KG: float = FUS_ENTHALPY_H2_J_MOL / MOLAR_MASS_H2_KG_MOL
const MOLAR_HEAT_CAP_H2_GAS_J_MOLK: float = 28.836   # cp of the gas at 298.15 K, 1 bar
const H2_GAS_SPECIFIC_HEAT_J_KGK: float = MOLAR_HEAT_CAP_H2_GAS_J_MOLK / MOLAR_MASS_H2_KG_MOL
const H2_LIQUID_SPECIFIC_HEAT_J_KGK: float = 9770.0  # saturated liquid at 20.3 K
const THERMAL_CONDUCT_H2_GAS_W_MK: float = 0.1805    # gas at 300 K, 1 bar (CRC 97th ed.)
const ENTROPY_H2_GAS_J_MOLK: float = 130.680         # CODATA Key Values
const ATOMISATION_H2_J_MOL: float = 4.35996e5        # 2 x dfH(H, g), CODATA

# Carbon monoxide, NIST Chemistry WebBook (CAS 630-08-0).
const MOLAR_MASS_CO_KG_MOL: float = MOLAR_MASS_CARBON_KG_MOL + MOLAR_MASS_OXYGEN_KG_MOL
const CO_BOIL_C: float = -191.51                     # normal boiling point 81.64 K
const CO_TRIPLE_T_C: float = -205.02                 # triple point 68.13 K
const CO_TRIPLE_P_PA: float = 15400.0
const CO_CRITICAL_T_C: float = -140.29               # critical point 132.86 K
const CO_CRITICAL_P_PA: float = 3.494e6
const VAP_ENTHALPY_CO_J_MOL: float = 6040.0          # dHvap at 81.64 K
const FUS_ENTHALPY_CO_J_MOL: float = 833.0           # dHfus at the triple point (CRC 97th ed.)
const LATENT_HEAT_VAPORISATION_CO_J_KG: float = VAP_ENTHALPY_CO_J_MOL / MOLAR_MASS_CO_KG_MOL
const LATENT_HEAT_FUSION_CO_J_KG: float = FUS_ENTHALPY_CO_J_MOL / MOLAR_MASS_CO_KG_MOL
const MOLAR_HEAT_CAP_CO_GAS_J_MOLK: float = 29.141   # cp of the gas at 298.15 K, 1 bar
const CO_GAS_SPECIFIC_HEAT_J_KGK: float = MOLAR_HEAT_CAP_CO_GAS_J_MOLK / MOLAR_MASS_CO_KG_MOL
const CO_LIQUID_SPECIFIC_HEAT_J_KGK: float = 2151.0  # saturated liquid at 81 K
const THERMAL_CONDUCT_CO_GAS_W_MK: float = 0.025     # gas at 300 K, 1 bar (CRC 97th ed.)
const ENTROPY_CO_GAS_J_MOLK: float = 197.660         # CODATA Key Values
const FORMATION_ENTHALPY_CO_J_MOL: float = -110530.0 # CODATA Key Values
const ATOMISATION_CO_J_MOL: float = 1.07639e6        # dfH(C,g) + dfH(O,g) - dfH(CO), CODATA

# Sulfur dioxide, NIST Chemistry WebBook (CAS 7446-09-5).
const MOLAR_MASS_SO2_KG_MOL: float = MOLAR_MASS_S_KG_MOL + 2.0 * MOLAR_MASS_OXYGEN_KG_MOL
const SO2_BOIL_C: float = -10.05                     # normal boiling point 263.10 K
const SO2_TRIPLE_T_C: float = -75.51                 # triple point 197.64 K
const SO2_TRIPLE_P_PA: float = 1670.0
const SO2_CRITICAL_T_C: float = 157.49               # critical point 430.64 K
const SO2_CRITICAL_P_PA: float = 7.884e6
const VAP_ENTHALPY_SO2_J_MOL: float = 24940.0        # dHvap at 263.10 K
const FUS_ENTHALPY_SO2_J_MOL: float = 7400.0         # dHfus at the triple point (CRC 97th ed.)
const LATENT_HEAT_VAPORISATION_SO2_J_KG: float = VAP_ENTHALPY_SO2_J_MOL / MOLAR_MASS_SO2_KG_MOL
const LATENT_HEAT_FUSION_SO2_J_KG: float = FUS_ENTHALPY_SO2_J_MOL / MOLAR_MASS_SO2_KG_MOL
const MOLAR_HEAT_CAP_SO2_GAS_J_MOLK: float = 39.87   # cp of the gas at 298.15 K, 1 bar
const SO2_GAS_SPECIFIC_HEAT_J_KGK: float = MOLAR_HEAT_CAP_SO2_GAS_J_MOLK / MOLAR_MASS_SO2_KG_MOL
const SO2_LIQUID_SPECIFIC_HEAT_J_KGK: float = 1360.0 # saturated liquid at 263 K
const THERMAL_CONDUCT_SO2_GAS_W_MK: float = 0.0096   # gas at 300 K, 1 bar (CRC 97th ed.)
const ENTROPY_SO2_GAS_J_MOLK: float = 248.223        # CODATA Key Values
const FORMATION_ENTHALPY_SO2_J_MOL: float = -296810.0  # CODATA Key Values
const ATOMISATION_SO2_J_MOL: float = 1.07234e6       # dfH(S,g) + 2 dfH(O,g) - dfH(SO2), CODATA

# Hydrogen sulfide, NIST Chemistry WebBook (CAS 7783-06-4); critical point Goodwin 1983, NBSIR 83-1694.
const MOLAR_MASS_H2S_KG_MOL: float = MOLAR_MASS_S_KG_MOL + 2.0 * MOLAR_MASS_HYDROGEN_KG_MOL
const H2S_BOIL_C: float = -60.28                     # normal boiling point 212.87 K
const H2S_TRIPLE_T_C: float = -85.49                 # triple point 187.66 K
const H2S_TRIPLE_P_PA: float = 23200.0
const H2S_CRITICAL_T_C: float = 100.25               # critical point 373.4 K
const H2S_CRITICAL_P_PA: float = 8.963e6
const VAP_ENTHALPY_H2S_J_MOL: float = 18670.0        # dHvap at 212.87 K
const FUS_ENTHALPY_H2S_J_MOL: float = 2377.0         # dHfus at the triple point (CRC 97th ed.)
const LATENT_HEAT_VAPORISATION_H2S_J_KG: float = VAP_ENTHALPY_H2S_J_MOL / MOLAR_MASS_H2S_KG_MOL
const LATENT_HEAT_FUSION_H2S_J_KG: float = FUS_ENTHALPY_H2S_J_MOL / MOLAR_MASS_H2S_KG_MOL
const MOLAR_HEAT_CAP_H2S_GAS_J_MOLK: float = 34.19   # cp of the gas at 298.15 K, 1 bar (NIST-JANAF)
const H2S_GAS_SPECIFIC_HEAT_J_KGK: float = MOLAR_HEAT_CAP_H2S_GAS_J_MOLK / MOLAR_MASS_H2S_KG_MOL
const H2S_LIQUID_SPECIFIC_HEAT_J_KGK: float = 2000.0 # saturated liquid at 212.9 K (Goodwin 1983)
const THERMAL_CONDUCT_H2S_GAS_W_MK: float = 0.01453  # gas at 300 K, 1 bar (CRC 97th ed.)
const ENTROPY_H2S_GAS_J_MOLK: float = 205.81         # CODATA Key Values
const FORMATION_ENTHALPY_H2S_J_MOL: float = -20600.0 # CODATA Key Values
const ATOMISATION_H2S_J_MOL: float = 7.3377e5        # dfH(S,g) + 2 dfH(H,g) - dfH(H2S), CODATA

# Methane, NIST Chemistry WebBook (CAS 74-82-8); EOS anchors Setzmann & Wagner 1991,
# J. Phys. Chem. Ref. Data 20:1061.
const MOLAR_MASS_CH4_KG_MOL: float = MOLAR_MASS_CARBON_KG_MOL + 4.0 * MOLAR_MASS_HYDROGEN_KG_MOL
const CH4_BOIL_C: float = -161.48                    # normal boiling point 111.667 K
const CH4_TRIPLE_T_C: float = -182.456               # triple point 90.694 K
const CH4_TRIPLE_P_PA: float = 11696.0
const CH4_CRITICAL_T_C: float = -82.586              # critical point 190.564 K
const CH4_CRITICAL_P_PA: float = 4.5992e6
const VAP_ENTHALPY_CH4_J_MOL: float = 8190.0         # dHvap at 111.667 K
const FUS_ENTHALPY_CH4_J_MOL: float = 940.0          # dHfus at the triple point (CRC 97th ed.)
const LATENT_HEAT_VAPORISATION_CH4_J_KG: float = VAP_ENTHALPY_CH4_J_MOL / MOLAR_MASS_CH4_KG_MOL
const LATENT_HEAT_FUSION_CH4_J_KG: float = FUS_ENTHALPY_CH4_J_MOL / MOLAR_MASS_CH4_KG_MOL
const MOLAR_HEAT_CAP_CH4_GAS_J_MOLK: float = 35.69   # cp of the gas at 298.15 K, 1 bar
const CH4_GAS_SPECIFIC_HEAT_J_KGK: float = MOLAR_HEAT_CAP_CH4_GAS_J_MOLK / MOLAR_MASS_CH4_KG_MOL
const CH4_LIQUID_SPECIFIC_HEAT_J_KGK: float = 3480.0 # saturated liquid at 111.7 K (Setzmann & Wagner)
const THERMAL_CONDUCT_CH4_GAS_W_MK: float = 0.03427  # gas at 300 K, 1 bar (CRC 97th ed.)
const ENTROPY_CH4_GAS_J_MOLK: float = 186.25         # NIST-JANAF (Chase 1998)
const FORMATION_ENTHALPY_CH4_J_MOL: float = -74870.0 # NIST-JANAF (Chase 1998)
const ATOMISATION_CH4_J_MOL: float = 1.66354e6       # dfH(C,g) + 4 dfH(H,g) - dfH(CH4), CODATA/JANAF

## Moles of N fixed per flash (Schumann & Huntrieser 2007, Atmos. Chem. Phys. 7:3823).
const LIGHTNING_N_FIXED_MOL_PER_FLASH: float = 250.0
const LIGHTNING_N_FIXED_MOL_PER_J: float = LIGHTNING_N_FIXED_MOL_PER_FLASH / LIGHTNING_FLASH_J

const MOLAR_MASS_HYDROGEN_KG_MOL: float = 0.00100794   # H
const MOLAR_MASS_OXYGEN_KG_MOL: float = 0.0159994      # O
# Standard atomic weights, kg/mol (IUPAC 2021).
const MOLAR_MASS_F_KG_MOL: float = 0.0189984    # F
const MOLAR_MASS_NA_KG_MOL: float = 0.0229898   # Na
const MOLAR_MASS_MG_KG_MOL: float = 0.0243050   # Mg
const MOLAR_MASS_AL_KG_MOL: float = 0.0269815   # Al
const MOLAR_MASS_SI_KG_MOL: float = 0.0280855   # Si
const MOLAR_MASS_P_KG_MOL: float = 0.0309738    # P
const MOLAR_MASS_S_KG_MOL: float = 0.0320600    # S
const MOLAR_MASS_CL_KG_MOL: float = 0.0354500   # Cl
const MOLAR_MASS_K_KG_MOL: float = 0.0390983    # K
const MOLAR_MASS_CA_KG_MOL: float = 0.0400780   # Ca
const MOLAR_MASS_FE_KG_MOL: float = 0.0558450   # Fe
const MOLAR_MASS_NI_KG_MOL: float = 0.0586934   # Ni

## Vitrinite-maturation frequency factor, per second (Sweeney & Burnham).
const VITRINITE_FREQUENCY_FACTOR_PER_S: float = 1.0e13
const KCAL_PER_MOL_TO_J_MOL: float = 4184.0
const COAL_DEHYDRATION_EA_J_MOL: float = 34.0 * KCAL_PER_MOL_TO_J_MOL
const COAL_DEHYDRATION_EA_OVER_R_K: float = COAL_DEHYDRATION_EA_J_MOL / GAS_CONSTANT_J_MOL_K
const COAL_DECARBOXYLATION_EA_J_MOL: float = 36.0 * KCAL_PER_MOL_TO_J_MOL
const COAL_DECARBOXYLATION_EA_OVER_R_K: float = COAL_DECARBOXYLATION_EA_J_MOL / GAS_CONSTANT_J_MOL_K

const SPEED_OF_LIGHT_M_S: float = 299792458.0        # CODATA, exact by definition of the metre
## Second radiation constant h*c/k, in cm K, so it pairs with a wavenumber in cm^-1: x = PLANCK_C2_CM_K*nu/T.
const PLANCK_C2_CM_K: float = PLANCK_J_S * SPEED_OF_LIGHT_M_S / BOLTZMANN_J_K * 100.0
## Two-stream diffusivity factor, the secant of the effective slant angle (Elsasser 1942).
const TWO_STREAM_DIFFUSIVITY: float = 1.66
## Pressure LAAbsorptionBands coefficients are stated at, Pa (Pierrehumbert, Principles of Planetary
## Climate 4.4.7: 100 mb, 260 K, air-broadened).
const ABSORPTION_REF_PRESSURE_PA: float = 1.0e4
## Broadband 8-14 um emissivity of snow (Warren 1982, Rev. Geophys. 20:67; Dozier & Warren 1982).
const EMISSIVITY_SNOW: float = 0.99
## Specific gas constant of CO2, J/kg/K.
const CO2_GAS_CONST_J_KGK: float = GAS_CONSTANT_J_MOL_K / MOLAR_MASS_CO2_KG_MOL
## Solar effective temperature, K (IAU 2015 Resolution B3 nominal luminosity and radius).
const SOLAR_EFFECTIVE_TEMPERATURE_K: float = 5772.0


## Rheological lock-up and remobilisation crystal fractions (Marsh 1981; Vigneresse et al. 1996).
const RHEOLOGICAL_LOCKUP_CRYSTAL_FRAC: float = 0.6
const RHEOLOGICAL_MOBILE_CRYSTAL_FRAC: float = 0.4

# Dynamic viscosity, Pa s. Kestin, Sokolov & Wakeham 1978, JPCRD 7:941 (water);
# Kadoya, Matsunaga & Nagashima 1985, ibid. 14:947 (air).
const WATER_DYNAMIC_VISCOSITY_PA_S: float = 1.002e-3    # liquid water at 20 C
const AIR_DYNAMIC_VISCOSITY_PA_S: float = 1.81e-5       # dry air at 15 C, 1 atm
## Kozeny-Carman shape factor for packed beds (Carman 1937, Trans. Inst. Chem. Eng. 15:150).
const KOZENY_CARMAN_C: float = 180.0
## Smagorinsky coefficient derived from the Kolmogorov constant (Lilly 1967).
const KOLMOGOROV_CONSTANT: float = 1.6
const SMAGORINSKY_COEFF: float = (1.0 / PI) * pow(1.5 * KOLMOGOROV_CONSTANT, -0.75)

## Air conductivity, S/m (Gringel, Rosen & Hofmann 1986, fair-weather profile).
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

# Atmosphere BEFORE life: CO2-N2 in roughly equal parts, mid-range Hadean (Kasting 1993, Science 259:920).
const PREBIOTIC_MOLE_FRAC_CO2: float = 0.5
## Outgassing vs. escape (Kasting 1993); contested — Tian et al. 2005 (Science 308:1014) argue ~0.3.
const PREBIOTIC_MOLE_FRAC_H2: float = 1.0e-3
## CO2-photolysis steady state (Kasting 1990, Orig. Life Evol. Biosph. 20:199).
const PREBIOTIC_MOLE_FRAC_CO: float = 1.0e-4
## Abiotic only (serpentinization; no methanogens): ~10 ppmv, uncertain by an order of magnitude
## either way (Kasting 2005, Precambrian Res. 137:119).
const PREBIOTIC_MOLE_FRAC_CH4: float = 1.0e-5
## Volcanic supply vs. photolysis + rainout, ppb steady state (Zahnle et al. 2006, Geobiology 4:271).
const PREBIOTIC_MOLE_FRAC_SO2: float = 1.0e-9
const PREBIOTIC_MOLE_FRAC_H2S: float = 1.0e-9
## N2 carries the remainder, so the mole fractions sum to exactly 1.
const PREBIOTIC_MOLE_FRAC_N2: float = 1.0 - PREBIOTIC_MOLE_FRAC_CO2 - PREBIOTIC_MOLE_FRAC_H2 \
	- PREBIOTIC_MOLE_FRAC_CO - PREBIOTIC_MOLE_FRAC_CH4 - PREBIOTIC_MOLE_FRAC_SO2 \
	- PREBIOTIC_MOLE_FRAC_H2S

# EARTH'S HYPSOGRAPHIC CURVE: the area-by-elevation distribution of the solid surface against sea level.
# Sverdrup, Johnson & Fleming 1942, The Oceans, ch. II; Eakins & Sharman 2010, NOAA ETOPO1 volumes.
const HYPSOMETRY_ELEVATION_M: Array[float] = [-10984.0, -6000.0, -5000.0, -4000.0, -3000.0, -2000.0,
	-1000.0, 0.0, 1000.0, 2000.0, 3000.0, 4000.0, 5000.0, 8848.86]
const HYPSOMETRY_AREA_BELOW: Array[float] = [0.0, 0.010, 0.174, 0.407, 0.546, 0.593, 0.622, 0.708,
	0.917, 0.962, 0.984, 0.995, 0.999, 1.0]
## Challenger Deep (Gardner, Armstrong & Calder 2014, Marine Geodesy 37:1).
const HYPSOMETRY_DEEPEST_M: float = -10984.0
## Everest (China-Nepal joint survey 2020).
const HYPSOMETRY_HIGHEST_M: float = 8848.86
## Land as a share of the solid surface (Eakins & Sharman 2010).
const HYPSOMETRY_LAND_AREA_FRACTION: float = 0.292

## Topographic power at planetary wavelengths falls as l^-2, so amplitude scales with wavelength
## (Rapp 1989; Wieczorek 2007, Treatise on Geophysics vol. 10).
const TOPOGRAPHY_LONG_HURST: float = 1.0
## Below ~100 km continental topography is self-affine with Hurst exponent ~0.5 (Turcotte 1997,
## Fractals and Chaos in Geology and Geophysics, ch. 7).
const TOPOGRAPHY_SHORT_HURST: float = 0.5
## Wavelength the two regimes meet at (Turcotte 1997).
const TOPOGRAPHY_SELF_AFFINE_CROSSOVER_M: float = 1.0e5
## The continent-ocean dichotomy is a degree-2 pattern (Wieczorek 2007).
const TOPOGRAPHY_DOMINANT_HARMONIC_DEGREE: int = 2

## Mantle potential temperature, K: 1280 C (McKenzie & Bickle 1988, J. Petrol. 29:625).
const MANTLE_POTENTIAL_TEMP_K: float = 1553.15
## Core-mantle boundary temperature, K (Lay, Hernlund & Buffett 2008, Nature Geosci. 1:25).
const CORE_MANTLE_BOUNDARY_TEMP_K: float = 4000.0
## Continental surface heat flow, W/m^2 (Pollack, Hurter & Johnson 1993, Rev. Geophys. 31:267).
const SURFACE_HEAT_FLOW_W_M2: float = 0.065

## Temperature at which a solid first glows visibly, C (Draper 1847: 798 K).
const DRAPER_POINT_C: float = 525.0
