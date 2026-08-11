class_name LACreatureExcretion
extends RefCounted

## Digestion + marking waste for LocalAgentCreature, factored out of the hot _physics_process. A fed creature
## periodically drops feces (soil fertility + a food/musk cue predators track prey by) and, more often,
## urine (territorial musk). Faeces is organic matter and goes into the detritus channel to rot, via
## c._material. No node is spawned; the deposit is a few cells that diffuse + wash away. Feces enrich
## the soil so plants regrow on dung (emergent nutrient cycle), so a well-fed animal fertilises its range.
##
## Static + dependency-free of the LocalAgentCreature type (dynamic field access, like the other Creature* helpers).
## The cooldown timers (_poop_cd/_urine_cd) stay on the creature; only the tick logic lives here.
## (Explicit types only, no ':=' inferred typing.)


## Minimum pending digested residue before a feces deposit is worth making, as a FRACTION OF GUT CAPACITY —
## an animal that has not digested anything has nothing to pass. A threshold on a per-animal quantity has to
## scale with the animal: an absolute one exceeds a small animal's whole gut and closes its death→soil leg.
const FECES_MIN_GUT_FRAC: float = 0.02

## Detritus deposited into the field's soil-nutrient loop per unit of feces mass (same 1:1 conserving-transfer
## convention CreatureRagdoll.DETRITUS_YIELD uses for carcasses) — R15 fungus-decompose then rots it into
## fertility, and R19 photosynthesis now actually consumes that fertility to grow (the loop this closes).
const FECES_DETRITUS_YIELD: float = 1.0


## Per-frame excretion tick, called from LocalAgentCreature._physics_process with the ground point below the body.
## Counts down the two cooldowns and deposits when each elapses. Feces is the OUTPUT of digestion: it deposits
## only the residue LACreatureDigestion has banked in c.gut_waste, and clears it on deposit — digestion feeds
## this level rather than depositing itself, so the waste is counted exactly once. Urine is unrelated
## territorial musk on its own cadence.
static func tick(c, ground_pos: Vector3, delta: float) -> void:
	c._poop_cd -= delta
	if c._poop_cd <= 0.0:
		c._poop_cd = randf_range(24.0, 48.0)
		if c.gut_waste >= maxf(float(c.gut_capacity), 0.0) * FECES_MIN_GUT_FRAC:
			deposit(c, ground_pos, "feces", c.gut_waste)
			c.gut_waste = 0.0                     # expelled — the pending digested residue is passed (no double count)
	c._urine_cd -= delta
	if c._urine_cd <= 0.0:
		c._urine_cd = randf_range(10.0, 22.0)
		deposit(c, ground_pos, "urine", 0.0)


## Deposit waste at `ground_pos`. Faeces is organic matter, so it goes into the detritus channel and decays
## through the field's own chemistry (detritus + O₂ + fungus -> CO₂ + moisture + fertility); the CO₂ that comes
## off is what another animal can smell. There is no separate cue: the deposit IS the smell, once it rots.
##
## The parallel deposit_waste() call that used to sit here is deleted. It seeded a semantic scent plane beside
## this line, so the same dropping was registered twice in two unrelated representations.
static func deposit(c, ground_pos: Vector3, kind: String, waste_amount: float) -> void:
	if c._material == null:
		return
	if kind == "feces" and waste_amount > 0.0 and c._material.has_method("deposit_detritus"):
		c._material.deposit_detritus(ground_pos, waste_amount * FECES_DETRITUS_YIELD)
