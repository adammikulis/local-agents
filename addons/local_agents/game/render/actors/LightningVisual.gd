@tool
class_name LALightningVisual
extends Node3D

## A bolt drawn where a discharge met the ground: a jagged channel down the local vertical and its flash,
## which fades over the afterglow and then frees the bolt.

@export_group("Channel")
## Height the channel is drawn down from, m above the strike point.
@export var height_m: float = 130.0
## Straight pieces the channel is drawn in.
@export var segments: int = 14
## Sideways wander of the channel's top, m.
@export var top_wander_m: float = 14.0
## Sideways jag just below the top, m; the channel straightens toward the ground.
@export var jag_m: float = 5.0
@export_group("Flash")
## Height of the flash above the strike point, m.
@export var flash_height_m: float = 6.0
## Seconds the flash takes to fade out; the bolt is freed when it has.
@export var afterglow_s: float = 0.7

@onready var _bolt: MeshInstance3D = $Bolt
@onready var _flash: OmniLight3D = $Flash

var _peak: float = 0.0
var _age: float = 0.0


func _ready() -> void:
	set_process(false)
	if Engine.is_editor_hint():
		return
	_peak = _flash.light_energy


## Draw the bolt that met the ground at `point`, along the vertical the bodies' pull defines there. With no
## body there is none to draw it along.
func strike(point: Vector3) -> void:
	var up: Vector3 = -LAGravity.acceleration_at(get_tree(), point).normalized()
	if up == Vector3.ZERO:
		push_error("LightningVisual: no gravity body at %s, so no up to draw the bolt along." % point)
		queue_free()
		return
	global_position = point
	_draw_channel(point, up)
	_flash.global_position = point + up * flash_height_m
	_flash.visible = true
	set_process(true)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_age += delta
	_flash.light_energy = _peak * maxf(0.0, 1.0 - _age / afterglow_s)
	if _age >= afterglow_s:
		queue_free()


func _draw_channel(point: Vector3, up: Vector3) -> void:
	var t1: Vector3 = up.cross(Vector3.RIGHT)
	if t1.length_squared() < 1.0e-6:
		t1 = up.cross(Vector3.FORWARD)
	t1 = t1.normalized()
	var t2: Vector3 = up.cross(t1).normalized()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = hash(point)
	var top: Vector3 = point + up * height_m + t1 * rng.randf_range(-top_wander_m, top_wander_m) \
		+ t2 * rng.randf_range(-top_wander_m, top_wander_m)
	var mesh: ImmediateMesh = _bolt.mesh as ImmediateMesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for s in range(segments + 1):
		var t: float = float(s) / float(segments)
		var p: Vector3 = top.lerp(point, t)
		var jag: float = (1.0 - t) * jag_m
		if s > 0 and s < segments:
			p += t1 * rng.randf_range(-jag, jag) + t2 * rng.randf_range(-jag, jag)
		mesh.surface_add_vertex(_bolt.to_local(p))
	mesh.surface_end()


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var bolt: MeshInstance3D = get_node_or_null("Bolt") as MeshInstance3D
	if bolt == null or not bolt.mesh is ImmediateMesh:
		out.append("Needs a Bolt MeshInstance3D holding an ImmediateMesh: the channel is drawn into it.")
	if not get_node_or_null("Flash") is OmniLight3D:
		out.append("Needs a Flash OmniLight3D: it is the light the bolt throws.")
	if segments < 1:
		out.append("Segments must be at least 1: the channel is drawn in that many straight pieces.")
	if afterglow_s <= 0.0:
		out.append("Afterglow S must be above 0: the flash fades over it before the bolt is freed.")
	return out
