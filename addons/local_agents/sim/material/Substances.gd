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
			"atomisation_j_mol": PC.ATOMISATION_H2O_J_MOL,
			"entropy_gas_j_molk": 188.835,
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
			"triple_t_c": PC.WATER_TRIPLE_T_C,
			"triple_p_pa": PC.WATER_TRIPLE_P_PA,
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
			"atomisation_j_mol": PC.ATOMISATION_O2_J_MOL,
			"entropy_gas_j_molk": 205.152,
			"density": PC.AMBIENT_O2_DENSITY_KG_M3,
			"specific_heat": PC.AIR_SPECIFIC_HEAT_J_KGK,
		},
		"co2": {
			"formula": {"C": 1.0, "O": 2.0},
			"molar_mass": PC.MOLAR_MASS_CO2_KG_MOL,
			"atomisation_j_mol": PC.ATOMISATION_CO2_J_MOL,
			"entropy_gas_j_molk": 213.785,
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
const ATOMS: int = 3
const PLASMA: int = 4
const SUPERCRITICAL: int = 5


## were three constants: 2.257e6 (quoted at 100 C) + 3.337e5 fell 2.433e5 J/kg short of a 2.834e6 stated at
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
## Per-element data, keyed the way `formula` is. One row per element, never one per compound.
const ELEMENT_IONISATION_EV: Dictionary = {
	"H": PC.IONISATION_EV_H, "O": PC.IONISATION_EV_O, "C": PC.IONISATION_EV_C, "N": PC.IONISATION_EV_N,
	"Si": PC.IONISATION_EV_SI, "Ca": PC.IONISATION_EV_CA, "Fe": PC.IONISATION_EV_FE,
	"Mg": PC.IONISATION_EV_MG, "Al": PC.IONISATION_EV_AL,
}
const ELEMENT_DEGEN: Dictionary = {
	"H": [PC.DEGEN_H_0, PC.DEGEN_H_1], "O": [PC.DEGEN_O_0, PC.DEGEN_O_1],
	"C": [PC.DEGEN_C_0, PC.DEGEN_C_1], "N": [PC.DEGEN_N_0, PC.DEGEN_N_1],
}
const ELEMENT_ENTROPY_J_MOLK: Dictionary = {
	"H": PC.ENTROPY_H_ATOM_J_MOLK, "O": PC.ENTROPY_O_ATOM_J_MOLK,
	"C": PC.ENTROPY_C_ATOM_J_MOLK, "N": PC.ENTROPY_N_ATOM_J_MOLK,
}


## Dissociated fraction at temperature and pressure, from the law of mass action. M <-> v atoms, with
## dG = dH_atomisation - T dS and dS the free atoms' standard entropies minus the molecule's.
## No onset temperature: the fraction rises smoothly and is nonzero everywhere, which is what a real
## equilibrium does.
static func dissociated_fraction(id: String, t_k: float, p_pa: float) -> float:
	var s: Dictionary = table().get(id, {})
	var dh: float = float(s.get("atomisation_j_mol", 0.0))
	var s_mol: float = float(s.get("entropy_gas_j_molk", 0.0))
	if dh <= 0.0 or s_mol <= 0.0 or t_k <= 0.0:
		return 0.0
	var nu: float = 0.0
	var s_atoms: float = 0.0
	for el in s.get("formula", {}):
		var n: float = float(s["formula"][el])
		if not ELEMENT_ENTROPY_J_MOLK.has(el):
			return 0.0
		nu += n
		s_atoms += n * float(ELEMENT_ENTROPY_J_MOLK[el])
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
	var atoms: float = 0.0
	var ion_atoms: float = 0.0
	for el in f:
		var n: float = float(f[el])
		atoms += n
		if not ELEMENT_IONISATION_EV.has(el) or not ELEMENT_DEGEN.has(el):
			continue
		var chi: float = float(ELEMENT_IONISATION_EV[el]) * PC.EV_TO_J_PER_MOL / PC.AVOGADRO_PER_MOL
		var g: Array = ELEMENT_DEGEN[el]
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
## NEGATIVE because ice floats, so ice melts at a LOWER temperature under load — which is why a glacier
## slides on its own base. Nothing here is a new number.
##
## `molality` is mol of dissolved particles per kg of solvent. The cryoscopic constant is DERIVED, not
## tabulated: K_f = R T_f^2 M / dH_fus,molar, which comes out at 1.859 K kg/mol for water against the
## measured 1.86. Sea water at ~1.16 mol/kg of ions therefore freezes near -2.2 C.
static func melt_c_at(id: String, p_pa: float, molality_mol_kg: float = 0.0) -> float:
	var s: Dictionary = table().get(id, {})
	var t_ref_c: float = float(s.get("melt_c", INF))
	if not is_finite(t_ref_c):
		return INF
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
	var ev: Dictionary = {
		"H": PC.IONISATION_EV_H, "O": PC.IONISATION_EV_O, "C": PC.IONISATION_EV_C,
		"N": PC.IONISATION_EV_N, "Si": PC.IONISATION_EV_SI, "Ca": PC.IONISATION_EV_CA,
		"Fe": PC.IONISATION_EV_FE, "Mg": PC.IONISATION_EV_MG, "Al": PC.IONISATION_EV_AL,
	}
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

	# NO LIQUID BELOW THE TRIPLE POINT. Ice on a cold dry summit leaves as vapour without ever melting, so
	# the plateau it crosses is SUBLIMATION, not fusion, and the next ramp is the gas.
	if sublimes_at(id, p_pa):
		var l_sub: float = latent_sublimation_j_kg(id)
		var h_sub_end: float = h_melt_start + l_sub
		if h_j_kg < h_sub_end:
			return {"t_c": melt, "phase": SOLID, "melted": 0.0,
				"vaporised": (h_j_kg - h_melt_start) / l_sub if l_sub > 0.0 else 1.0,
				"sublimating": true, "dissociated": 0.0, "ionised": 0.0}
		return {"t_c": melt + (h_j_kg - h_sub_end) / c_gas if c_gas > 0.0 else melt,
			"phase": GAS, "melted": 0.0, "vaporised": 1.0, "sublimating": true,
			"dissociated": 0.0, "ionised": 0.0}

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

	# ABOVE THE BOILING PLATEAU the two high transitions are EQUILIBRIA, not plateaus: the dissociated and
	# ionised fractions rise smoothly with temperature (law of mass action, Saha). So enthalpy is a
	# continuous monotonic function of T and the state is found by inverting it.
	var t_gas: float = _invert_gas_enthalpy(id, h_j_kg, p_pa, boil, h_boil_end, c_gas)
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
	return {"t_c": t_gas, "phase": ph, "melted": 1.0, "vaporised": 1.0,
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
