@tool
class_name LALightningView
extends LAEventView

## A bolt drawn where a discharge met the ground: a jagged channel down the local vertical, its flash and its thunder.

@export_group("Channel")
## Height the channel is drawn down from, m above the strike point.
@export var height_m: float = 130.0
## Straight pieces the channel is drawn in.
@export var segments: int = 14
## Sideways wander of the channel's top, m.
@export var top_wander_m: float = 14.0
## Sideways jag just below the top, m; the channel straightens toward the ground.
@export var jag_m: float = 5.0
@export_group("Sound")
## Played where the bolt strikes.
@export var sfx: String = "thunder"

@onready var _bolt: MeshInstance3D = $Bolt


## `observation` carries "pos", where the charge-breakdown kernel published the strike.
func show_event(observation: Dictionary) -> void:
	var point: Vector3 = observation["pos"]
	if stand_at(point) == Vector3.ZERO:
		finish()
		return
	_draw_channel(hash(point))
	LAAudioDirector.emit(get_tree(), sfx, point)


## The channel in the view's own frame, Y up the local vertical, from its wandering top down to the strike.
func _draw_channel(seed_value: int) -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	var top: Vector3 = Vector3(rng.randf_range(-top_wander_m, top_wander_m), height_m,
		rng.randf_range(-top_wander_m, top_wander_m))
	var mesh: ImmediateMesh = _bolt.mesh as ImmediateMesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for s in range(segments + 1):
		var t: float = float(s) / float(segments)
		var jag: float = (1.0 - t) * jag_m if s > 0 and s < segments else 0.0
		mesh.surface_add_vertex(top.lerp(Vector3.ZERO, t)
			+ Vector3(rng.randf_range(-jag, jag), 0.0, rng.randf_range(-jag, jag)))
	mesh.surface_end()


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = super()
	var bolt: MeshInstance3D = get_node_or_null("Bolt") as MeshInstance3D
	if bolt == null or not bolt.mesh is ImmediateMesh:
		out.append("Needs a Bolt MeshInstance3D holding an ImmediateMesh: the channel is drawn into it.")
	if segments < 1:
		out.append("Segments must be at least 1: the channel is drawn in that many straight pieces.")
	if lifetime_s <= 0.0:
		out.append("Lifetime S must be above 0: the flash fades over it before the bolt is freed.")
	return out
