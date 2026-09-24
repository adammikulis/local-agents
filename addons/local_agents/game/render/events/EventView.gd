@tool
@abstract
class_name LAEventView
extends Node3D

## What every drawn event shares: a light, a particle system and a lifetime, under one LAAblate switch.

@export_group("Event")
## The LAAblate switch every view of this kind stands under.
@export var ablation_name: String = ""
## Seconds a shown event stands, its light fading out over them; 0 stands until finish().
@export var lifetime_s: float = 0.0

@onready var light: OmniLight3D = $Light
@onready var particles: GPUParticles3D = $Particles

var _age: float = 0.0
var _peak: float = -1.0


## Draw the event `observation` reports; its "pos" is where it happened, in world coordinates.
@abstract func show_event(observation: Dictionary) -> void


## Stand the view at `point`, its Y axis up the local vertical. ZERO, and not stood, where nothing pulls.
func stand_at(point: Vector3) -> Vector3:
	if not point.is_finite():
		return Vector3.ZERO
	var up: Vector3 = -LABallistics.g_at(point).normalized()
	if up == Vector3.ZERO:
		return Vector3.ZERO
	var side: Vector3 = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	global_transform = Transform3D(Basis(side, up, side.cross(up)), point)
	return up


## Retire the event: the light goes out, the particles stop, and the view frees once the last is down.
func finish() -> void:
	light.visible = false
	if not particles.emitting:
		queue_free()
		return
	particles.emitting = false
	get_tree().create_timer(particles.lifetime).timeout.connect(queue_free)


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or lifetime_s <= 0.0 or _age >= lifetime_s:
		return
	if _peak < 0.0:
		_peak = light.light_energy
	_age += delta
	light.light_energy = _peak * maxf(0.0, 1.0 - _age / lifetime_s)
	if _age >= lifetime_s:
		finish()


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if not get_node_or_null("Light") is OmniLight3D or not get_node_or_null("Particles") is GPUParticles3D:
		out.append("Needs a Light OmniLight3D and a Particles GPUParticles3D: inherit EventView.tscn.")
	if ablation_name.is_empty():
		out.append("Ablation Name is empty: no LAAblate switch answers for this kind of event.")
	if lifetime_s < 0.0:
		out.append("Lifetime S is negative: 0 stands until finish(), above 0 fades and frees.")
	return out
