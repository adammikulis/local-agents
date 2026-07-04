extends "res://addons/local_agents/scenes/simulation/actors/MammalActor.gd"
class_name FoxActor

# Canid predator (animal/mammal/canid): a carnivore that hunts rabbits by scent. Its
# "food" smell profile is tuned to rabbit musk, so the shared smell-driven forage logic
# makes it stalk prey; its own emission (musk) is what rabbits flee. Catching a rabbit
# feeds the fox, which lets it breed. Locomotion/jump/nav come from CreatureActor.

@export var fox_id: String = ""
@export var hunt_speed: float = 3.1
@export var catch_radius: float = 0.6

var _fed_count: int = 0
var _meals_since_breeding: int = 0

func _register_creature_groups() -> void:
	super._register_creature_groups()
	add_to_group("living_canid")
	add_to_group("predator_actor")

func taxonomy_subtype() -> String:
	return "canid"

func _default_smell_kind() -> String:
	return "fox"

func _init_creature() -> void:
	move_speed = hunt_speed
	diet = "carnivore"
	food_smell_radius_cells = maxi(food_smell_radius_cells, 12)
	super._init_creature()

func mark_fed() -> void:
	_fed_count += 1
	_meals_since_breeding += 1

# Foxes only reproduce after eating — energy from a catch — so the predator population
# is bounded by prey availability rather than growing unconditionally.
func can_reproduce() -> bool:
	return super.can_reproduce() and _meals_since_breeding >= 1

func mark_bred() -> void:
	super.mark_bred()
	_meals_since_breeding = 0

func get_prey_group() -> String:
	return "living_lagomorph"

func get_catch_radius() -> float:
	return maxf(0.1, catch_radius)

func _default_emission_chemicals() -> Dictionary:
	# Musk that prey animals treat as danger. Deliberately excludes the rabbit-scent
	# chemicals (2-heptanone) the fox hunts, so foxes are not drawn to their own trail.
	return {"butyric_acid": 0.9}

func _smell_id() -> String:
	return _id()

func _id() -> String:
	if fox_id.strip_edges() != "":
		return fox_id
	return "fox_%d" % get_instance_id()

func _init_default_profiles() -> void:
	var food = profile_food
	var danger = profile_danger
	food.smell_acuity = smell_acuity
	food.food_smell_radius_cells = food_smell_radius_cells
	# Attraction to rabbit scent (2-heptanone) — the signature the fox hunts. Kept
	# distinct from the fox's own musk so it tracks prey, not itself.
	food.chem_2_heptanone = 1.8
	# Apex here: no predator scares the fox.
	danger.smell_acuity = smell_acuity
	danger.danger_smell_radius_cells = danger_smell_radius_cells
	danger.danger_threshold = 100.0

func get_inspector_payload() -> Dictionary:
	return {
		"title": "Fox",
		"id": _id(),
		"hunting": _has_food_target,
		"prey_eaten": _fed_count,
		"adult": is_adult(),
		"hunt_speed": hunt_speed,
		"can_smell": can_smell_enabled,
		"position": global_position,
	}

func get_living_entity_profile() -> Dictionary:
	if living_profile == null:
		living_profile = LivingProfileScript.new()
	_configure_living_profile()
	var row: Dictionary = living_profile.to_dict()
	row["position"] = {"x": global_position.x, "y": global_position.y, "z": global_position.z}
	return row

func _configure_living_profile() -> void:
	if living_profile == null:
		return
	living_profile.entity_id = _id()
	living_profile.display_kind = "fox"
	living_profile.taxonomy_path = taxonomy_path()
	living_profile.ownership_weight = 0.12
	living_profile.belonging_weight = 0.3
	living_profile.gather_tendency = 0.2
	living_profile.mobility = clampf(hunt_speed / 3.0, 0.0, 1.0)
	var tags: Array[String] = ["predator", "hunter", "carnivore"]
	living_profile.tags = tags
	living_profile.metadata = {
		"can_smell": can_smell_enabled,
		"prey_eaten": _fed_count,
	}
