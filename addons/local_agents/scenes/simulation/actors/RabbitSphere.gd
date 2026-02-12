extends Node3D
class_name RabbitSphere

signal seed_dropped(rabbit_id: String, count: int)

const MammalProfileScript = preload("res://addons/local_agents/configuration/parameters/simulation/MammalProfileResource.gd")
const SmellEmissionProfileScript = preload("res://addons/local_agents/configuration/parameters/simulation/SmellEmissionProfileResource.gd")
const LivingProfileScript = preload("res://addons/local_agents/configuration/parameters/simulation/LivingEntityProfileResource.gd")
const TaxonomyScript = preload("res://addons/local_agents/simulation/LivingEntityTaxonomy.gd")

@export var rabbit_id: String = ""
@export var forage_speed: float = 0.65
@export var flee_speed: float = 2.6
@export var smell_kind: String = "rabbit"
@export var smell_strength: float = 0.35
@export var digestion_seconds: float = 18.0
@export var can_smell_enabled: bool = true
@export var food_smell_radius_cells: int = 8
@export var danger_smell_radius_cells: int = 4
@export var smell_acuity: float = 1.0
@export var decision_commit_seconds: float = 1.6

@export var profile_food: Resource
@export var profile_danger: Resource
@export var emission_profile: Resource
@export var living_profile: Resource

var _food_target: Vector3 = Vector3.ZERO
var _has_food_target: bool = false
var _flee_direction: Vector3 = Vector3.ZERO
var _flee_remaining: float = 0.0
var _digestion_queue: Array[Dictionary] = []
var _decision_hold_remaining: float = 0.0

func _ready() -> void:
	add_to_group("living_smell_source")
	add_to_group("living_creature")
	add_to_group("living_animal")
	add_to_group("mammal_actor")
	add_to_group("living_mammal")
	add_to_group("living_lagomorph")
	add_to_group("field_selectable")
	if profile_food == null:
		profile_food = MammalProfileScript.new()
	if profile_danger == null:
		profile_danger = MammalProfileScript.new()
	if emission_profile == null:
		emission_profile = SmellEmissionProfileScript.new()
		emission_profile.set("base_strength", smell_strength)
		emission_profile.set("chemicals", {"2_heptanone": 0.7, "ammonia": 0.2})
	if living_profile == null:
		living_profile = LivingProfileScript.new()
	_configure_living_profile()
	_init_default_profiles()

func simulation_step(delta: float) -> void:
	_update_digestion(delta)
	if _decision_hold_remaining > 0.0:
		_decision_hold_remaining = maxf(0.0, _decision_hold_remaining - delta)
	if _flee_remaining > 0.0:
		_flee_remaining = maxf(0.0, _flee_remaining - delta)
		if _flee_direction.length_squared() > 0.0001:
			global_position += _flee_direction * flee_speed * delta
		return
	if _has_food_target:
		_move_toward_food(delta)

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

func ingest_seeds(seed_count: int) -> void:
	if seed_count <= 0:
		return
	_digestion_queue.append({"remaining": digestion_seconds, "count": seed_count})

func get_smell_source_payload() -> Dictionary:
	var ep = emission_profile
	return ep.call("to_payload", global_position, _id(), smell_kind)

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

func _move_toward_food(delta: float) -> void:
	var direction := _food_target - global_position
	direction.y = 0.0
	var distance := direction.length()
	if distance <= 0.05:
		_has_food_target = false
		return
	global_position += direction.normalized() * forage_speed * delta

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
	danger.chem_methyl_salicylate = 0.9
	danger.chem_alkaloids = 1.0
	danger.chem_tannins = 1.0
	danger.chem_ammonia = 1.4
	danger.chem_butyric_acid = 1.5

func get_inspector_payload() -> Dictionary:
	return {
		"title": "Rabbit",
		"id": _id(),
		"fleeing": is_fleeing(),
		"has_food_target": _has_food_target,
		"digestion_queue": _digestion_queue.size(),
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
	living_profile.taxonomy_path = TaxonomyScript.animal_path("mammal", "lagomorph")
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
