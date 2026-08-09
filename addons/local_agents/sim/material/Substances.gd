class_name LASubstances
extends RefCounted

## THE SUBSTANCE TABLE — every measured property of every material this planet is made of, in ONE entry per
## material, and the single source everything else is a view of.
##
## ============================================================================================================
## WHY THIS EXISTS: A MATERIAL'S PROPERTIES WERE SCATTERED ACROSS FIVE PLACES AND JOINED BY NAMING CONVENTION.
## ============================================================================================================
##
## There was no object called "water" anywhere in this codebase. There were about twelve constants in
## `PhysicalConstants.gd` whose names happened to begin with `WATER_`, plus an entry in the slot enum in
## `ReactionDefs.gd`, plus an entry in `LAReactionBalance.composition()`, plus an entry in
## `LAReactionBalance.mol_per_unit()`, plus hand-copied literals in six GLSL kernels bound only by a trailing
## comment that a shell script checked numerically. Nothing related them except that a person had typed
## `WATER_` at the front of each.
##
## Every one of the following came out of that, and each was found and patched SEPARATELY before anyone
## noticed they were one defect:
##
##   * IGNITION WAS A GLOBAL. `VEGETATION_IGNITION_C = 300.0` applied to every combustible cell on the
##     planet, because there was nowhere for a fuel to carry its own ignition behaviour. The flat namespace
##     has no slot for "a property OF cellulose", only for "a constant whose name mentions vegetation".
##   * MINERALS NEEDED A LUMPED FICTION. `M`, a mass with no stoichiometry, existed because rock had no
##     composition. Silicate weathering — the carbon sink that has regulated Earth's climate for four billion
##     years — could not be written at all, and was modelled with CO2 as a catalyst it never consumed.
##   * A CHANNEL UNIT WAS NOT A MOLE, AND THE CONSERVATION GATE DID NOT KNOW. Gas channels were denominated
##     in "the O2 in a cell of ambient air" (8.535 mol/m3) and water channels in "a cell full of liquid
##     water" (55343 mol/m3). The balance gate compared them as equal, certifying every gas-to-water record
##     as balanced while it was wrong by a factor of 6484.
##   * LATENT HEAT WAS SET AT TWO REFERENCE TEMPERATURES AT ONCE. Vaporisation quoted at 100 C beside fusion
##     and sublimation at 0 C, so a closed water -> vapour -> snow -> water loop released 2.433e5 J/kg from
##     nothing on every traverse. The file even carried a comment warning about that exact pairing.
##
## Adding a table to track each symptom is what produced `mol_per_unit()`. This is the fix instead.
##
## ============================================================================================================
## THE UNIT IS KILOGRAMS PER CUBIC METRE, AND THAT IS A DELIBERATE CHOICE OVER MOLES.
## ============================================================================================================
##
## Chemistry is stoichiometric in moles, so moles are the obvious candidate. Mass wins anyway, because this
## substrate is mostly PHYSICS with chemistry as one pass of twelve: heat capacity, buoyancy, hydrostatic
## pressure, erosion, slumping, advection and gravity are all mass-based, and thermodynamics is written per
## kilogram (J/kg for a latent heat, J/kg/K for a specific heat). Storing energy and DERIVING temperature —
## which is what this design turns on — is mass arithmetic end to end.
##
## Chemistry pays one multiply by `molar_mass` when the reaction table is built, and that conversion has to
## exist here regardless, because the balance gate counts ATOMS. Physics pays nothing. So: kilograms.
##
## It also replaces a made-up denomination with a real one. "One unit of o2 is the O2 in a cell of ambient
## air" is not a quantity anybody can check; 0.2731 kg/m3 is. Mass conservation stops needing a conversion
## table to state.
##
## ============================================================================================================
## PHASE IS NOT STORED. NEITHER IS TEMPERATURE.
## ============================================================================================================
##
## A substance has ONE conserved amount. Whether it is solid, liquid or gas follows from its energy and the
## phase boundaries declared here — which is what phase IS. The three H2O channels (`water`, `moisture`,
## `snow`) were three names for one substance, and the six "reactions" that moved mass between them
## (R21 freeze, R22 melt, R23/R24 evaporation, R25 sublimation) transformed nothing: they were bookkeeping
## between columns of one ledger, dressed as chemistry.
##
## THE CONSEQUENCE THAT MATTERS: latent heat stops being a number anyone can forget or mis-reference. If
## phase is a function of enthalpy, you cannot melt ice without moving the energy, because the energy IS the
## phase. Hess's law cannot be violated because there is no set of independent latent heats left to
## disagree. The 2.433e5 J/kg leak above is not fixed here — it is made unwritable.
##
## `latent_fusion_j_kg` and `latent_vaporisation_j_kg` below are therefore NOT charges applied by a reaction.
## They are the WIDTHS OF THE FLAT SECTIONS of the substance's enthalpy curve, which is what a latent heat
## has always physically been. See `enthalpy_to_state`.
##
## ============================================================================================================
## WHAT A NEW SUBSTANCE COSTS: one entry. What a new phenomenon costs: a reaction record over these.
## ============================================================================================================

const PC = preload("res://addons/local_agents/sim/material/PhysicalConstants.gd")


## Every substance, by id. A field channel names one of these; it does not name a phase.
##
## FIELDS, and each is a measured property with a citation — if you cannot say what a value is a property OF,
## it is a model parameter and does not belong here (the rule `PhysicalConstants.gd` already enforces):
##   formula          atoms per formula unit. The balance gate counts these; nothing else may.
##   molar_mass       kg/mol. The one bridge between the mass this table stores and the moles chemistry uses.
##   density          kg/m3 of the CONDENSED phase, for turning a mass into a volume fraction of a cell.
##   specific_heat    J/kg/K, by phase where they differ enough to matter (ice is half of liquid water).
##   melt_c, boil_c   phase boundaries at 1 atm, in C. Absent for a substance this planet never melts.
##   latent_*_j_kg    the flat sections of the enthalpy curve, at the boundary they belong to.
##   conductivity     W/m/K.
##   emissivity       thermal-infrared, for a surface of this material.
##   albedo           shortwave reflectance of a surface of this material.
static func table() -> Dictionary:
	return {
		# --- WATER ------------------------------------------------------------------------------------------
		# ONE substance in three phases. The phase boundaries are not negotiable and there is no hysteresis
		# in them: ice and liquid coexist at exactly one temperature, so freezing and melting are the same
		# number. (This project once had them 1.5 C apart, and at 12.5/14.0 rather than 0, because the planet
		# could not get cold and somebody moved the freezing point of water to meet it.)
		#
		# BOTH LATENT HEATS ARE AT 0 C AND THE THIRD IS NOT DECLARED. Sublimation is not a property in its own
		# right — by Hess's law it is fusion plus vaporisation at the same temperature, and stating it
		# separately is what let the three disagree by 2.433e5 J/kg. `latent_sublimation` is a function below,
		# not a field.
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
			"latent_fusion_j_kg": PC.LATENT_HEAT_FUSION_J_KG,
			"latent_vaporisation_j_kg": PC.LATENT_HEAT_VAPORISATION_0C_J_KG,
			"conductivity": PC.THERMAL_CONDUCT_WATER_W_MK,
			"emissivity": PC.EMISSIVITY_WATER,
			"albedo": PC.ALBEDO_OCEAN,
			"albedo_solid": PC.ALBEDO_SNOW_ICE,
		},

		# --- THE ATMOSPHERE'S GASES -------------------------------------------------------------------------
		# Stored as masses like everything else. Their ratios in the seeded air are mole fractions of a
		# measured atmosphere, not values anybody chose.
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
		# CH2O, the per-carbon empirical unit of a carbohydrate, plus the nitrogen the material actually
		# carries at its measured C:N ratio. Living tissue, dead litter and cured fuel are the SAME substance
		# in different places, which is why converting between them must move mass one-for-one.
		#
		# IGNITION IS A PROPERTY OF THIS ENTRY AND NOT A GLOBAL, and it is kinetics rather than a threshold.
		# A solid fuel has no ignition point the way water has a freezing point: it pyrolyses, releasing
		# volatiles at a rate that rises exponentially with temperature, and "ignition" is the name for the
		# moment that release outruns the losses. The measured quantity is the ACTIVATION ENERGY of that
		# pyrolysis, and it is what makes fire a thermal runaway rather than a branch.
		"cellulose": {
			"formula": {"C": 1.0, "H": 2.0, "O": 1.0,
				"N": (PC.MOLAR_MASS_CARBON_KG_MOL / PC.LITTER_C_TO_N) / PC.MOLAR_MASS_NITROGEN_KG_MOL},
			"molar_mass": PC.MOLAR_MASS_CH2O_UNIT_KG_MOL,
			"density": PC.DRY_WOOD_DENSITY_KG_M3,
			"specific_heat": PC.DRY_WOOD_SPECIFIC_HEAT_J_KGK,
			"heat_of_combustion_j_kg": PC.HEAT_PER_KG_OXYGEN_J,
			"pyrolysis_ea_over_r_k": PC.CELLULOSE_PYROLYSIS_EA_OVER_R_K,
			"albedo": PC.ALBEDO_VEGETATION,
		},

		# --- MINERALS ---------------------------------------------------------------------------------------
		# Three species, which is the minimum that lets the Urey reaction balance:
		#     CaSiO3 + CO2 -> CaCO3 + SiO2
		# Silicate is what the mantle makes, silica is the weathering residue that does not weather further,
		# and carbonate is where weathered carbon goes and the only place it CAN go. Wollastonite and calcite
		# are the standard proxies every carbon-cycle model uses (Walker, Hays & Kasting 1981).
		"silicate": {
			"formula": {"Ca": 1.0, "Si": 1.0, "O": 3.0},
			"molar_mass": PC.MOLAR_MASS_WOLLASTONITE_KG_MOL,
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
			"molar_mass": PC.MOLAR_MASS_SILICA_KG_MOL,
			"density": PC.ROCK_DENSITY_KG_M3,
			"specific_heat": PC.ROCK_SPECIFIC_HEAT_J_KGK,
			"conductivity": PC.THERMAL_CONDUCT_ROCK_W_MK,
			"emissivity": PC.BASALT_EMISSIVITY,
			"albedo": PC.ALBEDO_BARE_GROUND,
		},
		"carbonate": {
			"formula": {"Ca": 1.0, "C": 1.0, "O": 3.0},
			"molar_mass": PC.MOLAR_MASS_CALCITE_KG_MOL,
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


## Sublimation is fusion plus vaporisation AT THE SAME TEMPERATURE. It is a function, not a field, so that
## the three cannot be given independent values that disagree — which is exactly what happened when they
## were three constants: 2.257e6 (quoted at 100 C) + 3.337e5 fell 2.433e5 J/kg short of a 2.834e6 stated at
## 0 C, and every traverse of the water -> vapour -> snow -> water loop released the difference from nothing.
##
## The derived value is its own check: 2.501e6 + 3.337e5 = 2.8347e6 against a measured 2.834e6, agreeing to
## 0.02% — inside the uncertainty on the inputs. If that ever stops holding, one of the inputs is wrong.
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
	# AT EXACTLY THE PHASE BOUNDARY, ENTHALPY IS NOT A SINGLE VALUE — that is what a plateau MEANS: ice at
	# 0 C and water at 0 C differ by the whole latent heat. This returns the START of the plateau (still
	# solid), because "at its melting point a substance is solid until you pay the latent heat" is the
	# convention every phase diagram is drawn with, and it makes `enthalpy_at(melt) + f * L_fus` the enthalpy
	# of something f melted — the form every caller wants.
	if not is_finite(melt) or t_c <= melt:
		return c_sol * t_k
	var h: float = c_sol * (melt + PC.KELVIN_OFFSET) + float(s.get("latent_fusion_j_kg", 0.0))
	if not is_finite(boil) or t_c <= boil:
		return h + c_liq * (t_c - melt)
	h += c_liq * (boil - melt) + float(s.get("latent_vaporisation_j_kg", 0.0))
	return h + c_gas * (t_c - boil)


## THE INVERSE, AND THE POINT OF THE WHOLE FILE: given how much energy a kilogram of a substance holds, what
## temperature is it and what phase is it in? Returns {"t_c", "phase", "melted", "vaporised"} — the last two
## being the FRACTION through each transition, which is how a cell can be half-melted and sit exactly at its
## melting point while it absorbs the rest.
##
## Nothing here charges a latent heat, and nothing can forget to: the flat sections of the curve are where the
## energy goes, so ice at 0 C and water at 0 C differ by the latent heat BY CONSTRUCTION. A kernel that adds
## heat to a freezing cell warms it more slowly for free, and one that removes heat cannot skip past the
## phase boundary, because there is no boundary to skip — only a stretch of the curve where temperature stops
## responding.
static func enthalpy_to_state(id: String, h_j_kg: float) -> Dictionary:
	var s: Dictionary = table().get(id, {})
	var c_sol: float = float(s.get("specific_heat_solid", s.get("specific_heat", 0.0)))
	var c_liq: float = float(s.get("specific_heat", 0.0))
	var c_gas: float = float(s.get("specific_heat_gas", c_liq))
	var melt: float = float(s.get("melt_c", INF))
	var boil: float = float(s.get("boil_c", INF))
	var l_fus: float = float(s.get("latent_fusion_j_kg", 0.0))
	var l_vap: float = float(s.get("latent_vaporisation_j_kg", 0.0))

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
