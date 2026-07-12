class_name LACognizerAdapter
extends RefCounted

## Duck-typed read facade between the per-creature brain (LACognition) and whatever ACTOR is cognizing.
## LACognition talks ONLY through this adapter — it never names an LACreature field directly — so the
## brain is decoupled from any single actor implementation: LACreature today, and any other actor (e.g.
## an aquatic swimmer) that exposes the same duck-typed surface tomorrow reuses LACognition unchanged.
## Adding a new kind of cognizer = provide these properties, not patch the brain.
##
## The cognizer surface LACognition depends on (all READ-ONLY — the brain never mutates the actor here):
##   drives  : energy/max_energy, hydration/max_hydration, health/max_health
##   body    : global_position; breath_capacity + _breath (breath fraction); _panic_timer (fear);
##             _material (temp probe) — the private welfare senses, encapsulated by senses()
##   control : llm_enabled (slow-brain opt-out)
##   social  : species, family_id; the scene-tree neighbour scan + each neighbour's get_cognition()
##
## Static accessors so nothing is allocated per decision — this stays on the hot think path.
## (Explicit types only — project rule: no ':=' inferred typing.)


static func energy(c) -> float:
	return c.energy


static func max_energy(c) -> float:
	return c.max_energy


static func hydration(c) -> float:
	return c.hydration


static func max_hydration(c) -> float:
	return c.max_hydration


static func health(c) -> float:
	return c.health


static func max_health(c) -> float:
	return c.max_health


static func position(c) -> Vector3:
	return c.global_position


static func llm_enabled(c) -> bool:
	return c.llm_enabled


static func species(c) -> String:
	return String(c.species)


static func family_id(c) -> int:
	return int(c.family_id)


## Full welfare-sense snapshot for reinforcement: {health, fear, o2, temp}. Encapsulates the actor's
## PRIVATE breath/panic/material coupling so LACognition need not know the field names. `temp_fallback`
## is returned when the actor has no material field to probe (keeps the brain's last-known ambient).
## Behaviour is identical to the direct field reads it replaces.
static func senses(c, temp_fallback: float) -> Dictionary:
	var o2: float = 1.0
	if c.breath_capacity > 0.0:
		o2 = clampf(c._breath / c.breath_capacity, 0.0, 1.0)
	var temp: float = temp_fallback
	if c._material != null and c._material.has_method("temp_at"):
		temp = c._material.temp_at(c.global_position)
	return {"health": c.health, "fear": c._panic_timer, "o2": o2, "temp": temp}


## Same-species neighbours in the scene tree (the social-learning scan pool). The group-naming convention
## stays here so the brain never touches how the actor registers itself.
static func neighbours(c) -> Array:
	return c.get_tree().get_nodes_in_group("species_" + String(c.species))


## Whether cognizer `c` can currently SEE node `m` (vision-gated social learning). Wraps LAVision so the
## brain depends on the adapter, not on the actor+vision pair directly.
static func sees(c, m) -> bool:
	return LAVision.sees_node(c, m)


## The LACognition brain of neighbour `m`, or null if it has none / isn't a cognizer. Duck-typed through
## get_cognition() so any actor kind can be observed.
static func cognition_of(m):
	if m != null and m.has_method("get_cognition"):
		return m.get_cognition()
	return null


## Neighbour `m`'s family id (for relatedness). Tolerant `.get()` read so a non-creature node in the same
## group never hard-errors — matches the original observe() access exactly.
static func neighbour_family_id(m) -> int:
	return int(m.get("family_id"))
