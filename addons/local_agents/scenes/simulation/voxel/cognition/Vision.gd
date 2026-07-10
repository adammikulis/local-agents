class_name LAVision
extends RefCounted

## Realistic-ish sight: a creature only perceives things inside its field-of-view cone and within
## eye range. The cone is driven by heritable "eye" genes, so perception itself evolves and differs
## by body plan — no vision-language model needed, just geometry:
##
##   * Prey (rabbit, bird) have side-set eyes → a very wide, nearly panoramic FOV (small rear blind
##     spot) but see the world flatly. They notice threats from almost any angle.
##   * Predators (fox, villager) have forward-set eyes → a narrow cone they must aim at prey, in
##     exchange for the longer effective range that binocular focus buys.
##
## This gates ALL perception — who a creature can hunt, flee, or learn from — so ambush from a blind
## spot, a hunter that must face its target, and "you only copy herd-mates you can actually see" all
## fall out of the same rule (emergent, not scripted per species).
##
## BINOCULAR ADVANTAGE: a narrow forward cone means the eyes' fields overlap → depth perception →
## the animal sees FARTHER (it can pick out and range a target). A wide panoramic cone sees in every
## direction but shallowly. So the single `eye_fov` gene trades range for coverage, and forward-eyed
## predators get the reach to spot and judge prey that side-eyed prey lack. Purely emergent from one
## number, no predator/prey special-casing.
##
## Reads `c.eye_fov` (degrees, full cone width), `c.sense_radius`, `c._sense_mult`, `c._heading`.
## (Explicit types only — project rule: no ':=' inferred typing.)

# Narrowest cone we reward with full binocular reach, and the widest cone that keeps any bonus.
const BINOCULAR_FOV: float = 90.0        # <= this: maximum depth-perception range bonus
const PANORAMIC_FOV: float = 300.0       # >= this: shallowest (panoramic) range
const BINOCULAR_RANGE_MULT: float = 1.6  # reach multiplier for a fully-binocular hunter
const PANORAMIC_RANGE_MULT: float = 0.85 # reach multiplier for fully-panoramic prey


## How much the eye configuration scales view distance. Narrow forward eyes (low fov) → >1 (they see
## farther via depth perception); wide side eyes (high fov) → <1 (broad but shallow).
static func binocular_range_factor(fov: float) -> float:
	var t: float = clampf((fov - BINOCULAR_FOV) / (PANORAMIC_FOV - BINOCULAR_FOV), 0.0, 1.0)
	return lerpf(BINOCULAR_RANGE_MULT, PANORAMIC_RANGE_MULT, t)


## The creature's actual sight distance this frame (base sense × night mult × binocular factor).
static func effective_range(c) -> float:
	return c.sense_radius * c._sense_mult * binocular_range_factor(c.eye_fov)


## Can creature `c` currently see the point `target_pos`?
static func can_see(c, target_pos: Vector3) -> bool:
	var to: Vector3 = target_pos - c.global_position
	to.y = 0.0
	var dist: float = to.length()
	if dist < 0.0001:
		return true                                   # on top of it — sensed by contact
	var view_range: float = effective_range(c)
	if dist > view_range:
		return false
	var fwd: Vector3 = c._heading
	fwd.y = 0.0
	if fwd.length() < 0.0001:
		return true                                   # not yet oriented: treat as omnidirectional
	var half_fov: float = deg_to_rad(clampf(c.eye_fov, 1.0, 360.0) * 0.5)
	# A cone half-angle at/above 180° means full-circle vision — skip the dot check.
	if half_fov >= PI:
		return true
	var cos_to: float = fwd.normalized().dot(to / dist)
	return cos_to >= cos(half_fov)


## Convenience: is the Node3D `target` visible to `c`? (validity-checked)
static func sees_node(c, target) -> bool:
	if target == null or not is_instance_valid(target) or not (target is Node3D):
		return false
	return can_see(c, (target as Node3D).global_position)
