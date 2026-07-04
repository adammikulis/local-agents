extends "res://addons/local_agents/scenes/simulation/actors/MammalActor.gd"
class_name RabbitSphere

# Lagomorph (animal/mammal/lagomorph): a herbivore prey animal that forages plants by
# smell, flees predators (foxes) with an evasive hop, digests seeds and reseeds via
# droppings. All locomotion/nav/jump/breeding lives in CreatureActor/MammalActor.

signal seed_dropped(rabbit_id: String, count: int)

@export var rabbit_id: String = ""
@export var forage_speed: float = 0.65
@export var digestion_seconds: float = 18.0

var _digestion_queue: Array[Dictionary] = []

func _register_creature_groups() -> void:
	super._register_creature_groups()
	add_to_group("living_lagomorph")

func taxonomy_subtype() -> String:
	return "lagomorph"

func _default_smell_kind() -> String:
	return "rabbit"

func _init_creature() -> void:
	move_speed = forage_speed
	super._init_creature()

func simulation_step(delta: float) -> void:
	_update_digestion(delta)
	super.simulation_step(delta)

func ingest_seeds(seed_count: int) -> void:
	if seed_count <= 0:
		return
	_digestion_queue.append({"remaining": digestion_seconds, "count": seed_count})

func _update_digestion(delta: float) -> void:
	if _digestion_queue.is_empty():
		return
	for i in range(_digestion_queue.size() - 1, -1, -1):
		var entry = _digestion_queue[i]
		entry["remaining"] = float(entry.get("remaining", 0.0)) - delta
		if float(entry["remaining"]) <= 0.0:
			emit_signal("seed_dropped", _id(), int(entry.get("count", 0)))
			_digestion_queue.remove_at(i)
		else:
			_digestion_queue[i] = entry

func _default_emission_chemicals() -> Dictionary:
	return {"2_heptanone": 0.7, "ammonia": 0.2}

func _smell_id() -> String:
	return _id()

func _id() -> String:
	if rabbit_id.strip_edges() != "":
		return rabbit_id
	return "rabbit_%d" % get_instance_id()

func _init_default_profiles() -> void:
	var food = profile_food
	var danger = profile_danger
	food.smell_acuity = smell_acuity
	food.food_smell_radius_cells = food_smell_radius_cells
	food.chem_hexanal = 0.3
	food.chem_cis_3_hexenol = 1.2
	food.chem_linalool = 1.0
	food.chem_benzyl_acetate = 1.1
	food.chem_phenylacetaldehyde = 1.1
	food.chem_geraniol = 1.0
	food.chem_sugars = 1.2
	food.chem_tannins = 1.0
	food.chem_alkaloids = 1.0
	danger.smell_acuity = smell_acuity
	danger.danger_smell_radius_cells = danger_smell_radius_cells
	danger.danger_threshold = 0.14
	# Flee predator musk (fox butyric_acid) and plant alarm chemicals. Deliberately does
	# NOT include 2-heptanone (the rabbit's own scent) so rabbits don't flee each other.
	danger.chem_methyl_salicylate = 0.9
	danger.chem_alkaloids = 1.0
	danger.chem_tannins = 1.0
	danger.chem_butyric_acid = 1.6

func get_inspector_payload() -> Dictionary:
	return {
		"title": "Rabbit",
		"id": _id(),
		"fleeing": is_fleeing(),
		"has_food_target": _has_food_target,
		"digestion_queue": _digestion_queue.size(),
		"adult": is_adult(),
		"forage_speed": forage_speed,
		"flee_speed": flee_speed,
		"can_smell": can_smell_enabled,
		"smell_acuity": smell_acuity,
		"position": global_position,
	}

func get_living_entity_profile() -> Dictionary:
	if living_profile == null:
		living_profile = LivingProfileScript.new()
	_configure_living_profile()
	var row: Dictionary = living_profile.to_dict()
	row["position"] = {"x": global_position.x, "y": global_position.y, "z": global_position.z}
	row["can_collect"] = true
	row["collects_kind"] = "seeds"
	return row

func _configure_living_profile() -> void:
	if living_profile == null:
		return
	living_profile.entity_id = _id()
	living_profile.display_kind = "rabbit"
	living_profile.taxonomy_path = taxonomy_path()
	living_profile.ownership_weight = 0.08
	living_profile.belonging_weight = 0.22
	living_profile.gather_tendency = 0.74
	living_profile.mobility = clampf((forage_speed + flee_speed * 0.35) / 3.0, 0.0, 1.0)
	living_profile.carry_channels = {"mouth": 0.26}
	living_profile.build_channels = {"carry": 0.34, "dig": 0.62, "pack": 0.28}
	living_profile.shelter_preferences = {"shape": "burrow", "required_work": 7.0}
	var tags: Array[String] = ["forager", "seed_disperser", "prey"]
	living_profile.tags = tags
	living_profile.metadata = {
		"can_smell": can_smell_enabled,
		"digestion_seconds": digestion_seconds,
	}
