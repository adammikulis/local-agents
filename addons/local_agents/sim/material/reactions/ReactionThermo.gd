class_name LAReactionThermo
extends RefCounted

## Reaction DIRECTION from Gibbs free energy. dG = dH - T dS + R T ln Q, with dH and dS derived from the
## substance table over the record's own stoichiometry. A record's rate model stays the KINETICS; this is
## only which way it runs, and how close to equilibrium it is.

const PC = preload("res://addons/local_agents/sim/material/PhysicalConstants.gd")
const BalanceScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionBalance.gd")


## Standard dH (J per mole of `q_slot`'s substance) and dS (J/mol/K) for `rec`, plus the partial pressure one
## channel unit of `q_slot` exerts per kelvin. Empty when a participant has no standard-state data.
static func equilibrium_terms(rec: Dictionary, q_slot: int) -> Dictionary:
	var tbl: Dictionary = LASubstances.table()
	var subs: Dictionary = BalanceScript.slot_substance()
	var dh: float = 0.0
	var ds: float = 0.0
	var q_mol: float = 0.0
	for side in ["reactants", "products"]:
		var sgn: float = -1.0 if side == "reactants" else 1.0
		for entry in rec.get(side, []):
			var slot: int = int(entry[0])
			var s: Dictionary = tbl.get(String(subs.get(slot, "")), {})
			var entropy: float = float(s.get("entropy_j_molk", s.get("entropy_gas_j_molk", 0.0)))
			if not s.has("formation_enthalpy_j_mol") or entropy <= 0.0:
				return {}
			var moles: float = float(entry[1])
			dh += sgn * moles * float(s["formation_enthalpy_j_mol"])
			ds += sgn * moles * entropy
			if slot == q_slot:
				q_mol += sgn * moles
	if absf(q_mol) <= 0.0:
		return {}
	var q_sub: Dictionary = tbl.get(String(subs.get(q_slot, "")), {})
	var molar_mass: float = float(q_sub.get("molar_mass", 0.0))
	var density: float = float(q_sub.get("density", 0.0))
	if molar_mass <= 0.0 or density <= 0.0:
		return {}
	return {
		"dg_h_j_mol": dh / absf(q_mol),
		"dg_s_j_molk": ds / absf(q_mol),
		"q_slot": q_slot,
		"q_pa_per_unit_k": (density / molar_mass) * PC.GAS_CONSTANT_J_MOL_K,
		# Heat per unit of extent, positive exothermic — the same dH, undivided. An extent is moles, so
		# this is already J per m3 of cell.
		"enthalpy_j_m3": -dh,
	}


## `rec` with its direction taken from thermodynamics instead of a threshold: the kernel scales the kinetic
## extent by 1 - exp(dG/RT) and runs the record BACKWARDS where that is negative. `q_slot` names the one
## participant whose activity varies — a gas; every condensed participant is a pure phase at unit activity.
static func reversible(rec: Dictionary, q_slot: int) -> Dictionary:
	var terms: Dictionary = equilibrium_terms(rec, q_slot)
	if terms.is_empty():
		push_error("LAReactionThermo: a participant of this record has no formation enthalpy or standard "
			+ "entropy in LASubstances, so its direction cannot be derived. Add the datum with its source, "
			+ "or leave the record one-way.")
		return rec
	var declared: float = float(rec.get("enthalpy_j_m3", 0.0))
	if declared != 0.0 and absf(declared - float(terms["enthalpy_j_m3"])) > absf(declared) * 1.0e-6:
		push_error("LAReactionThermo: this record declares %s J/m3 of reaction heat while its own formation "
			% String.num(declared, 4) + "enthalpies give %s. Two authorities on one reaction's heat is how "
			% String.num(float(terms["enthalpy_j_m3"]), 4) + "Hess's law gets broken; delete the hand-written "
			+ "one.")
		return rec
	var out: Dictionary = rec.duplicate(true)
	out.merge(terms, true)
	return out


## Activity of `q_slot` at which dG = 0, i.e. the equilibrium the record relaxes to. The CPU counterpart of
## the kernel's equilibrium bound; tests read it, the kernel recomputes it per cell.
static func equilibrium_activity(terms: Dictionary, sigma: float, t_k: float) -> float:
	var rt: float = PC.GAS_CONSTANT_J_MOL_K * maxf(t_k, 1.0)
	return exp(sigma * (maxf(t_k, 1.0) * float(terms["dg_s_j_molk"]) - float(terms["dg_h_j_mol"])) / rt)


## exp() argument bound. The kernel's copy is generated from this constant.
const EXP_LIMIT: float = 60.0


## +1 when `q_slot` is a product of `rec`, -1 when it is a reactant, 0 when it is neither. The kernel reads
## the same two lists to get the same answer.
static func quotient_sign(rec: Dictionary) -> float:
	var q_slot: int = int(rec.get("q_slot", -1))
	for entry in rec.get("reactants", []):
		if int(entry[0]) == q_slot:
			return -1.0
	for entry in rec.get("products", []):
		if int(entry[0]) == q_slot:
			return 1.0
	return 0.0


## Activity of `q_slot` — its partial pressure over the standard pressure — at a channel amount and a
## temperature. Ideal gas: p = (rho/M) * ch * R * T.
static func activity_of(terms: Dictionary, channel_amount: float, t_k: float) -> float:
	return float(terms["q_pa_per_unit_k"]) * channel_amount * maxf(t_k, 1.0) / PC.STANDARD_PRESSURE_PA


## The signed scale the kernel applies to the kinetic extent: 1 - exp(dG/RT). Positive runs the record
## forward, negative runs it backwards, zero is equilibrium.
static func direction_factor(terms: Dictionary, sigma: float, t_k: float, activity: float) -> float:
	var rt: float = PC.GAS_CONSTANT_J_MOL_K * maxf(t_k, 1.0)
	var dg: float = float(terms["dg_h_j_mol"]) - maxf(t_k, 1.0) * float(terms["dg_s_j_molk"]) \
		+ sigma * rt * log(maxf(activity, 1.0e-30))
	return 1.0 - exp(clampf(dg / rt, -EXP_LIMIT, EXP_LIMIT))


## Temperature at which dG = 0 for a given activity of `q_slot`. This is what a threshold constant used to
## assert; it is a function of composition, which is why one number could never be right.
static func equilibrium_temperature_k(terms: Dictionary, sigma: float, activity: float) -> float:
	var denom: float = float(terms["dg_s_j_molk"]) \
		- sigma * PC.GAS_CONSTANT_J_MOL_K * log(maxf(activity, 1.0e-30))
	if absf(denom) <= 0.0:
		return INF
	return float(terms["dg_h_j_mol"]) / denom
