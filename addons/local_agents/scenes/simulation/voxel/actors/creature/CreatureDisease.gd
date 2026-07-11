class_name LACreatureDisease
extends RefCounted

## LACreatureDisease — the per-creature HEALTH / DISEASE / IMMUNE state, owned as an instance on each creature
## (`creature.disease`) so all of it lives HERE, off the Creature monolith. This is the SEAM the disease fan-out
## builds on: transmission modules call infect(); the creature's tick delegates to tick(); the immune system,
## strain progression, and symptoms all live in this module (and its sibling strain-registry / transmission /
## vector modules), never in Creature.gd. Creature.gd only holds `var disease` + one setup + one tick call.
##
## Config-over-cases (project rule): a disease is a DATA record (a strain in the registry — transmissibility,
## virulence, incubation, mortality, vector, immunity-conferred), never an `if strain == "X"` branch. An animal
## carries a set of active infections (strain_id → load) and a set of acquired immunities (strain_id → level);
## progression, the immune fight, symptom expression, recovery, and immunity all read those records generically.
##
## SKELETON: the interface + state are defined so Creature compiles and runs with ZERO behaviour change (no
## strains exist yet, nothing infects, tick is a no-op). The disease fan-out fleshes out the bodies below.
## Explicit types only (project rule: no ':=').

# Active infections: strain_id (String) → load (float 0..1, pathogen burden). Empty = healthy.
var loads: Dictionary = {}
# Acquired immunity: strain_id (String) → level (float 0..1). Survivors carry immunity that wanes slowly.
var immunity: Dictionary = {}
# Innate constitution (from the creature's genes/config): higher = fights infection off faster. Set in setup.
var constitution: float = 1.0


## Initialise from the creature's species config / genome (innate immune constitution, any starting immunities).
## Called once from LACreature.setup after the config/genome is expressed.
func setup(_creature, _config: Dictionary) -> void:
	constitution = maxf(0.1, float(_config.get("constitution", 1.0)))


## Advance disease this frame: incubate + progress each active infection, let the immune system fight it (scaled
## by constitution + acquired immunity), express symptoms (energy drain / slowed movement — written onto the
## creature), recover (clearing a strain grants immunity) or DIE. Returns true if the creature died of disease
## (the caller then returns, like the metabolism death gate). No-op until the disease fan-out fills it in.
func tick(_creature, _delta: float) -> bool:
	return false


## External infection hook: expose the creature to `dose` of `strain_id` (a transmission module — contact,
## proximity, a pest vector, a pathogen field cell — calls this). Acquired immunity blunts the dose; a fully
## immune animal shrugs it off. No-op skeleton.
func infect(_strain_id: String, _dose: float) -> void:
	pass


## Is this creature carrying any active infection (past incubation)? Read by transmission (only the sick shed).
func is_infected() -> bool:
	return not loads.is_empty()


## How infectious this creature is right now (0 = not shedding, 1 = peak) — the amount a transmission module
## multiplies into the dose it gives contacts. Sum/'max' over active strains once progression exists.
func infectiousness() -> float:
	return 0.0


## Symptom severity 0..1 — the aggregate "how sick" used by the creature for emergent behaviour (lethargy,
## staying put, being easier prey) and by the HUD/streamer. 0 until symptoms are implemented.
func severity() -> float:
	return 0.0
