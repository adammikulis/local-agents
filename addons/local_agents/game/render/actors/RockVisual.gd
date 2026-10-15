@tool
class_name LARockVisual
extends Node3D

## A loose boulder drawn at its own radius: an irregular stone, squat, lying at a turn of its own.

@export_group("Shape")
## Roughness of the stone's surface, as a share of its radius.
@export var jitter: float = 0.45
## Tilt off the local vertical the stone may lie at, rad.
@export var max_tilt_rad: float = 0.3

@onready var _stone: MeshInstance3D = $Stone


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var rock: LARock = get_parent() as LARock
	if rock == null:
		return
	if rock.radius_m() > 0.0:
		_shape(rock.radius_m())
	else:
		rock.settled.connect(_shape)


## Shape the stone for a boulder of `radius_m`, seeded off where it rests so one boulder keeps one shape.
func _shape(radius_m: float) -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = hash(get_parent().global_position)
	_stone.mesh = LARockMesh.make(radius_m, rng.randi(), jitter)
	_stone.rotation = Vector3(rng.randf_range(-max_tilt_rad, max_tilt_rad), rng.randf_range(0.0, TAU),
		rng.randf_range(-max_tilt_rad, max_tilt_rad))


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if not get_parent() is LARock:
		out.append("Draws the LARock it is a child of: LARenderLayer's Actor Views attaches it to each.")
	var stone: MeshInstance3D = get_node_or_null("Stone") as MeshInstance3D
	if stone == null or stone.material_override == null:
		out.append("Needs a Stone MeshInstance3D with its material: instance RockVisual.tscn.")
	return out
