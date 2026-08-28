class_name LAMeteorImpacts
extends Node

## The one cause that is genuinely outside the system: a rock arriving from space. It carries mass and
## momentum in at the boundary. Nothing here makes weather or geology happen, and nothing here consults
## the camera: where a rock comes down is not a function of who is watching.

const MeteorScript: GDScript = preload("res://addons/local_agents/sim/actors/Meteor.gd")

var _terrain = null
var _ecology = null
var _actors_root: Node3D = null
var _camera: Camera3D = null


func setup(terrain, ecology, actors_root: Node3D, camera: Camera3D) -> void:
	_terrain = terrain
	_ecology = ecology
	_actors_root = actors_root
	_camera = camera


## The camera is PRESENTATION — the trailer's cinematic shot casts along it. It stays null without --ui.
func set_presentation(camera: Camera3D) -> void:
	_camera = camera


## One arrival from outside. Its approach direction is drawn from the seeded planet stream and the impact
## point is that direction's own surface, so the run needs no camera and one seed lands one rock in one place.
func fire_ambient_meteor(size_scale: float = 1.0) -> void:
	var target: Vector3 = _arrival_point()
	if is_nan(target.x):
		return
	_drop(target, size_scale)


## A volley: independent arrivals, each drawn from the same stream, not a spread around one aimed point.
func fire_barrage(count: int = 18, size_scale: float = 5.5) -> void:
	for i in count:
		var target: Vector3 = _arrival_point()
		if is_nan(target.x):
			continue
		_drop(target, size_scale)


## Fling one toward `target` FROM an explicit world position. It then coasts under real N-body gravity.
func fire_meteor_at(target: Vector3, from_pos: Vector3) -> void:
	var m: MeteorScript = MeteorScript.new()
	_actors_root.add_child(m)
	m.setup(_terrain, _ecology)
	m.launch(target, from_pos)


func _drop(target: Vector3, size_scale: float) -> void:
	var m: MeteorScript = MeteorScript.new()
	_actors_root.add_child(m)
	m.setup(_terrain, _ecology)
	m.launch(target, Vector3(INF, INF, INF), size_scale)


func _arrival_point() -> Vector3:
	var nan3: Vector3 = Vector3(NAN, NAN, NAN)
	if _terrain == null or _actors_root == null:
		push_error("MeteorImpacts: no terrain for a rock to arrive at.")
		return nan3
	if not _terrain.has_method("surface_point"):
		push_error("MeteorImpacts: the terrain service resolves no surface point.")
		return nan3
	return _terrain.surface_point(_arrival_direction())


# Isotropic: rejection-sampled inside the unit ball, so no direction on the sphere is favoured.
func _arrival_direction() -> Vector3:
	var rng: LASimRng = LASimRng.for_domain("planet")
	var v: Vector3 = rng.rand_dir()
	var tries: int = 0
	while (v.length() > 1.0 or v.length() < 0.001) and tries < 32:
		v = rng.rand_dir()
		tries += 1
	if v.length() < 0.001:
		return Vector3.UP
	return v.normalized()
