class_name LACreatureLifeStage
extends RefCounted

## Life stage + ageing for LACreature, factored out of the main brain. Today this is minimal: age
## advances every frame, and maturity is a single threshold (age >= maturity_age) gating breeding,
## leadership eligibility, and the adult/juvenile inspector label. Death by old age lives in
## LACreatureMetabolism (the survival tick that owns starve/thirst/age mortality).
##
## Growth-by-age lives here (Phase 2, light): a newborn is BORN small (NEWBORN_SCALE of adult size) and grows
## linearly to full size as it matures, so a creature visibly develops from birth to adult. It is NOT yet
## fertile as a juvenile — that gate is is_mature (age >= maturity_age), which LACreatureReproduction reads —
## so the size curve and the fertility threshold share the one `maturity_age` axis. Creature keeps only the
## raw `age`/`maturity_age`/`max_age` state plus a cached `_growth` scale, and forwards to these functions, so
## life-stage behaviour is owned here without touching Creature.gd's brain.
##
## Static + dependency-free of the LACreature type (dynamic field access, like the other Creature* helpers).
## (Explicit types only — project rule: no ':=' inferred typing.)

# --- growth curve (exposed as named consts for retuning) -------------------------------------------------
const NEWBORN_SCALE: float = 0.45         # a newborn's visual size as a fraction of the adult (grows up from here)
const GROW_TIME_FRAC: float = 1.0         # reaches full adult size at age = maturity_age * this (adult by maturity)


## Advance the creature's age by `delta`, then update its growth scale. Called once per physics frame on the
## alive path (LOD-strided delta, so distant creatures still age + grow at the correct accumulated rate).
static func tick(c, delta: float) -> void:
	c.age += delta
	_apply_growth(c)


## True once the creature has reached breeding/adult maturity — the "is it an adult" query the rest of the sim
## (reproduction fertility, leadership eligibility, the inspector label) reads.
static func is_mature(c) -> bool:
	return c.age >= c.maturity_age


## Visual size as a fraction of the adult body: NEWBORN_SCALE at birth, rising linearly to 1.0 by the end of
## the juvenile grow-time (maturity_age * GROW_TIME_FRAC). Founders spawned aged-in are already full size.
static func growth_scale(c) -> float:
	var grow_time: float = maxf(c.maturity_age * GROW_TIME_FRAC, 0.001)
	return lerpf(NEWBORN_SCALE, 1.0, clampf(c.age / grow_time, 0.0, 1.0))


## Apply the age-driven growth scale to the creature's visual (the display model if it has one, else the
## capsule mesh). Early-outs once the cached scale has settled — an adult pays nothing, a juvenile only
## repaints its transform as it grows.
static func _apply_growth(c) -> void:
	var s: float = growth_scale(c)
	if is_equal_approx(c._growth, s):
		return
	c._growth = s
	var vis = c._model_root if c._model_root != null else c._mesh
	if vis != null and is_instance_valid(vis):
		vis.scale = Vector3(s, s, s)
