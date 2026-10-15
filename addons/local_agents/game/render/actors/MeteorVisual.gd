@tool
class_name LAMeteorVisual
extends Node3D

## A falling rock drawn: its body at the rock's own size, the embers it sheds, and the collider it is picked by.

@onready var _body: MeshInstance3D = $Body
@onready var _trail: GPUParticles3D = $Trail
@onready var _picker: StaticBody3D = $Picker


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var rock: LAMeteor = get_parent() as LAMeteor
	if rock == null:
		return
	rock.launched.connect(_on_launched)
	rock.impacted.connect(_on_impacted)


## The body mesh is authored at one size and the rock has its own; the embers leave up the local vertical
## and rise against the gravity there.
func _on_launched(radius_m: float) -> void:
	var authored: float = _body.mesh.get_aabb().size.x * 0.5
	if authored > 0.0:
		_body.scale = Vector3.ONE * (radius_m / authored)
	var embers: ParticleProcessMaterial = _trail.process_material as ParticleProcessMaterial
	embers.direction = -LAGravity.acceleration_at(get_tree(), global_position).normalized()
	embers.gravity = -LABallistics.g_at(global_position).normalized() * embers.gravity.length()
	_trail.emitting = true


## The rock is freed at impact and its strike is LAMeteorImpactView's; this view stays where it struck
## until its last ember is out.
func _on_impacted(_point: Vector3, _into_water: bool) -> void:
	_body.visible = false
	_trail.emitting = false
	_picker.queue_free()
	var tree: SceneTree = get_tree()
	reparent(get_parent().get_parent())
	tree.create_timer(_trail.lifetime).timeout.connect(queue_free)


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if not get_parent() is LAMeteor:
		out.append("Draws the LAMeteor it is a child of: instance it in sim/actors/Meteor.tscn.")
	return out
