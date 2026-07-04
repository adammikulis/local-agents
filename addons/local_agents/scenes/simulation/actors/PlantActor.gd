extends Node3D
class_name PlantActor

# Base for the PLANT kingdom (living_creature/plant/...). Plants are sessile: no
# locomotion, nav, or breeding-by-pairing — they grow in place and emit scent that
# animals forage. Concrete plants (edible herbs, trees, grasses) inherit this and
# implement growth + chemistry. Kept a separate branch from AnimalActor because plants
# don't move (Node3D, not CharacterBody3D).

const LivingProfileScript = preload("res://addons/local_agents/configuration/parameters/simulation/LivingEntityProfileResource.gd")
const TaxonomyScript = preload("res://addons/local_agents/simulation/LivingEntityTaxonomy.gd")

@export var living_profile: Resource

func _ready() -> void:
	add_to_group("living_creature")
	add_to_group("living_plant")
	add_to_group("living_smell_source")
	add_to_group("field_selectable")
	_register_plant_groups()
	if living_profile == null:
		living_profile = LivingProfileScript.new()
	_init_plant()

# --- overridable hooks ------------------------------------------------------

func _register_plant_groups() -> void:
	pass

func _init_plant() -> void:
	pass

func taxonomy_category() -> String:
	return "flowering"

func taxonomy_subtype() -> String:
	return ""

func taxonomy_path() -> Array:
	return TaxonomyScript.plant_path(taxonomy_category(), taxonomy_subtype())

# Sessile: subclasses emit growth-driven scent; default is no emission.
func get_smell_source_payload() -> Dictionary:
	return {}
