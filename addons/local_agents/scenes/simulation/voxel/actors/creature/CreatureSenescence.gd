class_name LACreatureSenescence
extends RefCounted

## LACreatureSenescence — the per-creature AGEING / SENESCENCE state, owned as an instance on each creature
## (`creature.senescence`) so all of it lives HERE, off the Creature monolith. The creature's _physics_process
## delegates to tick() once per frame (right after the life-stage age advance); Creature.gd only holds
## `var senescence` + one setup + one tick call, mirroring the `disease` seam.
##
## Emergent, curve-driven — NO scripted deaths, NO `if age == X` cases. From the one age-vs-max_age axis this
## module computes a single 0..1 SENESCENCE FACTOR: flat 0 through youth and prime (the middle of life is the
## peak), then rising with an accelerating curve toward max_age. Every age-graded trait is DERIVED from that one
## factor:
##   • speed_mult      — an old animal visibly SLOWS (worn muscle), so it forages/flees/hunts less well.
##   • max_energy_mult — its organ RESERVE shrinks (declining resilience → less buffer against starvation/stress).
##   • fertility_mult  — it becomes LESS FERTILE, tapering to sterile well before death (read by reproduction).
## The old-age MORTALITY itself is driven by this curve in LACreatureMetabolism (frailty drains health as the
## factor rises, with a hard backstop at max_age). Together these give life real stages — juvenile → prime →
## old — so populations turn over with generational structure instead of everyone dying identically at a cliff.
##
## The youthful BASELINES (speed, max_energy) are captured once at setup so tick() can rewrite the live traits
## from them every frame WITHOUT compounding (idempotent). Prime creatures get multiplier 1.0, so day-0 land
## behaviour is unchanged until an individual actually ages past its prime. Compresses with LA_EVO_FAST exactly
## like metabolism/reproduction, so the effective lifespan the curve measures against matches the death schedule.
## (Explicit types only — project rule: no ':=' inferred typing.)

# --- curve shape (exposed as named consts for retuning) --------------------------------------------------
const PRIME_END: float = 0.5        # fraction of (effective) lifespan spent at peak before senescence begins to rise
const SPEED_DECLINE: float = 0.45   # an animal at max_age moves at (1 - this) of its youthful speed
const ENERGY_DECLINE: float = 0.35  # its max_energy reserve at max_age falls to (1 - this) of youthful

# Youthful baselines, captured at setup so the age-graded traits are rewritten from a fixed reference each
# frame (no compounding drift). An offspring/evolved creature captures ITS OWN config-expressed values here.
var base_speed: float = 0.0
var base_max_energy: float = 0.0


## Capture the creature's youthful trait baselines. Called from setup() after all config/genome expression, so
## base_speed / base_max_energy reflect this individual's (possibly evolved) genes.
func setup(c) -> void:
	base_speed = c.speed
	base_max_energy = c.max_energy


## The 0..1 senescence factor: 0 through youth and prime (age below PRIME_END of the effective lifespan), then
## rising with an accelerating (squared) curve to 1.0 exactly at max_age. Measured against the SAME evo-compressed
## lifespan the metabolism death gate uses, so the curve and the mortality backstop line up.
func factor(c) -> float:
	var evo: float = LAAblate.evo_fast()
	var life: float = maxf(c.max_age / evo, 0.001)
	var f: float = clampf(c.age / life, 0.0, 1.0)
	if f <= PRIME_END:
		return 0.0
	var t: float = (f - PRIME_END) / maxf(1.0 - PRIME_END, 0.001)
	return clampf(t * t, 0.0, 1.0)


## Speed multiplier (1.0 in prime, falling to 1 - SPEED_DECLINE at max_age) — applied to the live `speed` field.
func speed_mult(c) -> float:
	return 1.0 - SPEED_DECLINE * factor(c)


## Max-energy (resilience/reserve) multiplier (1.0 in prime, falling to 1 - ENERGY_DECLINE at max_age).
func max_energy_mult(c) -> float:
	return 1.0 - ENERGY_DECLINE * factor(c)


## Fertility multiplier (1.0 in prime, falling FASTER than linear — squared — so a creature is effectively
## sterile well before it dies). Read by LACreatureReproduction to taper then cut off breeding with age.
func fertility_mult(c) -> float:
	var s: float = factor(c)
	var r: float = 1.0 - s
	return clampf(r * r, 0.0, 1.0)


## Per-frame ageing tick: rewrite the age-graded traits (speed, max-energy reserve) from the youthful baselines
## via the current multipliers. Idempotent — recomputed from a fixed reference each frame, so no compounding.
## A prime creature gets multiplier 1.0 (traits unchanged); only aged creatures slow and lose reserve. Called
## after LACreatureLifeStage.tick (which advances age) and BEFORE the metabolism/reproduction ticks that read
## the updated traits. `delta` is unused today (traits are a pure function of age) but kept for symmetry + future
## rate-based frailty.
func tick(c, _delta: float) -> void:
	c.speed = base_speed * speed_mult(c)
	var new_max: float = base_max_energy * max_energy_mult(c)
	c.max_energy = new_max
	# A shrinking reserve caps a full old animal's energy down to its new ceiling (declining resilience).
	if c.energy > new_max:
		c.energy = new_max
