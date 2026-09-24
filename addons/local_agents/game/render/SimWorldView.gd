@tool
class_name LASimWorldView
extends Node3D

## A LocalAgentSimWorld's look: the Sun under this node, aimed from the world's star to its body, and
## the material its terrain draws with.

@export_group("Wiring")
## The world this view dresses.
@export var sim_world: LocalAgentSimWorld:
	set(value):
		sim_world = value
		update_configuration_warnings()

@export_group("Terrain")
## The planet's surface material.
@export var terrain_material: ShaderMaterial:
	set(value):
		terrain_material = value
		update_configuration_warnings()

@onready var _sun: DirectionalLight3D = get_node_or_null("Sun") as DirectionalLight3D


func _ready() -> void:
	if Engine.is_editor_hint() or sim_world == null:
		return
	if sim_world.has_built():
		_dress()
	else:
		sim_world.world_built.connect(_dress, CONNECT_ONE_SHOT)


func _dress() -> void:
	var terrain: Variant = sim_world.terrain()
	if terrain != null and terrain.has_method("terrain_node"):
		LATerrainLook.dress(terrain.terrain_node(), terrain_material)


# The Sun shines the way the star's light travels, star to body.
func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or sim_world == null or _sun == null:
		return
	var star: LAStar = sim_world.star
	var body: Variant = sim_world.planet_body()
	if star == null or body == null:
		return
	var travel: Vector3 = (body.center() - star.global_position).normalized()
	var up: Vector3 = Vector3.UP if absf(travel.dot(Vector3.UP)) < 0.99 else Vector3.BACK
	_sun.global_basis = Basis.looking_at(travel, up)


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if sim_world == null:
		out.append("Sim World is unset, so no terrain takes Terrain Material. Point it at a LocalAgentSimWorld.")
	if terrain_material == null:
		out.append("Terrain Material is unset, so the planet draws with godot_voxel's default material.")
	if not get_node_or_null("Sun") is DirectionalLight3D:
		out.append("No DirectionalLight3D named Sun under this view, so nothing lights the world. Instance SimWorldView.tscn, which authors one.")
	return out
