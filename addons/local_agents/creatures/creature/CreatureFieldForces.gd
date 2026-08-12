class_name LACreatureFieldForces
extends RefCounted


const WIND_COUPLING: float = 1.0
# Below this squared force magnitude the push is treated as nil (skip the work — and today's zero wind
# makes this the always-taken early-out, guaranteeing an exact no-op until real forces arrive).
const FORCE_EPSILON_SQ: float = 0.0001


const WATER_REF_SIZE: float = 0.5
const WATER_COUPLING: float = 1.0
const WATER_MIN_FORCE_SQ: float = 0.04
const SWEEP_STRIDE: int = 8          # recompute the raycast-heavy water current only every N frames (cached between)


static func tick(c, delta: float) -> void:
	if c._material == null or delta <= 0.0:
		return
	var p: Vector3 = c.global_position
	if c._material.has_method("wind3_at"):
		apply(c, c._material.wind3_at(p.x, p.y, p.z), delta)
	if c._material.has_method("is_water_at") and c._material.is_water_at(p):
		if c._material.has_method("water_force_at") and LALodStride.should_run(int(Engine.get_physics_frames()), c._think_phase, SWEEP_STRIDE):
			c._water_force = c._material.water_force_at(p)
		if c._water_force.length_squared() >= WATER_MIN_FORCE_SQ:
			var weight: float = maxf(float(c.size), 0.1)
			c.global_position = c.global_position + c._water_force * (WATER_COUPLING * (WATER_REF_SIZE / weight) * delta)
	else:
		c._water_force = Vector3.ZERO


static func apply(c, force: Vector3, delta: float) -> void:
	if delta <= 0.0 or force.length_squared() < FORCE_EPSILON_SQ:
		return
	# Continuous advection: nudge the body along the field force; the creature's own movement step
	# re-seats it onto the surface radially each frame, so a downwind drift stays hugging the ground.
	c.global_position = c.global_position + force * (WIND_COUPLING * delta)
