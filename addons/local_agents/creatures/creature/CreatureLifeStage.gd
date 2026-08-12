class_name LACreatureLifeStage
extends RefCounted


const NEWBORN_SCALE: float = 0.45         # a newborn's visual size as a fraction of the adult (grows up from here)
const GROW_TIME_FRAC: float = 1.0         # reaches full adult size at age = maturity_age * this (adult by maturity)


static func tick(c, delta: float) -> void:
	c.age += delta
	_apply_growth(c)


## True once the creature has reached breeding/adult maturity — the "is it an adult" query the rest of the sim
## (reproduction fertility, leadership eligibility, the inspector label) reads.
static func is_mature(c) -> bool:
	return c.age >= c.maturity_age / LAAblate.evo_fast()


# Senescence factor at/above which a mature creature is labelled "old" (visibly slowing + declining fertility).
const OLD_STAGE_ONSET: float = 0.35


static func stage(c) -> String:
	if not is_mature(c):
		return "juvenile"
	var sen: float = 0.0
	if c.get("senescence") != null:
		sen = c.senescence.factor(c)
	return "old" if sen >= OLD_STAGE_ONSET else "prime"


static func growth_scale(c) -> float:
	var grow_time: float = maxf(c.maturity_age * GROW_TIME_FRAC / LAAblate.evo_fast(), 0.001)
	return lerpf(NEWBORN_SCALE, 1.0, clampf(c.age / grow_time, 0.0, 1.0))


static func _apply_growth(c) -> void:
	var s: float = growth_scale(c)
	if is_equal_approx(c._growth, s):
		return
	c._growth = s
	var vis = c._model_root if c._model_root != null else c._mesh
	if vis != null and is_instance_valid(vis):
		vis.scale = Vector3(s, s, s)
