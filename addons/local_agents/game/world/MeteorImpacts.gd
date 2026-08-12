class_name LAMeteorImpacts
extends Node

## The one cause that is genuinely outside the system: a rock arriving from space. It carries mass and
## momentum in at the boundary. Nothing here makes weather or geology happen.

const MeteorScript: GDScript = preload("res://addons/local_agents/sim/actors/Meteor.gd")

var _world = null            # LAVoxelWorld (dynamic; method calls only)
var _terrain = null
var _ecology = null
var _actors_root: Node3D = null
var _camera: Camera3D = null


func setup(world, terrain, ecology, actors_root: Node3D, camera: Camera3D) -> void:
	_world = world
	_terrain = terrain
	_ecology = ecology
	_actors_root = actors_root
	_camera = camera


## The camera is PRESENTATION — the screen-ray casts. It stays null without --ui.
func set_presentation(camera: Camera3D) -> void:
	_camera = camera


# Aim one at the nearest tree so the impact hits vegetation, else at the point under the camera's aim.
func fire_test_meteor() -> void:
	var impact: Vector3 = Vector3.ZERO
	var found: bool = false
	var best: float = INF
	for t in get_tree().get_nodes_in_group("tree"):
		if t is Node3D:
			var d: float = (_camera.global_position - (t as Node3D).global_position).length()
			if d < best:
				best = d
				impact = (t as Node3D).global_position
				found = true
	if not found:
		var ray: Dictionary = _camera.aim_ray()
		var hit: Dictionary = _terrain.raycast_terrain(ray["origin"], ray["dir"], 3000.0)
		if not bool(hit.get("hit", false)):
			return
		impact = hit["position"]
	var m: MeteorScript = MeteorScript.new()
	_actors_root.add_child(m)
	m.setup(_terrain, _ecology)
	m.launch(impact, _camera.global_position)
	_world.set_destruction(1.0)
	_world.mark_auto_meteor_fired()
	if _camera.has_method("focus_on"):
		_camera.focus_on(impact)
	else:
		_camera.global_position = impact + Vector3(26.0, 30.0, 26.0)
		_camera.look_at(impact, Vector3.UP)


func fire_barrage(count: int = 18, size_scale: float = 5.5, spread: float = 20.0) -> void:
	if _camera == null or _terrain == null:
		return
	var ray: Dictionary = _camera.aim_ray()
	var hit: Dictionary = _terrain.raycast_terrain(ray["origin"], ray["dir"], 3000.0)
	if not bool(hit.get("hit", false)):
		return
	var impact: Vector3 = hit["position"]
	for i in count:
		var j: Vector3 = LASimRng.shared().rand_dir() * spread
		var m: MeteorScript = MeteorScript.new()
		_actors_root.add_child(m)
		m.setup(_terrain, _ecology)
		m.launch(impact + j, _camera.global_position + j * 4.0, size_scale)
	_world.set_destruction(1.0)


## Fling one toward `target` FROM an explicit world position. It then coasts under real N-body gravity.
func fire_meteor_at(target: Vector3, from_pos: Vector3) -> void:
	var m: MeteorScript = MeteorScript.new()
	_actors_root.add_child(m)
	m.setup(_terrain, _ecology)
	m.launch(target, from_pos)
