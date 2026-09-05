class_name LAEcologyStimulus
extends Node


var _material = null                      # LAMaterialField — the ONE substrate (ground disturbance)


func set_material_field(m) -> void:
	_material = m


func disturb_ground(world_pos: Vector3, radius: float, strength: float) -> void:
	if _material != null and _material.has_method("disturb_terrain"):
		_material.disturb_terrain(world_pos, radius, strength)


## What a blast does to a body is set by the peak overpressure that reaches it, which follows from the
## impactor's energy and the air it drives. Nothing in this world computes one, so nothing here invents a
## damage number, a falloff or an impulse: the impact-energy lane fills this seam in.
func damage_sphere(world_pos: Vector3, radius: float) -> void:
	push_error("LAEcologyStimulus.damage_sphere at %s r=%.1f: no overpressure relation is in this world." % [world_pos, radius])


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
