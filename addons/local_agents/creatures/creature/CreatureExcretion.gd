class_name LACreatureExcretion
extends RefCounted

## Digestion + marking waste for LACreature, factored out of the hot _physics_process. A fed creature
## periodically drops feces (soil fertility + a food/musk cue predators track prey by) and, more often,
## urine (territorial musk). Both deposit into the shared scent/fertility field (LAMaterialScent3D) via
## c._material — no node is spawned; the deposit is a few cells that diffuse + wash away. Feces enrich
## the soil so plants regrow on dung (emergent nutrient cycle), so a well-fed animal fertilises its range.
##
## Static + dependency-free of the LACreature type (dynamic field access, like the other Creature* helpers).
## The cooldown timers (_poop_cd/_urine_cd) stay on the creature; only the tick logic lives here.
## (Explicit types only — project rule: no ':=' inferred typing.)


## Minimum pending digested residue (LACreatureDigestion.gut_waste) before a feces deposit is worth making —
## an animal that has not digested anything has nothing to pass.
const FECES_MIN_WASTE: float = 0.5


## Per-frame excretion tick, called from LACreature._physics_process with the ground point below the body.
## Counts down the two cooldowns and deposits when each elapses. Feces is the OUTPUT of digestion: it deposits
## only the residue LACreatureDigestion has banked in c.gut_waste, and clears it on deposit — digestion feeds
## this level rather than depositing itself, so the waste is counted exactly once. Urine is unrelated
## territorial musk on its own cadence.
static func tick(c, ground_pos: Vector3, delta: float) -> void:
	c._poop_cd -= delta
	if c._poop_cd <= 0.0:
		c._poop_cd = randf_range(24.0, 48.0)
		if c.gut_waste >= FECES_MIN_WASTE:
			deposit(c, ground_pos, "feces")
			c.gut_waste = 0.0                     # expelled — the pending digested residue is passed (no double count)
	c._urine_cd -= delta
	if c._urine_cd <= 0.0:
		c._urine_cd = randf_range(10.0, 22.0)
		deposit(c, ground_pos, "urine")


## Deposit waste at `ground_pos` into the shared scent/fertility field. Feces enriches the soil (plants
## regrow on dung — emergent) and carries a food + musk cue predators track prey by; urine is territorial
## musk. No node is spawned — the deposit is a few cells in LAMaterialScent3D that diffuse and wash away.
static func deposit(c, ground_pos: Vector3, kind: String) -> void:
	if c._material != null and c._material.has_method("deposit_waste"):
		c._material.deposit_waste(ground_pos, c, kind)
