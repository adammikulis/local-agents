@tool
class_name LAThrownRockVisual
extends Node3D

## A thrown stone drawn: the stone spinning about an axis across its flight, and the puff where it strikes.

@export_group("Tumble")
## Spin about the axis across the flight, rad/s. A free stone keeps the axis its release gave it.
@export var spin_rad_s: float = 12.0
@export_group("Impact")
## The puff thrown up where the stone strikes.
@export var puff_scene: PackedScene = null

@onready var _stone: Node3D = $Stone

var _rock: LAThrownRock = null
var _axis: Vector3 = Vector3.ZERO


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_rock = get_parent() as LAThrownRock
	if _rock != null:
		_rock.struck.connect(_on_struck)
	var box: BoxMesh = (_stone as MeshInstance3D).mesh.duplicate() as BoxMesh
	box.size = Vector3.ONE * LAThrownRock.STONE_SIDE
	(_stone as MeshInstance3D).mesh = box


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _rock == null:
		return
	if _axis == Vector3.ZERO:
		_axis = _across(_rock.velocity)
	if _axis != Vector3.ZERO:
		_stone.global_rotate(_axis, spin_rad_s * delta)


func _on_struck(at: Vector3) -> void:
	var puff: LAImpactPuff = puff_scene.instantiate() as LAImpactPuff
	_rock.get_parent().add_child(puff)
	puff.burst(at)


## A unit axis across `v`, or ZERO while the stone has not moved.
static func _across(v: Vector3) -> Vector3:
	var a: Vector3 = v.cross(Vector3.UP)
	if a.length_squared() < 1.0e-6 * v.length_squared():
		a = v.cross(Vector3.RIGHT)
	return a.normalized()


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if not get_parent() is LAThrownRock:
		out.append("Draws the LAThrownRock it is a child of: instance it in sim/actors/ThrownRock.tscn.")
	if puff_scene == null:
		out.append("Puff Scene is empty: a strike throws up nothing.")
	return out
