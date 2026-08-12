class_name LACreatureSenescence
extends RefCounted


const PRIME_END: float = 0.5        # fraction of (effective) lifespan spent at peak before senescence begins to rise
const SPEED_DECLINE: float = 0.45   # an animal at max_age moves at (1 - this) of its youthful speed
const ENERGY_DECLINE: float = 0.35  # its max_energy reserve at max_age falls to (1 - this) of youthful

var base_speed: float = 0.0
var base_max_energy: float = 0.0


## Capture the creature's youthful trait baselines. Called from setup() after all config/genome expression, so
## base_speed / base_max_energy reflect this individual's (possibly evolved) genes.
func setup(c) -> void:
	base_speed = c.speed
	base_max_energy = c.max_energy


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


func fertility_mult(c) -> float:
	var s: float = factor(c)
	var r: float = 1.0 - s
	return clampf(r * r, 0.0, 1.0)


func tick(c, _delta: float) -> void:
	c.speed = base_speed * speed_mult(c)
	var new_max: float = base_max_energy * max_energy_mult(c)
	c.max_energy = new_max
	# A shrinking reserve caps a full old animal's energy down to its new ceiling (declining resilience).
	if c.energy > new_max:
		c.energy = new_max
