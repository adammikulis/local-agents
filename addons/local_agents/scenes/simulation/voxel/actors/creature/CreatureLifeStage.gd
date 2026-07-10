class_name LACreatureLifeStage
extends RefCounted

## Life stage + ageing for LACreature, factored out of the main brain. Today this is minimal: age
## advances every frame, and maturity is a single threshold (age >= maturity_age) gating breeding,
## leadership eligibility, and the adult/juvenile inspector label. Death by old age lives in
## LACreatureMetabolism (the survival tick that owns starve/thirst/age mortality).
##
## Phase 2 lands graded life stages here — infant / juvenile / adult / senescent — plus growth-by-age
## (body size, speed, sense, and food value scaling with development along the age axis) so a creature
## visibly grows from birth and slows in senescence. That will live entirely in this module: Creature
## keeps only the raw `age`/`maturity_age`/`max_age` state and forwards to these functions, so a Phase 2
## agent owns life-stage behaviour without touching Creature.gd. Do not build the graded stages now.
##
## Static + dependency-free of the LACreature type (dynamic field access, like the other Creature* helpers).
## (Explicit types only — project rule: no ':=' inferred typing.)


## Advance the creature's age by `delta`. Called once per physics frame on the alive path.
static func tick(c, delta: float) -> void:
	c.age += delta


## True once the creature has reached breeding/adult maturity. One threshold today; Phase 2 replaces the
## boolean with graded stages (this stays the "is it an adult" query the rest of the sim reads).
static func is_mature(c) -> bool:
	return c.age >= c.maturity_age
