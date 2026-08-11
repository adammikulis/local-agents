class_name LACreatureLocomotion
extends RefCounted

## The MOVEMENT half of LocalAgentCreature's physics tick, factored out of the main brain: turning toward the
## decided heading, stepping across the planet's surface, coast avoidance, the radial ground snap, and the
## gaze. Runs EVERY (LOD-strided) frame, whether or not a decision ran. The think cascade only ever sets a
## TARGET heading and speed, and this smoothly carries the body along it.
##
## Radial locomotion: `up` points away from the planet centre, so all heading math is projected onto the local
## tangent plane and the ground read/snap go radial. The decided heading is a TARGET the creature turns toward
## smoothly each frame (not snapped); acute flees snap instantly (the think block sets _heading directly on
## _force_think).
##
## Static + dynamic field access on the passed creature, like the other Creature* modules.
## (Explicit types only, no ':=' inferred typing.)

# Flyers turn GRADUALLY (max radians/sec) so flocks wheel and vultures circle wide instead of
# snapping direction every frame — the fix for frantic, too-fast circling.
const BIRD_TURN_RATE: float = 1.5
const GROUND_TURN_RATE: float = 6.0        # ground creatures turn briskly-but-smoothly toward their decided
                                           # heading each frame, so throttled decisions don't read as jerky pops
# COAST AVOIDANCE: a land walker won't step onto ground that sits more than this far below the sea shell (i.e.
# into deep, drownable water) — it stays on land instead of wandering/fleeing off a shoreline into the ocean.
# The shallow shore (for drinking) stays open; only genuinely deep water is a soft wall. Flyers are exempt.
const COAST_AVOID_DEPTH: float = 3.0


## Turn toward the decided heading, step, re-seat radially on the surface, and gaze along the heading.
## `pos` is the position the tick started from and `ground_pos` the ground point below it (both already
## computed by the caller for the physiology/decision phases).
static func move(c, pos: Vector3, ground_pos: Vector3, delta: float) -> void:
	if c._target_heading.length() > 0.01:
		var turn_rate: float = BIRD_TURN_RATE if c.can_fly else GROUND_TURN_RATE
		c._heading = turn_toward(c, c._heading, c._target_heading, turn_rate * delta)
	var step: Vector3 = c._heading * c._eff_speed * delta
	# Height held above the local ground: flyers use their DECIDED altitude (they descend to feed/drink/roost —
	# _target_altitude, default cruise_height); walkers ride at body radius.
	var offset: float = c._target_altitude if c.can_fly else c.size
	# Step in the tangent plane, then snap radially: the new ground point is along the NEW radial direction
	# from the planet centre, and we sit `offset` above it (up == that same radial dir).
	var new_pos: Vector3 = pos + step
	var nud: Vector3 = (new_pos - c.terrain.planet_center()).normalized()
	var gpt: Vector3 = c.terrain.surface_point(nud)
	if is_nan(gpt.x):
		gpt = ground_pos                      # unmeshed ahead: hold last known ground
	# COAST AVOIDANCE: a land walker won't step into deep (drownable) water — if the ground ahead is well below
	# the sea shell, hold on the current land and turn back inland, so spawned rabbits don't run off an island
	# and drown. Flyers cross water freely; the shallow shore stays reachable for drinking.
	elif not c.can_fly and c.terrain.has_method("sea_radius"):
		var sea_r: float = c.terrain.sea_radius()
		if sea_r > 0.0 and (gpt - c.terrain.planet_center()).length() < sea_r - COAST_AVOID_DEPTH:
			gpt = ground_pos
			c._heading = -c._heading             # reflect off the coast — turn back toward land
			c._target_heading = c._heading
	c.global_position = gpt + nud * offset


## Gaze along the heading projected into the local tangent plane, with the local up as roll axis.
## Split from move() so the profiler can charge the step and the look-at to their own buckets, exactly
## as the inlined code did.
static func face_heading(c) -> void:
	if c._heading.length() <= 0.01:
		return
	var look_up: Vector3 = c.terrain.up_at(c.global_position)
	var fwd: Vector3 = c._heading - look_up * c._heading.dot(look_up)
	if fwd.length() > 0.001:
		var look: Vector3 = c.global_position + fwd
		if not look.is_equal_approx(c.global_position):
			c.look_at(look, look_up)


## Rotate `from` toward `to` about the LOCAL up axis by at most `max_angle` radians. Both vectors are
## projected onto the local tangent plane using the local radial up, so the turn always happens in the
## plane the creature actually walks on.
static func turn_toward(c, from: Vector3, to: Vector3, max_angle: float) -> Vector3:
	var up: Vector3 = c.terrain.up_at(c.global_position) if c.terrain != null else Vector3.UP
	var a: Vector3 = from - up * from.dot(up)
	var b: Vector3 = to - up * to.dot(up)
	if a.length() < 0.001:
		return to
	a = a.normalized()
	if b.length() < 0.001:
		return a
	b = b.normalized()
	var ang: float = a.signed_angle_to(b, up)
	var clamped: float = clampf(ang, -max_angle, max_angle)
	return a.rotated(up, clamped)
