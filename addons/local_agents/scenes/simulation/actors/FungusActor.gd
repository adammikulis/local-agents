extends Node3D
class_name FungusActor

# Base for the FUNGUS kingdom (living_creature/fungus/...). Fungi are sessile decomposers:
# they colonize/spread over substrate, break down dead matter, and emit distinctive
# spore/decay scents. Separate branch from AnimalActor and PlantActor. This is a stub
# base establishing the kingdom; concrete fungi (mushrooms, molds) inherit and implement
# colonization + decomposition.

const LivingProfileScript = preload("res://addons/local_agents/configuration/parameters/simulation/LivingEntityProfileResource.gd")
const TaxonomyScript = preload("res://addons/local_agents/simulation/LivingEntityTaxonomy.gd")

@export var living_profile: Resource

func _ready() -> void:
	add_to_group("living_creature")
	add_to_group("living_fungus")
	add_to_group("living_smell_source")
	add_to_group("field_selectable")
	_register_fungus_groups()
	if living_profile == null:
		living_profile = LivingProfileScript.new()
	_init_fungus()

func _register_fungus_groups() -> void:
	pass

func _init_fungus() -> void:
	pass

func taxonomy_category() -> String:
	return "decomposer"

func taxonomy_subtype() -> String:
	return ""

func taxonomy_path() -> Array:
	# Fungi are their own kingdom; represented under the animal-path helper's generic
	# living-creature root with a "fungus" kingdom token.
	return TaxonomyScript.normalized_path(["living_creature", "fungus", taxonomy_category(), taxonomy_subtype()])

func get_smell_source_payload() -> Dictionary:
	return {}
