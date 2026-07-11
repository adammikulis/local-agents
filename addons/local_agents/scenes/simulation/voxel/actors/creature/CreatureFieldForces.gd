class_name LACreatureFieldForces
extends RefCounted

## The creature's FIELD-FORCE response seam.
##
## A creature is continuously ADVECTED by the substrate's local wind/momentum: a storm's gale drags
## it downwind, an updraft lifts it, a shock front shoves it. This is a CONTINUOUS push sampled from
## the field every frame — distinct from the DISCRETE throw()/fling() impulse path (a one-shot ragdoll
## launch, which stays in LACreature/LACreatureRagdoll). Both compose: a creature can be blown by the
## wind and, if the gust is violent enough, flung off its feet.
##
## The field's wind3_at() currently returns a zero vector (the CPU wind oracle is retired and the GPU
## wind read is not wired to a per-point query yet), so today this samples zero and applies nothing —
## no behaviour change. It is the pre-wired seam the substrate agent's real wind/momentum force lights
## up, and the target every storm/tornado/hurricane fling dissolution will drive (via the
## EcologyStimulus.apply_wind_force broadcast) instead of editing the creature or the ecology hub.
## Static + explicit types only (project rule: no ':=').

# How strongly a unit of field wind velocity advects a creature per second (advection coupling).
const WIND_COUPLING: float = 1.0
# Below this squared force magnitude the push is treated as nil (skip the work — and today's zero wind
# makes this the always-taken early-out, guaranteeing an exact no-op until real forces arrive).
const FORCE_EPSILON_SQ: float = 0.0001


# Sample the substrate's local 3D wind/momentum at the creature's position and advect it that way this
# frame. Called once per physics frame from LACreature._physics_process (alive path only).
# Reference body size at which the water current pushes at full strength. Weight scales with size, so a
# BIGGER (heavier) animal is dragged LESS by the same current and a smaller one MORE — mass resists the sweep.
# A cornered flood thus washes away mice and rabbits before it can budge a big-bodied grazer.
const WATER_REF_SIZE: float = 0.5
const WATER_COUPLING: float = 1.0
const WATER_MIN_FORCE_SQ: float = 0.04


static func tick(c, delta: float) -> void:
	if c._material == null or delta <= 0.0:
		return
	var p: Vector3 = c.global_position
	if c._material.has_method("wind3_at"):
		apply(c, c._material.wind3_at(p.x, p.y, p.z), delta)
	# WATER SWEEP: moving water drags a creature standing in it downstream. Gate on the cheap is_water_at first
	# (dry creatures pay nothing), then sample the current and shove the body along it, mass-scaled by size —
	# heavier animals resist. A flyer cruising above the surface reads no water at its airborne position, so it
	# is naturally never swept until it lands in the flow. Drowning in the deep still emerges separately.
	if c._material.has_method("water_force_at") and c._material.has_method("is_water_at") and c._material.is_water_at(p):
		var wf: Vector3 = c._material.water_force_at(p)
		if wf.length_squared() >= WATER_MIN_FORCE_SQ:
			var weight: float = maxf(float(c.size), 0.1)
			c.global_position = c.global_position + wf * (WATER_COUPLING * (WATER_REF_SIZE / weight) * delta)


# Apply a field force `force` (a velocity-like push, world units/sec) to the creature over `delta`,
# advecting its position. Also the INSTANCE HOOK the EcologyStimulus.apply_wind_force area broadcast
# drives per affected creature, so a storm can push every creature in its footprint through one call.
# A zero/near-zero force is a no-op — so this is inert until the field supplies a real wind.
static func apply(c, force: Vector3, delta: float) -> void:
	if delta <= 0.0 or force.length_squared() < FORCE_EPSILON_SQ:
		return
	# Continuous advection: nudge the body along the field force; the creature's own movement step
	# re-seats it onto the surface radially each frame, so a downwind drift stays hugging the ground.
	c.global_position = c.global_position + force * (WIND_COUPLING * delta)
