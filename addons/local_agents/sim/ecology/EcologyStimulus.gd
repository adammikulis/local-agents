class_name LAEcologyStimulus
extends Node


var _material = null                      # LAMaterialField — the ONE substrate (ground disturbance)


func set_material_field(m) -> void:
	_material = m


func disturb_ground(world_pos: Vector3, radius: float, strength: float) -> void:
	if _material != null and _material.has_method("disturb_terrain"):
		_material.disturb_terrain(world_pos, radius, strength)


## A blast reaches a body as the peak overpressure in that body's OWN cell. No such reading is published
## here, so no radius, falloff or impulse is invented in its place.
func damage_sphere(world_pos: Vector3, radius: float) -> void:
	push_error("LAEcologyStimulus.damage_sphere at %s r=%.1f: no overpressure relation is in this world." % [world_pos, radius])

# Relay an animal call (alarm / distress / forage) to everything in earshot. Omnidirectional: each
# listener decides by its OWN hearing_range, so no line of sight is needed — this is how a sentinel's
# screech flushes a whole herd and how food calls teach kin past the vision cone.
func broadcast_call(world_pos: Vector3, from_species: String, call_type: String, caller) -> void:
	for actor in LAGroupIndex.shared().nearby(get_tree(), "creature", world_pos, LACreatureSetup.max_hearing_range):
		if actor == caller or not is_instance_valid(actor) or not (actor is Node3D):
			continue
		if not actor.has_method("hear_call"):
			continue
		var hr: float = float(actor.get("hearing_range"))
		if (actor as Node3D).global_position.distance_to(world_pos) <= hr:
			actor.call("hear_call", world_pos, from_species, call_type, caller)
