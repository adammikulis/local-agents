class_name LASubstances
extends RefCounted

## ============================================================================================================
## ============================================================================================================
##     in "the O2 in a cell of ambient air" (8.535 mol/m3) and water channels in "a cell full of liquid
##     water" (55343 mol/m3). The balance gate compared them as equal, certifying every gas-to-water record
##     and sublimation at 0 C, so a closed water -> vapour -> snow -> water loop released 2.433e5 J/kg from
## kilogram (J/kg for a latent heat, J/kg/K for a specific heat). Storing energy and DERIVING temperature —
## air" is not a quantity anybody can check; 0.2731 kg/m3 is. Mass conservation stops needing a conversion
## phase. Hess's law cannot be violated because there is no set of independent latent heats left to
## disagree. The 2.433e5 J/kg leak above is not fixed here — it is made unwritable.

const PC = preload("res://addons/local_agents/sim/material/PhysicalConstants.gd")


##   molar_mass       kg/mol. The one bridge between the mass this table stores and the moles chemistry uses.
##   density          kg/m3 of the CONDENSED phase, for turning a mass into a volume fraction of a cell.
##   specific_heat    J/kg/K, by phase where they differ enough to matter (ice is half of liquid water).
##   conductivity     W/m/K.
static func table() -> Dictionary:
	return {
		# --- WATER ------------------------------------------------------------------------------------------
		# right — by Hess's law it is fusion plus vaporisation at the same temperature, and stating it
		# separately is what let the three disagree by 2.433e5 J/kg. `latent_sublimation` is a function below,
		"h2o": {
			"formula": {"H": 2.0, "O": 1.0},
			"molar_mass": PC.MOLAR_MASS_WATER_KG_MOL,
			"density": PC.WATER_DENSITY_KG_M3,
			"density_solid": PC.ICE_DENSITY_KG_M3,
			"specific_heat": PC.WATER_SPECIFIC_HEAT_J_KGK,
			"specific_heat_solid": PC.ICE_SPECIFIC_HEAT_J_KGK,
			"specific_heat_gas": PC.VAPOUR_SPECIFIC_HEAT_J_KGK,
			"melt_c": PC.WATER_FREEZE_C,
			"boil_c": PC.WATER_BOIL_C,
			"boil_ref_p_pa": PC.STANDARD_PRESSURE_PA,
			# ABOVE THIS THERE IS NO LIQUID-VAPOUR BOUNDARY. Water is one supercritical phase: no meniscus,
			# no boiling, and a latent heat of exactly zero. A post-Theia steam envelope sits near here, so
			# leaving it out does not just misplace the boundary, it asserts one that does not exist.
			"critical_t_c": PC.WATER_CRITICAL_T_C,
			"critical_p_pa": PC.WATER_CRITICAL_P_PA,
			"latent_fusion_j_kg": PC.LATENT_HEAT_FUSION_J_KG,
			# Quoted at 0 C. It is a FUNCTION of temperature — `latent_vaporisation_at()` — and this entry is
			# the anchor, not the value to use at an arbitrary temperature.
			"latent_vaporisation_j_kg": PC.LATENT_HEAT_VAPORISATION_0C_J_KG,
			"latent_vaporisation_ref_t_c": PC.WATER_FREEZE_C,
			"conductivity": PC.THERMAL_CONDUCT_WATER_W_MK,
			"emissivity": PC.EMISSIVITY_WATER,
			"albedo": PC.ALBEDO_OCEAN,
			"albedo_solid": PC.ALBEDO_SNOW_ICE,
		},

		# --- THE ATMOSPHERE'S GASES -------------------------------------------------------------------------
		# Stored as masses like everything else. Their ratios in the seeded air are mole fractions of a
		"o2": {
			"formula": {"O": 2.0},
			"molar_mass": PC.MOLAR_MASS_O2_KG_MOL,
			"density": PC.AMBIENT_O2_DENSITY_KG_M3,
			"specific_heat": PC.AIR_SPECIFIC_HEAT_J_KGK,
		},
		"co2": {
			"formula": {"C": 1.0, "O": 2.0},
			"molar_mass": PC.MOLAR_MASS_CO2_KG_MOL,
			"density": PC.AMBIENT_O2_DENSITY_KG_M3 * (PC.MOLAR_MASS_CO2_KG_MOL / PC.MOLAR_MASS_O2_KG_MOL),
			"specific_heat": PC.AIR_SPECIFIC_HEAT_J_KGK,
		},

		# --- ORGANIC MATTER ---------------------------------------------------------------------------------
		"cellulose": {
			"formula": {"C": 1.0, "H": 2.0, "O": 1.0,
				"N": (PC.MOLAR_MASS_CARBON_KG_MOL / PC.LITTER_C_TO_N) / PC.MOLAR_MASS_NITROGEN_KG_MOL},
			"molar_mass": PC.MOLAR_MASS_CH2O_UNIT_KG_MOL,
			"density": PC.DRY_WOOD_DENSITY_KG_M3,
			"specific_heat": PC.DRY_WOOD_SPECIFIC_HEAT_J_KGK,
			# PER KG OF FUEL. This held HEAT_PER_KG_OXYGEN_J, which is Huggett's constant — joules per kg of OXYGEN
			# PhysicalConstants 160 lines from the wrong one. Unread so far, which is the only reason the fire
			# path and the metabolism path have not yet disagreed about the energy content of one molecule.
			"heat_of_combustion_j_kg": PC.BIOMASS_HEAT_OF_COMBUSTION_J_PER_KG,
			"pyrolysis_ea_over_r_k": PC.CELLULOSE_PYROLYSIS_EA_OVER_R_K,
			"albedo": PC.ALBEDO_VEGETATION,
		},

		# --- MINERALS ---------------------------------------------------------------------------------------
		# are the standard proxies every carbon-cycle model uses (Walker, Hays & Kasting 1981).
		"silicate": {
			"formula": {"Ca": 1.0, "Si": 1.0, "O": 3.0},
			"molar_mass": PC.MOLAR_MASS_CASIO3_KG_MOL,
			"density": PC.ROCK_DENSITY_KG_M3,
			"specific_heat": PC.ROCK_SPECIFIC_HEAT_J_KGK,
			"melt_c": PC.BASALT_SOLIDUS_C,
			"latent_fusion_j_kg": PC.BASALT_LATENT_HEAT_CRYSTALLISATION_J_KG,
			"conductivity": PC.THERMAL_CONDUCT_ROCK_W_MK,
			"emissivity": PC.BASALT_EMISSIVITY,
			"albedo": PC.ALBEDO_BARE_GROUND,
		},
		"silica": {
			"formula": {"Si": 1.0, "O": 2.0},
			"molar_mass": PC.MOLAR_MASS_SIO2_KG_MOL,
			"density": PC.QUARTZ_DENSITY_KG_M3,
			"specific_heat": PC.ROCK_SPECIFIC_HEAT_J_KGK,
			"conductivity": PC.THERMAL_CONDUCT_ROCK_W_MK,
			"emissivity": PC.BASALT_EMISSIVITY,
			"albedo": PC.ALBEDO_BARE_GROUND,
		},
		"carbonate": {
			"formula": {"Ca": 1.0, "C": 1.0, "O": 3.0},
			"molar_mass": PC.MOLAR_MASS_CACO3_KG_MOL,
			"density": PC.CALCITE_DENSITY_KG_M3,
			"specific_heat": PC.ROCK_SPECIFIC_HEAT_J_KGK,
			"conductivity": PC.THERMAL_CONDUCT_ROCK_W_MK,
			"emissivity": PC.BASALT_EMISSIVITY,
			"albedo": PC.ALBEDO_BARE_GROUND,
		},

		# --- MINERAL NITROGEN -------------------------------------------------------------------------------
		# Plant-available N in the soil. Modelled as the element because this substrate has no nitrate,
		# ammonium or N2 channel to distinguish, and saying so is more honest than implying a molecule.
		"fixed_n": {
			"formula": {"N": 1.0},
			"molar_mass": PC.MOLAR_MASS_NITROGEN_KG_MOL,
			"density": PC.ROCK_DENSITY_KG_M3,
			"specific_heat": PC.ROCK_SPECIFIC_HEAT_J_KGK,
		},
	}


## SOLID / LIQUID / GAS, derived — never stored.
const SOLID: int = 0
const LIQUID: int = 1
const GAS: int = 2


## Latent heat of sublimation, J/kg — DERIVED as fusion + vaporisation so Hess's law cannot be violated.
static func latent_sublimation_j_kg(id: String) -> float:
	var s: Dictionary = table().get(id, {})
	return float(s.get("latent_fusion_j_kg", 0.0)) + float(s.get("latent_vaporisation_j_kg", 0.0))


## Moles of substance in one kilogram — the ONLY bridge between what the field stores (mass) and what
## chemistry counts (atoms). It replaces `LAReactionBalance.mol_per_unit()`, which existed to reconcile two
## invented denominations that no longer exist.
static func mol_per_kg(id: String) -> float:
	var m: float = float(table().get(id, {}).get("molar_mass", 0.0))
	return 1.0 / m if m > 0.0 else 0.0


## Atoms per KILOGRAM of a substance, which is what a conservation ledger has to sum. `formula` is per MOLE;
## forgetting to convert is the defect that let the balance gate compare 8.535 mol/m3 against 55343 as though
## they were equal.
static func atoms_per_kg(id: String) -> Dictionary:
	var s: Dictionary = table().get(id, {})
	var per_mol: Dictionary = s.get("formula", {})
	var n: float = mol_per_kg(id)
	var out: Dictionary = {}
	for el in per_mol:
		out[el] = float(per_mol[el]) * n
	return out


## SPECIFIC ENTHALPY (J/kg) of a substance at a temperature, measured from its solid at 0 K — the curve whose
## flat sections ARE the latent heats. This is the function that makes phase a consequence rather than a
## channel: sensible heat through each phase, plus the full latent step at each boundary crossed.
static func enthalpy_at(id: String, t_c: float) -> float:
	var s: Dictionary = table().get(id, {})
	var c_sol: float = float(s.get("specific_heat_solid", s.get("specific_heat", 0.0)))
	var c_liq: float = float(s.get("specific_heat", 0.0))
	var c_gas: float = float(s.get("specific_heat_gas", c_liq))
	var melt: float = float(s.get("melt_c", INF))
	var boil: float = float(s.get("boil_c", INF))
	var t_k: float = t_c + PC.KELVIN_OFFSET
	if not is_finite(melt) or t_c <= melt:
		return c_sol * t_k
	var h: float = c_sol * (melt + PC.KELVIN_OFFSET) + float(s.get("latent_fusion_j_kg", 0.0))
	if not is_finite(boil) or t_c <= boil:
		return h + c_liq * (t_c - melt)
	h += c_liq * (boil - melt) + float(s.get("latent_vaporisation_j_kg", 0.0))
	return h + c_gas * (t_c - boil)


## THE BOILING POINT AT A GIVEN PRESSURE. Clausius-Clapeyron, integrated with the latent heat taken as
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
	# The latent heat at the REFERENCE point, which is what the integrated form is anchored on.
	var l: float = latent_vaporisation_at(id, t_ref_c)
	if l <= 0.0:
		return t_ref_c
	var inv_t: float = 1.0 / t_ref_k - (PC.VAPOUR_GAS_CONST_J_KGK / l) * log(p / p_ref)
	if inv_t <= 0.0:
		return t_crit if is_finite(t_crit) else t_ref_c
	var t_c: float = 1.0 / inv_t - PC.KELVIN_OFFSET
	# The boundary cannot run past the critical point; beyond it the two phases are one.
	return minf(t_c, t_crit) if is_finite(t_crit) else t_c


## constants with the relation between them written in a comment. Watson correlation:
## that is physically ZERO. Watson has the right asymptote — L goes to zero at Tc, because that is what a
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


static func enthalpy_to_state(id: String, h_j_kg: float, p_pa: float = PC.STANDARD_PRESSURE_PA) -> Dictionary:
	var s: Dictionary = table().get(id, {})
	var c_sol: float = float(s.get("specific_heat_solid", s.get("specific_heat", 0.0)))
	var c_liq: float = float(s.get("specific_heat", 0.0))
	var c_gas: float = float(s.get("specific_heat_gas", c_liq))
	var melt: float = float(s.get("melt_c", INF))
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

	var h_melt_start: float = c_sol * (melt + PC.KELVIN_OFFSET)
	if h_j_kg <= h_melt_start:
		return {"t_c": (h_j_kg / c_sol) - PC.KELVIN_OFFSET if c_sol > 0.0 else melt,
			"phase": SOLID, "melted": 0.0, "vaporised": 0.0}

	var h_melt_end: float = h_melt_start + l_fus
	if h_j_kg < h_melt_end:
		# ON the melting plateau: temperature is pinned at the boundary while the latent heat goes in. This
		# is why a lake holds near 0 C for weeks as it freezes.
		return {"t_c": melt, "phase": SOLID,
			"melted": (h_j_kg - h_melt_start) / l_fus if l_fus > 0.0 else 1.0, "vaporised": 0.0}

	if not is_finite(boil):
		return {"t_c": melt + (h_j_kg - h_melt_end) / c_liq if c_liq > 0.0 else melt,
			"phase": LIQUID, "melted": 1.0, "vaporised": 0.0}

	var h_boil_start: float = h_melt_end + c_liq * (boil - melt)
	if h_j_kg <= h_boil_start:
		return {"t_c": melt + (h_j_kg - h_melt_end) / c_liq if c_liq > 0.0 else melt,
			"phase": LIQUID, "melted": 1.0, "vaporised": 0.0}

	var h_boil_end: float = h_boil_start + l_vap
	if h_j_kg < h_boil_end:
		return {"t_c": boil, "phase": LIQUID, "melted": 1.0,
			"vaporised": (h_j_kg - h_boil_start) / l_vap if l_vap > 0.0 else 1.0}

	return {"t_c": boil + (h_j_kg - h_boil_end) / c_gas if c_gas > 0.0 else boil,
		"phase": GAS, "melted": 1.0, "vaporised": 1.0}
