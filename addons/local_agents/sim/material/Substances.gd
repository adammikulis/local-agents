class_name LASubstances
extends RefCounted

const PC = preload("res://addons/local_agents/sim/material/PhysicalConstants.gd")

## Moles of ELEMENT in one channel unit of any organic stock — one number for organic_c, organic_h and
## organic_o, so organic_h/organic_c is the molar H:C ratio with no conversion. mol/m3.
const ORGANIC_MOL_PER_M3: float = PC.DRY_WOOD_DENSITY_KG_M3 / PC.MOLAR_MASS_CH2O_UNIT_KG_MOL

## HIGHER heating value per kg of each element in a solid fuel — Channiwala & Parikh 2002, Fuel 81:1051-1063,
## "A unified correlation for estimating HHV of solid, liquid and gaseous fuels", eq. 1:
const HHV_PER_KG_C_J: float = 0.3491e8
const HHV_PER_KG_H_J: float = 1.1783e8
const HHV_PER_KG_O_J: float = -0.1034e8
const HHV_PER_KG_N_J: float = -0.0151e8

## Standard molar entropy of the GAS, J/mol/K (CODATA / NIST-JANAF, 298.15 K, 1 bar). A property of the
## substance, so it lives here rather than in LAPhysical.
const ENTROPY_H2O_GAS_J_MOLK: float = 188.835
const ENTROPY_O2_GAS_J_MOLK: float = 205.152
const ENTROPY_CO2_GAS_J_MOLK: float = 213.785


##   molar_mass       kg/mol. The one bridge between the mass this table stores and the moles chemistry uses.
##   density          kg/m3, a REFERENCE value at `density_ref_t_c` and STANDARD_PRESSURE_PA — not the
##                    density, which is density(id, t_c, p_pa) and varies with both.
static var _table_cache: Dictionary = {}


## The one table. Cached because it is read per cell and per substance on hot paths, and it is built
## entirely from constants; no caller writes to it.
static func table() -> Dictionary:
	if _table_cache.is_empty():
		_table_cache = _build_table()
	return _table_cache


static func _build_table() -> Dictionary:
	return {
		# --- WATER ------------------------------------------------------------------------------------------
		"h2o": {
			"formula": {"H": 2.0, "O": 1.0},
			"molar_mass": PC.MOLAR_MASS_WATER_KG_MOL,
			"atomisation_j_mol": PC.ATOMISATION_H2O_J_MOL,
			"entropy_gas_j_molk": ENTROPY_H2O_GAS_J_MOLK,
			"density": PC.WATER_DENSITY_KG_M3,
			"density_ref_t_c": PC.LAB_REFERENCE_TEMP_C,
			"expansion_per_k": PC.WATER_VOLUME_EXPANSION_PER_K,
			"bulk_modulus_pa": PC.WATER_BULK_MODULUS_PA,
			"density_solid": PC.ICE_DENSITY_KG_M3,
			"density_solid_ref_t_c": PC.WATER_FREEZE_C,
			"expansion_solid_per_k": PC.ICE_VOLUME_EXPANSION_PER_K,
			"bulk_modulus_solid_pa": PC.ICE_BULK_MODULUS_PA,
			"specific_heat": PC.WATER_SPECIFIC_HEAT_J_KGK,
			"specific_heat_solid": PC.ICE_SPECIFIC_HEAT_J_KGK,
			"specific_heat_gas": PC.VAPOUR_SPECIFIC_HEAT_J_KGK,
			"melt_c": PC.WATER_FREEZE_C,
			"boil_c": PC.WATER_BOIL_C,
			"boil_ref_p_pa": PC.STANDARD_PRESSURE_PA,
			"triple_t_c": PC.WATER_TRIPLE_T_C,
			"triple_p_pa": PC.WATER_TRIPLE_P_PA,
			"critical_t_c": PC.WATER_CRITICAL_T_C,
			"critical_p_pa": PC.WATER_CRITICAL_P_PA,
			"latent_fusion_j_kg": PC.LATENT_HEAT_FUSION_J_KG,
			"latent_vaporisation_j_kg": PC.LATENT_HEAT_VAPORISATION_0C_J_KG,
			"latent_vaporisation_ref_t_c": PC.WATER_FREEZE_C,
			"conductivity": PC.THERMAL_CONDUCT_WATER_W_MK,
			"emissivity": PC.EMISSIVITY_WATER,
			"albedo": PC.ALBEDO_OCEAN,
			"albedo_solid": PC.ALBEDO_SNOW_ICE,
		},

		# --- THE ATMOSPHERE'S GASES -------------------------------------------------------------------------
		"n2": {
			"formula": {"N": 2.0},
			"molar_mass": PC.MOLAR_MASS_N2_KG_MOL,
			"atomisation_j_mol": PC.ATOMISATION_N2_J_MOL,
			"entropy_gas_j_molk": PC.ENTROPY_N2_GAS_J_MOLK,
			"density": PC.AMBIENT_O2_DENSITY_KG_M3 * (PC.MOLAR_MASS_N2_KG_MOL / PC.MOLAR_MASS_O2_KG_MOL),
			"specific_heat": PC.N2_LIQUID_SPECIFIC_HEAT_J_KGK,
			"specific_heat_gas": PC.N2_GAS_SPECIFIC_HEAT_J_KGK,
			"melt_c": PC.N2_TRIPLE_T_C,
			"boil_c": PC.N2_BOIL_C,
			"boil_ref_p_pa": PC.STANDARD_PRESSURE_PA,
			"triple_t_c": PC.N2_TRIPLE_T_C,
			"triple_p_pa": PC.N2_TRIPLE_P_PA,
			"critical_t_c": PC.N2_CRITICAL_T_C,
			"critical_p_pa": PC.N2_CRITICAL_P_PA,
			"latent_fusion_j_kg": PC.LATENT_HEAT_FUSION_N2_J_KG,
			"latent_vaporisation_j_kg": PC.LATENT_HEAT_VAPORISATION_N2_J_KG,
			"latent_vaporisation_ref_t_c": PC.N2_BOIL_C,
			"conductivity": PC.THERMAL_CONDUCT_N2_GAS_W_MK,
		},
		"o2": {
			"formula": {"O": 2.0},
			"molar_mass": PC.MOLAR_MASS_O2_KG_MOL,
			"atomisation_j_mol": PC.ATOMISATION_O2_J_MOL,
			"entropy_gas_j_molk": ENTROPY_O2_GAS_J_MOLK,
			"density": PC.AMBIENT_O2_DENSITY_KG_M3,
			"specific_heat": PC.AIR_SPECIFIC_HEAT_J_KGK,
			"conductivity": PC.THERMAL_CONDUCT_O2_GAS_W_MK,
		},
		"co2": {
			"formula": {"C": 1.0, "O": 2.0},
			"molar_mass": PC.MOLAR_MASS_CO2_KG_MOL,
			"atomisation_j_mol": PC.ATOMISATION_CO2_J_MOL,
			"entropy_gas_j_molk": ENTROPY_CO2_GAS_J_MOLK,
			"formation_enthalpy_j_mol": PC.FORMATION_ENTHALPY_CO2_J_MOL,
			"density": PC.AMBIENT_O2_DENSITY_KG_M3 * (PC.MOLAR_MASS_CO2_KG_MOL / PC.MOLAR_MASS_O2_KG_MOL),
			"specific_heat": PC.AIR_SPECIFIC_HEAT_J_KGK,
			"conductivity": PC.THERMAL_CONDUCT_CO2_GAS_W_MK,
		},

		# --- ORGANIC MATTER ---------------------------------------------------------------------------------
		"organic_c": {
			"formula": {"C": 1.0,
				"N": (PC.MOLAR_MASS_CARBON_KG_MOL / PC.LITTER_C_TO_N) / PC.MOLAR_MASS_NITROGEN_KG_MOL},
			"molar_mass": PC.MOLAR_MASS_CARBON_KG_MOL,
			"density": ORGANIC_MOL_PER_M3 * PC.MOLAR_MASS_CARBON_KG_MOL,
			"specific_heat": PC.DRY_WOOD_SPECIFIC_HEAT_J_KGK,
			"albedo": PC.ALBEDO_VEGETATION,
			"conductivity": PC.THERMAL_CONDUCT_ORGANIC_W_MK,
		},
		"organic_h": {
			"formula": {"H": 1.0},
			"molar_mass": PC.MOLAR_MASS_HYDROGEN_KG_MOL,
			"density": ORGANIC_MOL_PER_M3 * PC.MOLAR_MASS_HYDROGEN_KG_MOL,
			"specific_heat": PC.DRY_WOOD_SPECIFIC_HEAT_J_KGK,
			"conductivity": PC.THERMAL_CONDUCT_ORGANIC_W_MK,
		},
		"organic_o": {
			"formula": {"O": 1.0},
			"molar_mass": PC.MOLAR_MASS_OXYGEN_KG_MOL,
			"density": ORGANIC_MOL_PER_M3 * PC.MOLAR_MASS_OXYGEN_KG_MOL,
			"specific_heat": PC.DRY_WOOD_SPECIFIC_HEAT_J_KGK,
			"conductivity": PC.THERMAL_CONDUCT_ORGANIC_W_MK,
		},
		"cellulose": {
			"formula": {"C": 1.0, "H": 2.0, "O": 1.0,
				"N": (PC.MOLAR_MASS_CARBON_KG_MOL / PC.LITTER_C_TO_N) / PC.MOLAR_MASS_NITROGEN_KG_MOL},
			"molar_mass": PC.MOLAR_MASS_CH2O_UNIT_KG_MOL,
			"density": PC.DRY_WOOD_DENSITY_KG_M3,
			"specific_heat": PC.DRY_WOOD_SPECIFIC_HEAT_J_KGK,
			"pyrolysis_ea_over_r_k": PC.CELLULOSE_PYROLYSIS_EA_OVER_R_K,
			"albedo": PC.ALBEDO_VEGETATION,
			"conductivity": PC.THERMAL_CONDUCT_CELLULOSE_W_MK,
		},

		# --- MINERALS ---------------------------------------------------------------------------------------
		"silicate": {
			"formula": {"Ca": 1.0, "Si": 1.0, "O": 3.0},
			"molar_mass": PC.MOLAR_MASS_CASIO3_KG_MOL,
			"formation_enthalpy_j_mol": PC.FORMATION_ENTHALPY_CASIO3_J_MOL,
			"entropy_j_molk": PC.ENTROPY_CASIO3_J_MOL_K,
			"density": PC.ROCK_DENSITY_KG_M3,
			"density_ref_t_c": PC.LAB_REFERENCE_TEMP_C,
			"expansion_per_k": PC.ROCK_VOLUME_EXPANSION_PER_K,
			"bulk_modulus_pa": PC.ROCK_BULK_MODULUS_PA,
			"specific_heat": PC.ROCK_SPECIFIC_HEAT_J_KGK,
			"melt_c": PC.BASALT_SOLIDUS_C,
			"liquidus_c": PC.BASALT_LIQUIDUS_C,
			"latent_fusion_j_kg": PC.BASALT_LATENT_HEAT_CRYSTALLISATION_J_KG,
			"conductivity": PC.THERMAL_CONDUCT_ROCK_W_MK,
			"emissivity": PC.BASALT_EMISSIVITY,
			"albedo": PC.ALBEDO_BARE_GROUND,
		},
		"silica": {
			"formula": {"Si": 1.0, "O": 2.0},
			"molar_mass": PC.MOLAR_MASS_SIO2_KG_MOL,
			"formation_enthalpy_j_mol": PC.FORMATION_ENTHALPY_SIO2_J_MOL,
			"entropy_j_molk": PC.ENTROPY_SIO2_J_MOL_K,
			"density": PC.QUARTZ_DENSITY_KG_M3,
			"density_ref_t_c": PC.LAB_REFERENCE_TEMP_C,
			"expansion_per_k": PC.QUARTZ_VOLUME_EXPANSION_PER_K,
			"bulk_modulus_pa": PC.QUARTZ_BULK_MODULUS_PA,
			"specific_heat": PC.QUARTZ_SPECIFIC_HEAT_J_KGK,
			"conductivity": PC.THERMAL_CONDUCT_ROCK_W_MK,
			"emissivity": PC.BASALT_EMISSIVITY,
			"albedo": PC.ALBEDO_BARE_GROUND,
		},
		"carbonate": {
			"formula": {"Ca": 1.0, "C": 1.0, "O": 3.0},
			"molar_mass": PC.MOLAR_MASS_CACO3_KG_MOL,
			"formation_enthalpy_j_mol": PC.FORMATION_ENTHALPY_CACO3_J_MOL,
			"entropy_j_molk": PC.ENTROPY_CACO3_J_MOL_K,
			"density": PC.CALCITE_DENSITY_KG_M3,
			"density_ref_t_c": PC.LAB_REFERENCE_TEMP_C,
			"expansion_per_k": PC.CALCITE_VOLUME_EXPANSION_PER_K,
			"specific_heat": PC.CALCITE_SPECIFIC_HEAT_J_KGK,
			"conductivity": PC.THERMAL_CONDUCT_ROCK_W_MK,
			"emissivity": PC.BASALT_EMISSIVITY,
			"albedo": PC.ALBEDO_BARE_GROUND,
		},

		# --- MINERAL NITROGEN -------------------------------------------------------------------------------
		"fixed_n": {
			"formula": {"N": 1.0},
			"molar_mass": PC.MOLAR_MASS_NITROGEN_KG_MOL,
			"density": PC.ROCK_DENSITY_KG_M3,
			"specific_heat": PC.ROCK_SPECIFIC_HEAT_J_KGK,
			"conductivity": PC.THERMAL_CONDUCT_ROCK_W_MK,
		},
	}


## Moles of one element per mole of CARBON in FRESH litter — the composition a living plant sheds, read off
## the cellulose entry so a credit into the dead pool cannot disagree with the table about what litter is.
static func fresh_litter_per_carbon(element: String) -> float:
	var f: Dictionary = table()["cellulose"]["formula"]
	var c: float = float(f.get("C", 0.0))
	if c <= 0.0:
		return 0.0
	return float(f.get(element, 0.0)) / c


## Heat released by fully oxidising ONE MOLE of one element of the dead organic pool, J/mol, with the water
## leaving as VAPOUR (that is where the MOISTURE channel puts it, so the latent heat is not available and the
static func organic_energy_j_mol(element: String) -> float:
	if element == "C":
		var n_per_c: float = float(table()["organic_c"]["formula"]["N"])
		return HHV_PER_KG_C_J * PC.MOLAR_MASS_CARBON_KG_MOL \
			+ n_per_c * HHV_PER_KG_N_J * PC.MOLAR_MASS_NITROGEN_KG_MOL
	if element == "H":
		var water_per_h: float = PC.MOLAR_MASS_WATER_KG_MOL / (2.0 * PC.MOLAR_MASS_HYDROGEN_KG_MOL)
		var lhv: float = HHV_PER_KG_H_J - water_per_h * latent_vaporisation_at("h2o", PC.LAB_REFERENCE_TEMP_C)
		return lhv * PC.MOLAR_MASS_HYDROGEN_KG_MOL
	if element == "O":
		return HHV_PER_KG_O_J * PC.MOLAR_MASS_OXYGEN_KG_MOL
	return 0.0


## SOLID / LIQUID / GAS, derived — never stored.
const SOLID: int = 0
const LIQUID: int = 1
const GAS: int = 2
const ATOMS: int = 3
const PLASMA: int = 4
const SUPERCRITICAL: int = 5


## Latent heat of sublimation, J/kg — DERIVED as fusion + vaporisation so Hess's law cannot be violated.
static func latent_sublimation_j_kg(id: String) -> float:
	var s: Dictionary = table().get(id, {})
	return float(s.get("latent_fusion_j_kg", 0.0)) + float(s.get("latent_vaporisation_j_kg", 0.0))


## True when this row carries an equation of state — a thermal expansivity, a bulk modulus, or both. A row
## without one has that dependence UNMEASURED here, not zero, and reports its reference value unchanged.
static func has_eos(id: String) -> bool:
	var s: Dictionary = table().get(id, {})
	return s.has("expansion_per_k") or s.has("bulk_modulus_pa") \
		or s.has("expansion_solid_per_k") or s.has("bulk_modulus_solid_pa")


## Density at a temperature and pressure, kg/m^3. `p_pa` is the partial pressure of THIS substance.
static func density(id: String, t_c: float, p_pa: float) -> float:
	var s: Dictionary = table().get(id, {})
	if s.is_empty():
		return 0.0
	if _is_gas_at(s, id, t_c, p_pa):
		var mm: float = float(s.get("molar_mass", 0.0))
		var t_k: float = t_c + PC.KELVIN_OFFSET
		if mm <= 0.0 or t_k <= 0.0 or p_pa <= 0.0:
			return 0.0
		return p_pa * mm / (PC.GAS_CONSTANT_J_MOL_K * t_k)

	var rho_liq: float = float(s.get("density", 0.0))
	var v_liq: float = _specific_volume(rho_liq, float(s.get("density_ref_t_c", PC.LAB_REFERENCE_TEMP_C)),
		float(s.get("expansion_per_k", 0.0)), float(s.get("bulk_modulus_pa", 0.0)), t_c, p_pa)
	if not s.has("density_solid"):
		return 1.0 / v_liq if v_liq > 0.0 else 0.0
	var v_sol: float = _specific_volume(float(s["density_solid"]),
		float(s.get("density_solid_ref_t_c", PC.LAB_REFERENCE_TEMP_C)),
		float(s.get("expansion_solid_per_k", 0.0)), float(s.get("bulk_modulus_solid_pa", 0.0)), t_c, p_pa)
	# Across the melting interval both phases are present and VOLUMES add, so the specific volumes mix by
	# the melt fraction. Outside it one end of the lever carries everything.
	var solidus: float = melt_c_at(id, p_pa)
	if not is_finite(solidus):
		return 1.0 / v_sol if v_sol > 0.0 else 0.0
	var liquidus: float = liquidus_c_at(id, p_pa)
	var phi: float = 1.0
	if t_c <= solidus:
		phi = 0.0
	elif t_c < liquidus:
		phi = (t_c - solidus) / (liquidus - solidus)
	var v: float = (1.0 - phi) * v_sol + phi * v_liq
	return 1.0 / v if v > 0.0 else 0.0


## Specific volume of a condensed phase, m^3/kg: the reference volume opened up by thermal expansion and
## squeezed by pressure. A coefficient the table does not carry leaves its term out.
static func _specific_volume(rho_ref: float, t_ref_c: float, alpha_per_k: float, bulk_pa: float,
		t_c: float, p_pa: float) -> float:
	if rho_ref <= 0.0:
		return 0.0
	var v: float = (1.0 + alpha_per_k * (t_c - t_ref_c)) / rho_ref
	if bulk_pa > 0.0 and p_pa > 0.0:
		v *= 1.0 - (p_pa - PC.STANDARD_PRESSURE_PA) / bulk_pa
	return maxf(v, 0.0)


## Gaseous at these conditions? The table's own vapour boundary decides — the frost point below the triple
## pressure, the boiling point above it. A row carrying neither boundary nor an EOS has no phase data at
## all, and the honest answer is that its declared reference value is all this table knows.
static func _is_gas_at(s: Dictionary, id: String, t_c: float, p_pa: float) -> bool:
	if not is_finite(float(s.get("boil_c", INF))):
		return false
	if sublimes_at(id, p_pa):
		return t_c > sublimation_c_at(id, p_pa)
	return t_c > boil_c_at(id, p_pa)


## Moles of substance in one kilogram — the ONLY bridge between what the field stores (mass) and what
## chemistry counts (atoms).
static func mol_per_kg(id: String) -> float:
	var m: float = float(table().get(id, {}).get("molar_mass", 0.0))
	return 1.0 / m if m > 0.0 else 0.0


## Atoms per KILOGRAM of a substance, which is what a conservation ledger has to sum. `formula` is per MOLE.
static func atoms_per_kg(id: String) -> Dictionary:
	var s: Dictionary = table().get(id, {})
	var per_mol: Dictionary = s.get("formula", {})
	var n: float = mol_per_kg(id)
	var out: Dictionary = {}
	for el in per_mol:
		out[el] = float(per_mol[el]) * n
	return out


## SPECIFIC ENTHALPY (J/kg) at a temperature, referenced to the solid at 0 K. The inverse of
## enthalpy_to_state(), rung for rung; on a ZERO-WIDTH plateau it returns the LOWER end.
static func enthalpy_at(id: String, t_c: float, p_pa: float = PC.STANDARD_PRESSURE_PA,
		molality_mol_kg: float = 0.0) -> float:
	var s: Dictionary = table().get(id, {})
	var c_sol: float = float(s.get("specific_heat_solid", s.get("specific_heat", 0.0)))
	var c_liq: float = float(s.get("specific_heat", 0.0))
	var c_gas: float = float(s.get("specific_heat_gas", c_liq))
	# Pressure-dependent, and depressed by any dissolved solute. For water the Clapeyron slope is negative.
	var melt: float = melt_c_at(id, p_pa, molality_mol_kg)
	var boil: float = boil_c_at(id, p_pa)
	var t_k: float = t_c + PC.KELVIN_OFFSET
	if not is_finite(melt):
		# Never melts on this planet — silica, the gases. Sensible heat alone, on whichever capacity it has.
		var c: float = c_sol if c_sol > 0.0 else c_liq
		return c * t_k

	# NO LIQUID BELOW THE TRIPLE POINT. The plateau crossed is SUBLIMATION at the frost point.
	if sublimes_at(id, p_pa):
		var t_sub: float = sublimation_c_at(id, p_pa)
		if t_c <= t_sub:
			return c_sol * t_k
		var h_sub: float = c_sol * (t_sub + PC.KELVIN_OFFSET) + latent_sublimation_j_kg(id)
		return _gas_enthalpy_at(id, t_c, p_pa, t_sub, h_sub, c_gas)

	if t_c <= melt:
		return c_sol * t_k
	var liquidus: float = liquidus_c_at(id, p_pa, molality_mol_kg)
	var l_fus: float = float(s.get("latent_fusion_j_kg", 0.0))
	var h_start: float = c_sol * (melt + PC.KELVIN_OFFSET)
	var h_end: float = h_start + l_fus + c_liq * (liquidus - melt)
	if t_c < liquidus:
		# Lever rule across the mush: solid and liquid enthalpies weighted by the melt fraction.
		var x: float = t_c - melt
		var phi: float = x / (liquidus - melt)
		return h_start + c_sol * x + phi * (l_fus + (c_liq - c_sol) * x)
	if not is_finite(boil) or t_c <= boil:
		return h_end + c_liq * (t_c - liquidus)
	# THE LATENT HEAT AT THE BOUNDARY, not the table's reference value: the plateau is zero at the critical
	# point. Above it the atomisation and ionisation energies are paid by equilibrium, not in one step.
	var h_top: float = h_end + c_liq * (boil - liquidus) + latent_vaporisation_at(id, boil)
	return _gas_enthalpy_at(id, t_c, p_pa, boil, h_top, c_gas)


## ln p = A - B/T, with B fixed by the TWO measured points the table carries — the triple point and the
## normal boiling point — so both are reproduced exactly and B * R_v is the MEAN latent heat over the
## interval. One anchor is not enough: it puts water at 0 C near 900 Pa against a measured 611.
static func _clapeyron_b(id: String) -> float:
	var s: Dictionary = table().get(id, {})
	var t2_c: float = float(s.get("boil_c", INF))
	if not is_finite(t2_c):
		return 0.0
	var p2: float = float(s.get("boil_ref_p_pa", PC.STANDARD_PRESSURE_PA))
	var t1_c: float = float(s.get("triple_t_c", INF))
	var p1: float = float(s.get("triple_p_pa", 0.0))
	if is_finite(t1_c) and p1 > 0.0 and p2 > 0.0 and absf(t1_c - t2_c) > 0.0:
		var inv: float = 1.0 / (t1_c + PC.KELVIN_OFFSET) - 1.0 / (t2_c + PC.KELVIN_OFFSET)
		if absf(inv) > 0.0:
			return log(p2 / p1) / inv
	return latent_vaporisation_at(id, t2_c) / PC.VAPOUR_GAS_CONST_J_KGK


## THE BOILING POINT AT A GIVEN PRESSURE — the boundary curve solved for temperature.
static func boil_c_at(id: String, p_pa: float) -> float:
	var s: Dictionary = table().get(id, {})
	var t_ref_c: float = float(s.get("boil_c", INF))
	if not is_finite(t_ref_c):
		return INF
	var p_ref: float = float(s.get("boil_ref_p_pa", PC.STANDARD_PRESSURE_PA))
	var p_crit: float = float(s.get("critical_p_pa", INF))
	var t_crit: float = float(s.get("critical_t_c", INF))
	if is_finite(p_crit) and p_pa >= p_crit:
		return t_crit
	var p: float = maxf(p_pa, 1.0)
	var t_ref_k: float = t_ref_c + PC.KELVIN_OFFSET
	var b: float = _clapeyron_b(id)
	if b <= 0.0:
		return t_ref_c
	var inv_t: float = 1.0 / t_ref_k - log(p / p_ref) / b
	if inv_t <= 0.0:
		return t_crit if is_finite(t_crit) else t_ref_c
	var t_c: float = 1.0 / inv_t - PC.KELVIN_OFFSET
	# The boundary cannot run past the critical point; beyond it the two phases are one.
	return minf(t_c, t_crit) if is_finite(t_crit) else t_c


## constants with the relation between them written in a comment. Watson correlation:
## that is physically ZERO. Watson has the right asymptote — L goes to zero at Tc, because that is what a
static func element_ionisation_ev() -> Dictionary:
	return {
		"H": PC.IONISATION_EV_H, "O": PC.IONISATION_EV_O, "C": PC.IONISATION_EV_C, "N": PC.IONISATION_EV_N,
		"Si": PC.IONISATION_EV_SI, "Ca": PC.IONISATION_EV_CA, "Fe": PC.IONISATION_EV_FE,
		"Mg": PC.IONISATION_EV_MG, "Al": PC.IONISATION_EV_AL,
	}


static func element_degen() -> Dictionary:
	return {
		"H": [PC.DEGEN_H_0, PC.DEGEN_H_1], "O": [PC.DEGEN_O_0, PC.DEGEN_O_1],
		"C": [PC.DEGEN_C_0, PC.DEGEN_C_1], "N": [PC.DEGEN_N_0, PC.DEGEN_N_1],
	}


static func element_entropy_j_molk() -> Dictionary:
	return {
		"H": PC.ENTROPY_H_ATOM_J_MOLK, "O": PC.ENTROPY_O_ATOM_J_MOLK,
		"C": PC.ENTROPY_C_ATOM_J_MOLK, "N": PC.ENTROPY_N_ATOM_J_MOLK,
	}


## Dissociated fraction at temperature and pressure, from the law of mass action. M <-> v atoms, with
## dG = dH_atomisation - T dS and dS the free atoms' standard entropies minus the molecule's.
static func dissociated_fraction(id: String, t_k: float, p_pa: float) -> float:
	var s: Dictionary = table().get(id, {})
	var dh: float = float(s.get("atomisation_j_mol", 0.0))
	var s_mol: float = float(s.get("entropy_gas_j_molk", 0.0))
	if dh <= 0.0 or s_mol <= 0.0 or t_k <= 0.0:
		return 0.0
	var s_ent: Dictionary = element_entropy_j_molk()
	var nu: float = 0.0
	var s_atoms: float = 0.0
	for el in s.get("formula", {}):
		var n: float = float(s["formula"][el])
		if not s_ent.has(el):
			return 0.0
		nu += n
		s_atoms += n * float(s_ent[el])
	if nu <= 1.0:
		return 0.0
	var dg: float = dh - t_k * (s_atoms - s_mol)
	var ln_k: float = -dg / (PC.GAS_CONSTANT_J_MOL_K * t_k)
	# Bisect on the extent. K_p(alpha) is monotonic increasing, so a bracket search is exact to tolerance.
	var pr: float = maxf(p_pa, 1.0) / PC.STANDARD_PRESSURE_PA
	var lo: float = 0.0
	var hi: float = 1.0
	for _i in range(48):
		var a: float = 0.5 * (lo + hi)
		var tot: float = 1.0 + (nu - 1.0) * a
		var x_a: float = nu * a / tot
		var x_m: float = (1.0 - a) / tot
		var lhs: float = -1.0e30
		if x_m > 1.0e-30 and x_a > 1.0e-30:
			lhs = nu * log(x_a) - log(x_m) + (nu - 1.0) * log(pr)
		if lhs < ln_k:
			lo = a
		else:
			hi = a
	return 0.5 * (lo + hi)


## Ionised fraction from the SAHA equation, per element and mole-weighted. Single stage: the closed-form
## root of x^2/(1-x) = S. `n_m3` is the number density of heavy particles, from the ideal gas at the cell.
static func ionised_fraction(id: String, t_k: float, p_pa: float) -> float:
	var s: Dictionary = table().get(id, {})
	var f: Dictionary = s.get("formula", {})
	if f.is_empty() or t_k <= 0.0:
		return 0.0
	var n_m3: float = maxf(p_pa, 1.0) / (PC.BOLTZMANN_J_K * t_k)
	var kt: float = PC.BOLTZMANN_J_K * t_k
	# The thermal de Broglie factor, (2 pi m_e k T / h^2)^(3/2).
	var lam: float = pow(2.0 * PI * PC.ELECTRON_MASS_KG * kt / (PC.PLANCK_J_S * PC.PLANCK_J_S), 1.5)
	var ev: Dictionary = element_ionisation_ev()
	var dg: Dictionary = element_degen()
	var atoms: float = 0.0
	var ion_atoms: float = 0.0
	for el in f:
		var n: float = float(f[el])
		atoms += n
		if not ev.has(el) or not dg.has(el):
			continue
		var chi: float = float(ev[el]) * PC.EV_TO_J_PER_MOL / PC.AVOGADRO_PER_MOL
		var g: Array = dg[el]
		var ratio: float = 2.0 * float(g[1]) / maxf(float(g[0]), 1.0)
		var expo: float = -chi / kt
		var big: float = ratio * lam * exp(expo) / maxf(n_m3, 1.0)
		var x: float = 0.0
		if big > 0.0:
			x = 0.5 * (-big + sqrt(big * big + 4.0 * big))
		ion_atoms += n * clampf(x, 0.0, 1.0)
	return ion_atoms / atoms if atoms > 0.0 else 0.0


## Melting point at pressure, and depressed by dissolved solute. Clapeyron for the solid-liquid boundary:
## dT/dP = T dv / dH_fus, with dv = 1/rho_liquid - 1/rho_solid straight out of this table. For water dv is
static func melt_c_at(id: String, p_pa: float, molality_mol_kg: float = 0.0) -> float:
	var s: Dictionary = table().get(id, {})
	var t_ref_c: float = float(s.get("melt_c", INF))
	if not is_finite(t_ref_c):
		return INF
	# THE REFERENCE densities, not density() at (t, p): this is a rung of the phase ladder, and enthalpy.glsli
	# carries the same two constants and has no EOS to call. One curve, or the two sides are not one curve.
	var rho_l: float = float(s.get("density", 0.0))
	var rho_s: float = float(s.get("density_solid", rho_l))
	var l_fus: float = float(s.get("latent_fusion_j_kg", 0.0))
	var mm: float = float(s.get("molar_mass", 0.0))
	var t_ref_k: float = t_ref_c + PC.KELVIN_OFFSET
	var t_c: float = t_ref_c
	if rho_l > 0.0 and rho_s > 0.0 and l_fus > 0.0:
		var dv: float = (1.0 / rho_l) - (1.0 / rho_s)
		var p_ref: float = float(s.get("triple_p_pa", PC.STANDARD_PRESSURE_PA))
		t_c += (p_pa - p_ref) * t_ref_k * dv / l_fus
	if molality_mol_kg > 0.0 and l_fus > 0.0 and mm > 0.0:
		var l_molar: float = l_fus * mm
		var k_f: float = PC.GAS_CONSTANT_J_MOL_K * t_ref_k * t_ref_k * mm / l_molar
		t_c -= k_f * molality_mol_kg
	return t_c


## THE LIQUIDUS AT PRESSURE — the temperature the last crystal goes. Water is the degenerate case where it
## meets the solidus. DECISION, not a law: the interval keeps its width, both ends on one Clapeyron slope.
static func liquidus_c_at(id: String, p_pa: float, molality_mol_kg: float = 0.0) -> float:
	var s: Dictionary = table().get(id, {})
	var solidus: float = melt_c_at(id, p_pa, molality_mol_kg)
	if not is_finite(solidus):
		return INF
	var t_sol: float = float(s.get("melt_c", INF))
	var t_liq: float = float(s.get("liquidus_c", t_sol))
	if not is_finite(t_sol) or not is_finite(t_liq):
		return solidus
	return solidus + maxf(t_liq - t_sol, 0.0)


## THE LIQUID-VAPOUR BOUNDARY READ AS A PRESSURE — boil_c_at() inverted, so one curve answers from either
## end and the plateau's temperature cannot disagree with the latent heat charged to cross it.
static func saturation_p_at(id: String, t_c: float) -> float:
	var s: Dictionary = table().get(id, {})
	var t_ref_c: float = float(s.get("boil_c", INF))
	if not is_finite(t_ref_c):
		return 0.0
	var b: float = _clapeyron_b(id)
	if b <= 0.0:
		return 0.0
	var t_crit: float = float(s.get("critical_t_c", INF))
	if is_finite(t_crit) and t_c >= t_crit:
		return float(s.get("critical_p_pa", 0.0))
	var p_ref: float = float(s.get("boil_ref_p_pa", PC.STANDARD_PRESSURE_PA))
	var t_k: float = maxf(t_c + PC.KELVIN_OFFSET, 1.0)
	var t_ref_k: float = t_ref_c + PC.KELVIN_OFFSET
	return p_ref * exp(-b * (1.0 / t_k - 1.0 / t_ref_k))


## Sublimation pressure at temperature — the solid-vapour boundary, Clausius-Clapeyron anchored on the
## triple point with the SUBLIMATION enthalpy (fusion + vaporisation, derived, so Hess still closes).
static func sublimation_p_at(id: String, t_c: float) -> float:
	var s: Dictionary = table().get(id, {})
	var t3: float = float(s.get("triple_t_c", INF))
	var p3: float = float(s.get("triple_p_pa", 0.0))
	if not is_finite(t3) or p3 <= 0.0:
		return 0.0
	var l_sub: float = latent_sublimation_j_kg(id)
	if l_sub <= 0.0:
		return 0.0
	var t3_k: float = t3 + PC.KELVIN_OFFSET
	var t_k: float = maxf(t_c + PC.KELVIN_OFFSET, 1.0)
	return p3 * exp(-(l_sub / PC.VAPOUR_GAS_CONST_J_KGK) * (1.0 / t_k - 1.0 / t3_k))


## THE FROST POINT AT A GIVEN PRESSURE, C — sublimation_p_at() inverted, so the solid-vapour boundary is one
## curve read from either end. Below the triple point the solid leaves at THIS temperature, not at the
## melting point: the fusion curve does not exist down here.
static func sublimation_c_at(id: String, p_pa: float) -> float:
	var s: Dictionary = table().get(id, {})
	var t3: float = float(s.get("triple_t_c", INF))
	var p3: float = float(s.get("triple_p_pa", 0.0))
	if not is_finite(t3) or p3 <= 0.0:
		return INF
	var l_sub: float = latent_sublimation_j_kg(id)
	if l_sub <= 0.0:
		return t3
	var inv_t: float = 1.0 / (t3 + PC.KELVIN_OFFSET) \
		- (PC.VAPOUR_GAS_CONST_J_KGK / l_sub) * log(maxf(p_pa, 1.0e-12) / p3)
	if inv_t <= 0.0:
		return t3
	return 1.0 / inv_t - PC.KELVIN_OFFSET


## True when this substance has NO liquid phase at this pressure: below the triple-point pressure a solid
## goes straight to vapour, which is how snow leaves a cold dry summit without ever melting.
static func sublimes_at(id: String, p_pa: float) -> bool:
	var p3: float = float(table().get(id, {}).get("triple_p_pa", 0.0))
	return p3 > 0.0 and p_pa < p3


## Ionisation energy per kg, DERIVED from `formula` and the per-element first ionisation energies. One
## number per element, never one per compound — the same rule the stoichiometry follows.
static func ionisation_j_kg(id: String) -> float:
	var s: Dictionary = table().get(id, {})
	var f: Dictionary = s.get("formula", {})
	var mm: float = float(s.get("molar_mass", 0.0))
	if f.is_empty() or mm <= 0.0:
		return 0.0
	var ev: Dictionary = element_ionisation_ev()
	var j_mol: float = 0.0
	for el in f:
		if not ev.has(el):
			return 0.0
		j_mol += float(f[el]) * float(ev[el]) * PC.EV_TO_J_PER_MOL
	return j_mol / mm


## Atomisation enthalpy per kg — the gas -> free atoms rung. Declared per substance because it is a measured
## quantity and the table carries atom COUNTS, not a bond graph.
static func dissociation_j_kg(id: String) -> float:
	var s: Dictionary = table().get(id, {})
	var j_mol: float = float(s.get("atomisation_j_mol", 0.0))
	var mm: float = float(s.get("molar_mass", 0.0))
	return j_mol / mm if (j_mol > 0.0 and mm > 0.0) else 0.0


static func latent_vaporisation_at(id: String, t_c: float) -> float:
	var s: Dictionary = table().get(id, {})
	var l_ref: float = float(s.get("latent_vaporisation_j_kg", 0.0))
	if l_ref <= 0.0:
		return 0.0
	var t_crit: float = float(s.get("critical_t_c", INF))
	if not is_finite(t_crit):
		return l_ref
	if t_c >= t_crit:
		return 0.0
	var t_ref: float = float(s.get("latent_vaporisation_ref_t_c", 0.0))
	var span_ref: float = t_crit - t_ref
	if span_ref <= 0.0:
		return l_ref
	return l_ref * pow((t_crit - t_c) / span_ref, PC.WATSON_LATENT_EXPONENT)


## Is this substance past its critical point at these conditions? Above it there is one fluid phase, no
## boiling, and no latent heat — so a caller that branches on "liquid or gas" has no valid answer and must
## ask this first.
static func is_supercritical(id: String, t_c: float, p_pa: float) -> bool:
	var s: Dictionary = table().get(id, {})
	var t_crit: float = float(s.get("critical_t_c", INF))
	var p_crit: float = float(s.get("critical_p_pa", INF))
	if not is_finite(t_crit) or not is_finite(p_crit):
		return false
	return t_c >= t_crit and p_pa >= p_crit


static func enthalpy_to_state(id: String, h_j_kg: float, p_pa: float = PC.STANDARD_PRESSURE_PA,
		molality_mol_kg: float = 0.0) -> Dictionary:
	var s: Dictionary = table().get(id, {})
	var c_sol: float = float(s.get("specific_heat_solid", s.get("specific_heat", 0.0)))
	var c_liq: float = float(s.get("specific_heat", 0.0))
	var c_gas: float = float(s.get("specific_heat_gas", c_liq))
	# Pressure-dependent, and depressed by dissolved solute. For water the Clapeyron slope is negative.
	var melt: float = melt_c_at(id, p_pa, molality_mol_kg)
	var liquidus: float = liquidus_c_at(id, p_pa, molality_mol_kg)
	# THE BOUNDARY AT THIS PRESSURE, not the one-atmosphere reference point. See boil_c_at().
	var boil: float = boil_c_at(id, p_pa)
	var l_fus: float = float(s.get("latent_fusion_j_kg", 0.0))
	# THE LATENT HEAT AT THE BOUNDARY, not at whichever temperature the table happened to quote. At high
	# pressure the boundary moves up the curve and the plateau it costs to cross gets SHORTER, reaching zero
	# at the critical point — which is why a supercritical cell has no plateau at all below.
	var l_vap: float = latent_vaporisation_at(id, boil) if is_finite(boil) else 0.0

	if not is_finite(melt):
		# A substance this planet never melts — silica, the gases. Temperature is sensible heat alone.
		var c: float = c_sol if c_sol > 0.0 else c_liq
		return {"t_c": (h_j_kg / c) - PC.KELVIN_OFFSET if c > 0.0 else 0.0,
			"phase": SOLID, "melted": 0.0, "vaporised": 0.0}

	# NO LIQUID BELOW THE TRIPLE POINT. Ice on a cold dry summit leaves as vapour without ever melting, so
	# the plateau it crosses is SUBLIMATION at the frost point, not fusion, and the next ramp is the gas.
	if sublimes_at(id, p_pa):
		var t_sub: float = sublimation_c_at(id, p_pa)
		var h_sub_start: float = c_sol * (t_sub + PC.KELVIN_OFFSET)
		if h_j_kg <= h_sub_start:
			return {"t_c": (h_j_kg / c_sol) - PC.KELVIN_OFFSET if c_sol > 0.0 else t_sub,
				"phase": SOLID, "melted": 0.0, "vaporised": 0.0, "sublimating": true,
				"dissociated": 0.0, "ionised": 0.0}
		var l_sub: float = latent_sublimation_j_kg(id)
		var h_sub_end: float = h_sub_start + l_sub
		if h_j_kg < h_sub_end:
			return {"t_c": t_sub, "phase": SOLID, "melted": 0.0,
				"vaporised": (h_j_kg - h_sub_start) / l_sub if l_sub > 0.0 else 1.0,
				"sublimating": true, "dissociated": 0.0, "ionised": 0.0}
		var st: Dictionary = _gas_state(id, h_j_kg, p_pa, t_sub, h_sub_end, c_gas, 0.0)
		st["sublimating"] = true
		return st

	var h_melt_start: float = c_sol * (melt + PC.KELVIN_OFFSET)
	if h_j_kg <= h_melt_start:
		return {"t_c": (h_j_kg / c_sol) - PC.KELVIN_OFFSET if c_sol > 0.0 else melt,
			"phase": SOLID, "melted": 0.0, "vaporised": 0.0}

	var h_melt_end: float = h_melt_start + l_fus + c_liq * (liquidus - melt)
	if h_j_kg < h_melt_end:
		# IN THE MUSH: temperature RISES through the melting interval as the crystals go. The quadratic is
		# the lever rule solved for the melt fraction; a zero-width interval leaves phi = dh / l_fus and the
		# temperature pinned, which is why a lake holds near 0 C for weeks as it freezes.
		var dh: float = h_j_kg - h_melt_start
		var dt: float = liquidus - melt
		var a2: float = (c_liq - c_sol) * dt
		var a1: float = c_sol * dt + l_fus
		var phi: float = 2.0 * dh / (a1 + sqrt(a1 * a1 + 4.0 * a2 * dh))
		return {"t_c": melt + phi * dt, "phase": SOLID, "melted": phi, "vaporised": 0.0}

	if not is_finite(boil):
		return {"t_c": liquidus + (h_j_kg - h_melt_end) / c_liq if c_liq > 0.0 else liquidus,
			"phase": LIQUID, "melted": 1.0, "vaporised": 0.0}

	var h_boil_start: float = h_melt_end + c_liq * (boil - liquidus)
	if h_j_kg <= h_boil_start:
		return {"t_c": liquidus + (h_j_kg - h_melt_end) / c_liq if c_liq > 0.0 else liquidus,
			"phase": LIQUID, "melted": 1.0, "vaporised": 0.0}

	var h_boil_end: float = h_boil_start + l_vap
	if h_j_kg < h_boil_end:
		return {"t_c": boil, "phase": LIQUID, "melted": 1.0,
			"vaporised": (h_j_kg - h_boil_start) / l_vap if l_vap > 0.0 else 1.0}

	return _gas_state(id, h_j_kg, p_pa, boil, h_boil_end, c_gas, 1.0)


## ABOVE A CONDENSATION PLATEAU the two high transitions are EQUILIBRIA, not plateaus (law of mass action,
## Saha), so enthalpy stays continuous and monotonic and the state is found by inverting it. `ref_t_c` is
## the plateau's temperature and `h_ref` its top, so boiling and sublimation share one tail.
static func _gas_state(id: String, h_j_kg: float, p_pa: float, ref_t_c: float, h_ref: float,
		c_gas: float, melted: float) -> Dictionary:
	var s: Dictionary = table().get(id, {})
	var t_gas: float = _invert_gas_enthalpy(id, h_j_kg, p_pa, ref_t_c, h_ref, c_gas)
	var t_k: float = t_gas + PC.KELVIN_OFFSET
	var a_d: float = dissociated_fraction(id, t_k, p_pa)
	var a_i: float = ionised_fraction(id, t_k, p_pa)
	var ph: int = GAS
	var p_crit: float = float(s.get("critical_p_pa", INF))
	var t_crit: float = float(s.get("critical_t_c", INF))
	if is_finite(p_crit) and p_pa >= p_crit and t_gas >= t_crit:
		ph = SUPERCRITICAL
	if a_i >= 0.5:
		ph = PLASMA
	elif a_d >= 0.5:
		ph = ATOMS
	return {"t_c": t_gas, "phase": ph, "melted": melted, "vaporised": 1.0,
		"dissociated": a_d, "ionised": a_i}


## Invert h(T) above the boiling plateau. h rises monotonically with T — sensible heat plus the two
## equilibrium enthalpies, both of which only increase — so bisection is exact to tolerance and needs no
## starting guess.
static func _invert_gas_enthalpy(id: String, h_j_kg: float, p_pa: float, boil: float,
		h_boil_end: float, c_gas: float) -> float:
	var lo: float = boil
	var hi: float = boil + 1.0e5
	for _i in range(60):
		var mid: float = 0.5 * (lo + hi)
		if _gas_enthalpy_at(id, mid, p_pa, boil, h_boil_end, c_gas) < h_j_kg:
			lo = mid
		else:
			hi = mid
	return 0.5 * (lo + hi)


## Specific enthalpy at a temperature above boiling: sensible heat of the gas, plus the share of the
## atomisation and ionisation energies the equilibrium has actually paid for at that temperature.
static func _gas_enthalpy_at(id: String, t_c: float, p_pa: float, boil: float,
		h_boil_end: float, c_gas: float) -> float:
	var t_k: float = t_c + PC.KELVIN_OFFSET
	var a_d: float = dissociated_fraction(id, t_k, p_pa)
	var a_i: float = ionised_fraction(id, t_k, p_pa)
	# Once dissociated the carrier is monatomic, so the sensible term crosses over with the fraction.
	var c_eff: float = c_gas + (_monatomic_c_j_kgk(id) - c_gas) * a_d
	return h_boil_end + c_eff * (t_c - boil) + a_d * dissociation_j_kg(id) + a_d * a_i * ionisation_j_kg(id)


## Monatomic ideal-gas heat capacity of the dissociated substance, J/kgK: (3/2)R per mole of ATOMS.
static func _monatomic_c_j_kgk(id: String) -> float:
	var s: Dictionary = table().get(id, {})
	var mm: float = float(s.get("molar_mass", 0.0))
	var atoms: float = 0.0
	for el in s.get("formula", {}):
		atoms += float(s["formula"][el])
	if mm <= 0.0 or atoms <= 0.0:
		return 0.0
	return 1.5 * PC.GAS_CONSTANT_J_MOL_K * atoms / mm
