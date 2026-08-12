class_name LAEcologyStimulus
extends Node


var _material = null                      # LAMaterialField — the ONE substrate (ground disturbance / shock inject)


func set_material_field(m) -> void:
	_material = m


func disturb_ground(world_pos: Vector3, radius: float, strength: float) -> void:
	if _material != null and _material.has_method("disturb_terrain"):
		_material.disturb_terrain(world_pos, radius, strength)
	# EVERY ground disturbance is also FELT as a seismic pulse — the camera shake emerges from this, so
	# no caller needs its own shake call. A wider disturbance moves more ground, so it hits harder.
	broadcast_seismic(world_pos, strength * clampf(radius / 12.0, 0.3, 4.0))


func broadcast_seismic(world_pos: Vector3, magnitude: float) -> void:
	if magnitude <= 0.0:
		return
	if _material != null and _material.has_method("emit_shock"):
		_material.emit_shock(world_pos, magnitude)


static func blast_falloff(d: float, radius: float) -> float:
	if radius <= 0.0:
		return 0.0
	var f: float = clampf(1.0 - d / radius, 0.0, 1.0)
	return f * f


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
