class_name LAReactionThermo
extends RefCounted

## Reaction direction from dG = dH - T dS + R T ln Q, over a record's own stoichiometry.

const BalanceScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionBalance.gd")


## Standard dH (J per mole of `q_slot`'s substance) and dS (J/mol/K) for `rec`. Empty when a participant
## has no standard-state data. A channel amount is moles, so Q needs no per-record unit bridge.
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
	return {
		"dg_h_j_mol": dh / absf(q_mol),
		"dg_s_j_molk": ds / absf(q_mol),
		"q_slot": q_slot,
		# Heat per mole of extent, positive exothermic.
		"enthalpy_j_mol": -dh,
	}


## `rec` with equilibrium terms merged in; `q_slot` names the one participant whose activity varies.
static func reversible(rec: Dictionary, q_slot: int) -> Dictionary:
	var terms: Dictionary = equilibrium_terms(rec, q_slot)
	if terms.is_empty():
		push_error("LAReactionThermo: a participant has no formation enthalpy or standard entropy in "
			+ "LASubstances. Add the datum with its source, or leave the record one-way.")
		return rec
	var declared: float = float(rec.get("enthalpy_j_mol", 0.0))
	if declared != 0.0 and absf(declared - float(terms["enthalpy_j_mol"])) > absf(declared) * 1.0e-6:
		push_error("LAReactionThermo: the record declares %s J/mol of reaction heat; its own formation "
			% String.num(declared, 4) + "enthalpies give %s. Two authorities on one reaction's heat break "
			% String.num(float(terms["enthalpy_j_mol"]), 4) + "Hess's law; delete the hand-written one.")
		return rec
	var out: Dictionary = rec.duplicate(true)
	out.merge(terms, true)
	return out


## exp() argument bound: half the float32 exponent range, so a product of two bounded terms is finite.
## The kernel's copy is generated from this constant.
const EXP_LIMIT: float = 64.0 * log(2.0)
