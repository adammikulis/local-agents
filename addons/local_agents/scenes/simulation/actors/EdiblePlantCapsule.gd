extends Node3D
class_name EdiblePlantCapsule

signal consumed(plant_id: String, seeds: int)

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

@onready var mesh_instance: MeshInstance3D = $MeshInstance3D

var _age_seconds: float = 0.0
var _consumed: bool = false

func _ready() -> void:
	add_to_group("living_smell_source")
	if mesh_instance.material_override is StandardMaterial3D:
		mesh_instance.material_override = (mesh_instance.material_override as StandardMaterial3D).duplicate()
	_update_visual_scale()

func simulation_step(delta: float) -> void:
	if _consumed:
		return
	_age_seconds = minf(_age_seconds + maxf(delta, 0.0), grow_duration_seconds)
	_update_visual_scale()

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
	var growth := growth_ratio()
	var scalar := lerpf(min_scale, max_scale, growth)
	mesh_instance.scale = Vector3.ONE * scalar
	_apply_flower_visuals()

func _id() -> String:
	if plant_id.strip_edges() != "":
		return plant_id
	return "plant_%d" % get_instance_id()

func chemical_profile() -> Dictionary:
	# Real compounds modeled with simple growth curves:
	# - hexanal: green-cut grass aldehyde
	# - cis-3-hexenol: leafy/fruity alcohol
	# - linalool: floral terpene
	# - methyl_salicylate: wintergreen-like defense volatile
	# - tannins/alkaloids: bitterness and astringency deterrents
	# - sugars: sweet taste cue for mammals
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
