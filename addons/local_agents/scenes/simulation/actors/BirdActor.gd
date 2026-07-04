extends "res://addons/local_agents/scenes/simulation/actors/AnimalActor.gd"
class_name BirdActor

# Flying animal (animal/bird): flocks in full 3D. Unlike grounded mammals it has no
# gravity binding — AnimalActor's fly mode steers it in 3D toward a boids heading and a
# cruise altitude. Driven by BirdFlockController, which feeds the flock velocity via the
# shared apply_flock_output channel each tick. Birds emit scent like any animal.

@export var bird_id: String = ""

func _register_creature_groups() -> void:
	add_to_group("living_bird")
	add_to_group("bird_actor")

func taxonomy_category() -> String:
	return "bird"

func _default_smell_kind() -> String:
	return "bird"

func _default_emission_chemicals() -> Dictionary:
	# Feather/preen-oil + droppings scent; distinct from mammal musk.
	return {"hexanal": 0.3, "ammonia": 0.35}

func get_inspector_payload() -> Dictionary:
	return {
		"title": "Bird",
		"id": _id(),
		"altitude": global_position.y,
		"speed": velocity.length(),
		"position": global_position,
	}

func _smell_id() -> String:
	return _id()

func _id() -> String:
	if bird_id.strip_edges() != "":
		return bird_id
	return "bird_%d" % get_instance_id()
