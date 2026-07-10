class_name LAEcologyStimulus
extends Node

## The world's STIMULUS / BROADCAST bus — the single seam every disaster couples to the living world
## through. A meteor, earthquake, volcano, storm, flood or a hard landing does not reach into creatures
## or the terrain itself: it emits a stimulus here (a ground disturbance, a seismic pulse, a graded
## point blast, a felt terror, an animal call, an area wind force) and the affected actors + the field
## react locally. New events compose with existing reactions for free, so a disaster is a SEED that
## emits — never per-event coupling code.
##
## Owned by LAEcologyService (a Node child, so it can scan the scene groups); the service keeps thin
## forwarders for back-compat. The material field is pushed in via set_material_field so the ground
## channels (slump, shock) and the reads stay pointed at the one substrate.
## Explicit types only (project rule: no ':=').

var _material = null                      # LAMaterialField — the ONE substrate (ground disturbance / shock inject)


func set_material_field(m) -> void:
	_material = m


# Broadcast a GROUND-DISTURBANCE stimulus (meteor blast, earthquake, later a saturated slope). It just
# tells the material field the earth was shaken here — loose/steep ground then slumps toward its angle
# of repose under GRAVITY, in the field's own granular step. No landslide "system"; it's material
# physics. One channel every disaster reuses.
func disturb_ground(world_pos: Vector3, radius: float, strength: float) -> void:
	if _material != null and _material.has_method("disturb_terrain"):
		_material.disturb_terrain(world_pos, radius, strength)
	# EVERY ground disturbance is also FELT as a seismic pulse — the camera shake emerges from this, so
	# no caller needs its own shake call. A wider disturbance moves more ground, so it hits harder.
	broadcast_seismic(world_pos, strength * clampf(radius / 12.0, 0.3, 4.0))


# The seismic/shock stimulus is a REAL PROPAGATING FIELD (LAMaterialShock3D in MaterialField3D), not a
# point ring: every ground-disturbing event injects a shock wave that radiates outward + is muffled by
# terrain, so a blast behind a ridge is felt less for free. This just mediates the actor→field call
# (the ONE stimulus every impact/tremor feeds); the camera + energy graph read it back on the service.
func broadcast_seismic(world_pos: Vector3, magnitude: float) -> void:
	if magnitude <= 0.0:
		return
	if _material != null and _material.has_method("emit_shock"):
		_material.emit_shock(world_pos, magnitude)


# Deterministic point-source falloff: max (1.0) at the centre, 0.0 at/beyond the edge, squared for a
# sharp peak so a blast/bolt kills hard near the impact and tapers quickly toward the rim. No randomness
# — the same distance always yields the same fraction. Shared by every point blast (damage_sphere here,
# and later lightning's fish electrocution).
static func blast_falloff(d: float, radius: float) -> float:
	if radius <= 0.0:
		return 0.0
	var f: float = clampf(1.0 - d / radius, 0.0, 1.0)
	return f * f


# A point blast (meteor, earthquake, lightning). Deals GRADED, deterministic damage: each actor in
# range with take_damage() loses base_damage * falloff(distance) HP and dies only when its HP hits 0
# — lethal at the centre, survivable at the rim. `base_damage` defaults large so the centre still
# reproduces the old lethal-blast feel. Actors without take_damage (plants/rocks) fall back to the
# old topple/die/clear behaviour.
func damage_sphere(world_pos: Vector3, radius: float, base_damage: float = 1000.0) -> void:
	var r2: float = radius * radius
	for actor in get_tree().get_nodes_in_group("selectable"):
		if not is_instance_valid(actor) or not (actor is Node3D):
			continue
		var a: Node3D = actor as Node3D
		var d2: float = a.global_position.distance_squared_to(world_pos)
		if d2 > r2:
			continue
		if a.has_method("take_damage"):
			var falloff: float = blast_falloff(sqrt(d2), radius)
			if falloff <= 0.0:
				continue
			# Fling scales with proximity too, so the killing blow throws the corpse outward.
			var away: Vector3 = a.global_position - world_pos
			away.y = absf(away.y) + 2.0
			var impulse: Vector3 = away.normalized() * (14.0 + 34.0 * falloff)
			a.take_damage(base_damage * falloff, "blast", impulse)
		elif a.has_method("topple"):
			# Trees don't vanish — the blast knocks them over, falling away from impact.
			var dir: Vector3 = a.global_position - world_pos
			dir.y = 0.0
			a.topple(dir)
		elif a.has_method("die"):
			var away2: Vector3 = a.global_position - world_pos
			away2.y = absf(away2.y) + 2.0
			var force: float = 1.0 - a.global_position.distance_to(world_pos) / maxf(1.0, radius)
			a.die("meteor", away2.normalized() * (14.0 + 34.0 * force))
		elif not a.is_in_group("corpse"):
			a.queue_free()


# Broadcast a felt/heard terror event (meteor impact, etc). Every creature within `radius` panics and
# sprints away, more intensely the closer it is.
func broadcast_scare(world_pos: Vector3, radius: float, base_intensity: float = 1.0) -> void:
	if radius <= 0.0:
		return
	for actor in get_tree().get_nodes_in_group("selectable"):
		if not is_instance_valid(actor) or not (actor is Node3D):
			continue
		if not actor.has_method("add_fear"):
			continue
		var d: float = (actor as Node3D).global_position.distance_to(world_pos)
		if d > radius:
			continue
		var closeness: float = 1.0 - (d / radius)          # 1 at impact, 0 at edge
		var panic_seconds: float = lerpf(2.0, 7.0, closeness) * base_intensity
		actor.call("add_fear", world_pos, panic_seconds)


# Broadcast an AREA WIND/MOMENTUM force: every creature within `radius` is continuously advected by a
# force sampled at its own position via `force_fn` (a Callable Vector3 -> Vector3 world_pos -> force).
# This is the seam every storm/tornado/hurricane fling dissolution drives — it pushes creatures through
# their field-force hook (LACreatureFieldForces.apply) instead of editing the creature or this hub. The
# force source arrives with the substrate agent; a zero `force_fn` (or delta) is an inert no-op today.
func apply_wind_force(world_pos: Vector3, radius: float, force_fn: Callable, delta: float = 0.0) -> void:
	if radius <= 0.0 or not force_fn.is_valid():
		return
	var r2: float = radius * radius
	for actor in get_tree().get_nodes_in_group("creature"):
		if not is_instance_valid(actor) or not (actor is Node3D):
			continue
		if not actor.has_method("apply_field_force"):
			continue
		var cpos: Vector3 = (actor as Node3D).global_position
		if cpos.distance_squared_to(world_pos) > r2:
			continue
		var force: Vector3 = force_fn.call(cpos)
		actor.apply_field_force(force, delta)


# Relay an animal call (alarm / distress / forage) to everything in earshot. Omnidirectional: each
# listener decides by its OWN hearing_range, so no line of sight is needed — this is how a sentinel's
# screech flushes a whole herd and how food calls teach kin past the vision cone.
func broadcast_call(world_pos: Vector3, from_species: String, call_type: String, caller) -> void:
	for actor in get_tree().get_nodes_in_group("creature"):
		if actor == caller or not is_instance_valid(actor) or not (actor is Node3D):
			continue
		if not actor.has_method("hear_call"):
			continue
		var hr: float = float(actor.get("hearing_range"))
		if (actor as Node3D).global_position.distance_to(world_pos) <= hr:
			actor.call("hear_call", world_pos, from_species, call_type, caller)
