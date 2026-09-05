class_name LAReactionThermo
extends RefCounted

## Reaction direction from dG = dH - T dS + R T ln Q, over a record's own stoichiometry.

const BalanceScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionBalance.gd")


## What the substance table says about `rec`: its heat, its net moles of gas and its standard entropy
## change, all on the record's own composition-scaled coefficients. Empty when a participant is unpriced.
static func table_terms(rec: Dictionary) -> Dictionary:
	return LASubstances.reaction_terms(rec, BalanceScript.slot_substance(), LAChannels.derived_slots())


## `rec` with its heat and its gas balance filled in from the table — the ONE authority on both.
static func priced(rec: Dictionary) -> Dictionary:
	var terms: Dictionary = table_terms(rec)
	if terms.is_empty():
		push_error("LAReactionThermo.priced: a participant has no formation enthalpy in LASubstances. "
			+ "Add the datum with its source; a reaction heat may not be hand-written beside the table.")
		return rec
	var out: Dictionary = rec.duplicate(true)
	out.merge(terms, true)
	return out


## `rec` priced, plus its equilibrium terms; `q_slot` names the one participant whose activity varies.
static func reversible(rec: Dictionary, q_slot: int) -> Dictionary:
	var out: Dictionary = priced(rec)
	var q_mol: float = 0.0
	for side in ["reactants", "products"]:
		for entry in rec.get(side, []):
			if int(entry[0]) == q_slot:
				q_mol += (-1.0 if side == "reactants" else 1.0) * float(entry[1])
	var ds: float = float(out.get("entropy_j_molk", NAN))
	if absf(q_mol) <= 0.0 or is_nan(ds):
		push_error("LAReactionThermo.reversible: a participant has no standard entropy, or q_slot is not "
			+ "one of them. Add the datum with its source, or leave the record one-way.")
		return rec
	out["dg_h_j_mol"] = -float(out["enthalpy_j_mol"]) / absf(q_mol)
	out["dg_s_j_molk"] = ds / absf(q_mol)
	out["q_slot"] = q_slot
	return out


## exp() argument bound: half the float32 exponent range, so a product of two bounded terms is finite.
## The kernel's copy is generated from this constant.
const EXP_LIMIT: float = 64.0 * log(2.0)
