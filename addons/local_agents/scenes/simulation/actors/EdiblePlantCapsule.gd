extends Node3D
class_name EdiblePlantCapsule

signal consumed(plant_id: String, seeds: int)
signal edible_state_changed(plant_id: String, edible: bool)

@export var plant_id: String = ""
@export var grow_duration_seconds: float = 80.0
@export var min_scale: float = 0.25
@export var max_scale: float = 1.0
@export var smell_kind: String = "plant_food"
@export var max_smell_strength: float = 1.0
@export var edible_growth_threshold: float = 0.7
@export var smell_growth_threshold: float = 0.65
@export var flowering_growth_threshold: float = 0.55
@export var flowering_peak_growth: float = 0.82
@export var flowering_smell_boost: float = 0.55
@export var seeds_per_plant: int = 2

const SmellEmissionProfileScript = preload("res://addons/local_agents/configuration/parameters/simulation/SmellEmissionProfileResource.gd")
const LivingProfileScript = preload("res://addons/local_agents/configuration/parameters/simulation/LivingEntityProfileResource.gd")
const TaxonomyScript = preload("res://addons/local_agents/simulation/LivingEntityTaxonomy.gd")
@export var smell_profile: Resource
@export var living_profile: Resource

@onready var mesh_instance: MeshInstance3D = $MeshInstance3D

var _age_seconds: float = 0.0
var _consumed: bool = false
var _last_edible_state: bool = false

func _ready() -> void:
	add_to_group("living_smell_source")
	add_to_group("living_creature")
	add_to_group("living_plant")
	add_to_group("living_edible_plant")
	add_to_group("field_selectable")
	if smell_profile == null:
		smell_profile = SmellEmissionProfileScript.new()
	if living_profile == null:
		living_profile = LivingProfileScript.new()
	_configure_living_profile()
	if mesh_instance.material_override is StandardMaterial3D:
		mesh_instance.material_override = (mesh_instance.material_override as StandardMaterial3D).duplicate()
	_update_visual_scale()
	_last_edible_state = is_edible()

func simulation_step(delta: float) -> void:
	if _consumed:
		return
	_age_seconds = minf(_age_seconds + maxf(delta, 0.0), grow_duration_seconds)
	_update_visual_scale()
	var now_edible := is_edible()
	if now_edible != _last_edible_state:
		_last_edible_state = now_edible
		emit_signal("edible_state_changed", _id(), now_edible)

func is_edible() -> bool:
	if _consumed:
		return false
	return growth_ratio() >= edible_growth_threshold

func growth_ratio() -> float:
	if grow_duration_seconds <= 0.001:
		return 1.0
	return clampf(_age_seconds / grow_duration_seconds, 0.0, 1.0)

func consume() -> int:
	if not is_edible():
		return 0
	_consumed = true
	visible = false
	emit_signal("consumed", _id(), seeds_per_plant)
	emit_signal("edible_state_changed", _id(), false)
	return seeds_per_plant

func get_smell_source_payload() -> Dictionary:
	if _consumed:
		return {}
	var growth := growth_ratio()
	if growth < smell_growth_threshold:
		return {}
	var chemistry := chemical_profile()
	var attractive := float(chemistry.get("cis_3_hexenol", 0.0)) + float(chemistry.get("linalool", 0.0)) + float(chemistry.get("sugars", 0.0))
	var floral := float(chemistry.get("benzyl_acetate", 0.0)) + float(chemistry.get("phenylacetaldehyde", 0.0)) + float(chemistry.get("geraniol", 0.0))
	var deterrent := float(chemistry.get("tannins", 0.0)) + float(chemistry.get("alkaloids", 0.0))
	var flower_factor := flowering_ratio()
	var chemistry_drive := clampf(attractive + floral * flowering_smell_boost * flower_factor - (0.6 * deterrent), 0.0, 1.0)
	return {
		"id": _id(),
		"position": global_position,
		"strength": max_smell_strength * chemistry_drive,
		"kind": smell_kind,
		"chemicals": chemistry,
		"flowering_ratio": flower_factor,
	}

func set_initial_growth_ratio(ratio: float) -> void:
	_age_seconds = clampf(ratio, 0.0, 1.0) * grow_duration_seconds
	_update_visual_scale()

func _update_visual_scale() -> void:
	if mesh_instance == null:
		return
	var growth := growth_ratio()
	var scalar := lerpf(min_scale, max_scale, growth)
	mesh_instance.scale = Vector3.ONE * scalar
	_apply_flower_visuals()

func _id() -> String:
	if plant_id.strip_edges() != "":
		return plant_id
	return "plant_%d" % get_instance_id()

func chemical_profile() -> Dictionary:
	var g := growth_ratio()
	var hexanal := clampf(1.0 - g * 0.75, 0.0, 1.0)
	var cis_3_hexenol := clampf(0.18 + g * 0.82, 0.0, 1.0)
	var linalool := clampf(maxf(0.0, g - 0.45) / 0.55, 0.0, 1.0)
	var methyl_salicylate := clampf(0.1 + g * 0.25, 0.0, 1.0)
	var sugars := clampf(maxf(0.0, g - 0.35) / 0.65, 0.0, 1.0)
	var tannins := clampf(0.72 - g * 0.52, 0.0, 1.0)
	var alkaloids := clampf(0.64 - g * 0.44, 0.0, 1.0)
	var flower := flowering_ratio()
	var benzyl_acetate := clampf(flower * 0.92, 0.0, 1.0)
	var phenylacetaldehyde := clampf(flower * 0.8, 0.0, 1.0)
	var geraniol := clampf(flower * 0.76, 0.0, 1.0)
	return {
		"hexanal": hexanal,
		"cis_3_hexenol": cis_3_hexenol,
		"linalool": linalool,
		"methyl_salicylate": methyl_salicylate,
		"benzyl_acetate": benzyl_acetate,
		"phenylacetaldehyde": phenylacetaldehyde,
		"geraniol": geraniol,
		"sugars": sugars,
		"tannins": tannins,
		"alkaloids": alkaloids,
	}

func flowering_ratio() -> float:
	var g := growth_ratio()
	if g < flowering_growth_threshold:
		return 0.0
	var rise_span := maxf(0.001, flowering_peak_growth - flowering_growth_threshold)
	if g <= flowering_peak_growth:
		return clampf((g - flowering_growth_threshold) / rise_span, 0.0, 1.0)
	var fall_span := maxf(0.001, 1.0 - flowering_peak_growth)
	return clampf(1.0 - ((g - flowering_peak_growth) / fall_span), 0.0, 1.0)

func _apply_flower_visuals() -> void:
	if not (mesh_instance.material_override is StandardMaterial3D):
		return
	var material := mesh_instance.material_override as StandardMaterial3D
	var flower := flowering_ratio()
	var stem_color := Color(0.31, 0.82, 0.35, 1.0)
	var flower_tint := Color(0.92, 0.93, 0.76, 1.0)
	material.albedo_color = stem_color.lerp(flower_tint, flower * 0.5)

func get_inspector_payload() -> Dictionary:
	return {
		"title": "Edible Plant",
		"id": _id(),
		"growth_ratio": growth_ratio(),
		"flowering_ratio": flowering_ratio(),
		"edible": is_edible(),
		"consumed": _consumed,
		"seeds_per_plant": seeds_per_plant,
		"chemistry": chemical_profile(),
		"position": global_position,
	}

func get_living_entity_profile() -> Dictionary:
	if living_profile == null:
		living_profile = LivingProfileScript.new()
	_configure_living_profile()
	var row: Dictionary = living_profile.to_dict()
	row["position"] = {"x": global_position.x, "y": global_position.y, "z": global_position.z}
	row["growth_ratio"] = growth_ratio()
	row["edible"] = is_edible()
	return row

func _configure_living_profile() -> void:
	if living_profile == null:
		return
	living_profile.entity_id = _id()
	living_profile.display_kind = "edible_plant"
	living_profile.taxonomy_path = TaxonomyScript.plant_path("flowering", "edible_herb")
	living_profile.ownership_weight = 0.34
	living_profile.belonging_weight = 0.28
	living_profile.gather_tendency = 0.0
	living_profile.mobility = 0.0
	living_profile.carry_channels = {}
	living_profile.build_channels = {}
	living_profile.shelter_preferences = {"shape": "cover", "required_work": 0.0}
	var tags: Array[String] = ["food_source", "edible", "seed_origin"]
	living_profile.tags = tags
	living_profile.metadata = {
		"seeds_per_plant": seeds_per_plant,
		"smell_kind": smell_kind,
	}
