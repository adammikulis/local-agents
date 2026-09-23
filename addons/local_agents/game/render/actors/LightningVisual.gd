@tool
class_name LALightningVisual
extends Node3D

## A bolt drawn: a jagged channel down the local vertical to where the discharge met the ground, and its flash.

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

@onready var _bolt: MeshInstance3D = $Bolt
@onready var _flash: OmniLight3D = $Flash

var _strike: LALightningStrike = null
var _peak: float = 0.0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_peak = _flash.light_energy
	_strike = get_parent() as LALightningStrike
	if _strike != null:
		_strike.struck.connect(_on_struck)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or _strike == null:
		return
	_flash.light_energy = _peak * _strike.remaining()


## The channel runs down the vertical the bodies' pull defines; with no body there is none to draw it along.
func _on_struck(point: Vector3) -> void:
	var up: Vector3 = -LAGravity.acceleration_at(get_tree(), point).normalized()
	if up == Vector3.ZERO:
		push_error("LightningVisual: no gravity body at %s, so no up to draw the bolt along." % point)
		return
	_draw_channel(point, up)
	_flash.global_position = point + up * flash_height_m
	_flash.visible = true


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
	if not get_parent() is LALightningStrike:
		out.append("Draws the LALightningStrike it is a child of: instance it in sim/actors/LightningStrike.tscn.")
	var bolt: MeshInstance3D = get_node_or_null("Bolt") as MeshInstance3D
	if bolt == null or not bolt.mesh is ImmediateMesh:
		out.append("Needs a Bolt MeshInstance3D holding an ImmediateMesh: the channel is drawn into it.")
	if segments < 1:
		out.append("Segments must be at least 1: the channel is drawn in that many straight pieces.")
	return out
