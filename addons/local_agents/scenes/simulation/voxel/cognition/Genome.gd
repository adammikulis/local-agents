class_name LAGenome
extends RefCounted

## DEPRECATED thin shim — the heritable genome is now a literal DNA sequence, LADNA (see cognition/DNA.gd).
## Every live call site (Creature.setup, EcologyBreeding, WorldSaveState) builds LADNA directly. This shim
## exists only so any stray or dynamically-dispatched `LAGenome.*` call still resolves: its factories forward
## to LADNA and return LADNA instances. All stochastic draws route through the shared seeded LASimRng (never a
## bare randf()), matching the new deterministic-heredity rule. Remove once no reference to LAGenome remains.
## (Explicit types only — project rule: no ':=' inferred typing.)


static func from_config(cfg: Dictionary) -> LADNA:
	return LADNA.from_config(cfg)


static func from_parent(a) -> LADNA:
	return LADNA.from_parent(a)


static func crossover(a, b) -> LADNA:
	return LADNA.crossover(a, b, LASimRng.shared())
