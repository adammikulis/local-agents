extends CharacterBody3D

const MammalProfileScript = preload("res://addons/local_agents/configuration/parameters/simulation/MammalProfileResource.gd")
const SmellEmissionProfileScript = preload("res://addons/local_agents/configuration/parameters/simulation/SmellEmissionProfileResource.gd")
const LivingProfileScript = preload("res://addons/local_agents/configuration/parameters/simulation/LivingEntityProfileResource.gd")
const TaxonomyScript = preload("res://addons/local_agents/simulation/LivingEntityTaxonomy.gd")

@export var npc_id: String = ""
@export var role: String = "gatherer"
@export var move_speed: float = 1.25
@export var flee_speed: float = 2.2
@export var smell_kind: String = "villager"
@export var smell_strength: float = 0.45
@export var can_smell_enabled: bool = true
@export var food_smell_radius_cells: int = 7
@export var danger_smell_radius_cells: int = 5
@export var smell_acuity: float = 0.9
@export var decision_commit_seconds: float = 1.2

@export var profile_food: Resource
@export var profile_danger: Resource
@export var emission_profile: Resource
@export var living_profile: Resource

var _food_target: Vector3 = Vector3.ZERO
var _has_food_target: bool = false
var _flee_direction: Vector3 = Vector3.ZERO
var _flee_remaining: float = 0.0
var _decision_hold_remaining: float = 0.0

func set_villager_identity(next_npc_id: String, next_role: String) -> void:
	npc_id = next_npc_id
	role = next_role
	name = "Villager_%s" % npc_id
	_configure_living_profile()

func _ready() -> void:
	add_to_group("living_smell_source")
	add_to_group("living_creature")
	add_to_group("living_animal")
	add_to_group("mammal_actor")
	add_to_group("living_mammal")
	add_to_group("living_human")
	if profile_food == null:
		profile_food = MammalProfileScript.new()
	if profile_danger == null:
		profile_danger = MammalProfileScript.new()
	if emission_profile == null:
		emission_profile = SmellEmissionProfileScript.new()
		emission_profile.set("base_strength", smell_strength)
		emission_profile.set("chemicals", {"ammonia": 0.8, "butyric_acid": 0.6})
	if living_profile == null:
		living_profile = LivingProfileScript.new()
	_configure_living_profile()
	_init_default_profiles()

func simulation_step(delta: float) -> void:
	if _decision_hold_remaining > 0.0:
		_decision_hold_remaining = maxf(0.0, _decision_hold_remaining - delta)
	if _flee_remaining > 0.0:
		_flee_remaining = maxf(0.0, _flee_remaining - delta)
		if _flee_direction.length_squared() > 0.0001:
			global_position += _flee_direction * flee_speed * delta
		return
	if _has_food_target:
		var direction := _food_target - global_position
		direction.y = 0.0
		var distance := direction.length()
		if distance <= 0.06:
			_has_food_target = false
		else:
			global_position += direction.normalized() * move_speed * delta

func set_food_target(position: Vector3) -> void:
	if _decision_hold_remaining > 0.0 and _has_food_target:
		return
	_food_target = position
	_has_food_target = true
	_decision_hold_remaining = decision_commit_seconds

func clear_food_target() -> void:
	if _decision_hold_remaining > 0.0 and _has_food_target:
		return
	_has_food_target = false

func trigger_flee(away_from: Vector3, duration_seconds: float) -> void:
	var direction := global_position - away_from
	if direction.length_squared() <= 0.0001:
		direction = Vector3(1.0, 0.0, 0.0)
	_flee_direction = direction.normalized()
	_flee_remaining = maxf(_flee_remaining, duration_seconds)
	_decision_hold_remaining = decision_commit_seconds

func is_fleeing() -> bool:
	return _flee_remaining > 0.0

func get_smell_source_payload() -> Dictionary:
	var ep = emission_profile
	return ep.call("to_payload", global_position, _smell_id(), smell_kind)

func can_smell() -> bool:
	return can_smell_enabled

func get_food_smell_radius_cells() -> int:
	return maxi(1, food_smell_radius_cells)

func get_danger_smell_radius_cells() -> int:
	return maxi(1, danger_smell_radius_cells)

func get_food_chemical_weights() -> Dictionary:
	return profile_food.call("as_weights", true, true)

func get_danger_chemical_weights() -> Dictionary:
	return profile_danger.call("as_weights", false, false)

func get_danger_threshold() -> float:
	return float(profile_danger.get("danger_threshold"))

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
	danger.chem_ammonia = 1.1
	danger.chem_butyric_acid = 1.0

func _smell_id() -> String:
	if npc_id.strip_edges() != "":
		return "villager_%s" % npc_id
	return "villager_%d" % get_instance_id()

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
	living_profile.taxonomy_path = TaxonomyScript.animal_path("mammal", "human")
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
