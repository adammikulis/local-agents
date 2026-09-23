@tool
class_name LASimWorldView
extends Node3D

## A LocalAgentSimWorld's look: the Sun light under this node, and the material its terrain draws with.

## The world this view dresses.
@export var sim_world: LocalAgentSimWorld:
	set(value):
		sim_world = value
		update_configuration_warnings()

@export_group("Terrain")
## The planet's surface material. The terrain draws with its own copy, so runtime uniforms stay per world.
@export var terrain_material: ShaderMaterial


func _ready() -> void:
	if Engine.is_editor_hint() or sim_world == null:
		return
	if sim_world.has_built():
		_dress()
	else:
		sim_world.world_built.connect(_dress, CONNECT_ONE_SHOT)


func _dress() -> void:
	var terrain: Variant = sim_world.terrain()
	if terrain_material != null and terrain != null and terrain.has_method("set_terrain_material"):
		terrain.set_terrain_material(terrain_material)


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if sim_world == null:
		out.append("Sim World is unset, so no terrain takes Terrain Material. Point it at a LocalAgentSimWorld.")
	return out
