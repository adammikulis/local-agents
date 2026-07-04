extends "res://addons/local_agents/scenes/simulation/actors/MammalActor.gd"
class_name VillagerCapsule

# Human (animal/mammal/human): an omnivorous, tool-using mammal. Shares the same
# locomotion/nav/jump/breeding base as other creatures and specializes senses, a role,
# and build/carry channels. Locomotion lives in CreatureActor/MammalActor.

@export var npc_id: String = ""
@export var role: String = "gatherer"

func _register_creature_groups() -> void:
	super._register_creature_groups()
	add_to_group("living_human")

func taxonomy_subtype() -> String:
	return "human"

func _default_smell_kind() -> String:
	return "villager"

func _init_creature() -> void:
	if diet == "herbivore":
		diet = "omnivore"
	super._init_creature()

func set_villager_identity(next_npc_id: String, next_role: String) -> void:
	npc_id = next_npc_id
	role = next_role
	name = "Villager_%s" % npc_id
	_configure_living_profile()

func _default_emission_chemicals() -> Dictionary:
	return {"ammonia": 0.8, "butyric_acid": 0.6}

func _smell_id() -> String:
	if npc_id.strip_edges() != "":
		return "villager_%s" % npc_id
	return "villager_%d" % get_instance_id()

func _init_default_profiles() -> void:
	var food = profile_food
	var danger = profile_danger
	food.smell_acuity = smell_acuity
	food.food_smell_radius_cells = food_smell_radius_cells
	food.chem_hexanal = 0.45
	food.chem_cis_3_hexenol = 0.8
	food.chem_linalool = 0.7
	food.chem_benzyl_acetate = 0.6
	food.chem_phenylacetaldehyde = 0.6
	food.chem_geraniol = 0.55
	food.chem_sugars = 0.7
	food.chem_tannins = 0.9
	food.chem_alkaloids = 1.0
	danger.smell_acuity = smell_acuity
	danger.danger_smell_radius_cells = danger_smell_radius_cells
	danger.danger_threshold = 0.18
	danger.chem_methyl_salicylate = 1.2
	danger.chem_alkaloids = 1.0
	danger.chem_tannins = 0.9
	danger.chem_butyric_acid = 1.0

func get_inspector_payload() -> Dictionary:
	return {
		"title": "Villager",
		"id": _smell_id(),
		"role": role,
		"fleeing": is_fleeing(),
		"has_food_target": _has_food_target,
		"adult": is_adult(),
		"move_speed": move_speed,
		"can_smell": can_smell_enabled,
		"position": global_position,
	}

func get_living_entity_profile() -> Dictionary:
	if living_profile == null:
		living_profile = LivingProfileScript.new()
	_configure_living_profile()
	var row: Dictionary = living_profile.to_dict()
	row["position"] = {"x": global_position.x, "y": global_position.y, "z": global_position.z}
	row["role"] = role
	row["can_collect"] = true
	return row

func _configure_living_profile() -> void:
	if living_profile == null:
		return
	var entity_id = npc_id.strip_edges()
	if entity_id == "":
		entity_id = "villager_%d" % get_instance_id()
	living_profile.entity_id = entity_id
	living_profile.display_kind = "villager"
	living_profile.taxonomy_path = taxonomy_path()
	living_profile.ownership_weight = 0.82
	living_profile.belonging_weight = 0.91
	living_profile.gather_tendency = 0.68
	living_profile.mobility = clampf((move_speed + flee_speed * 0.25) / 3.0, 0.0, 1.0)
	living_profile.carry_channels = {"mouth": 0.12, "hands": 1.0}
	living_profile.build_channels = {"carry": 0.86, "dig": 0.34, "stack": 0.78, "pack": 0.46}
	living_profile.shelter_preferences = {"shape": "hut", "required_work": 16.0}
	var tags: Array[String] = ["builder", "collector", "culture_bearer", "hominid", "human"]
	living_profile.tags = tags
	living_profile.metadata = {
		"role": role,
		"can_smell": can_smell_enabled,
		"dexterous_grasp": true,
	}
