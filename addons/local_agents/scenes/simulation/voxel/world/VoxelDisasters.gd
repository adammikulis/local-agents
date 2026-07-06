class_name LAVoxelDisasters
extends Node

# Natural-disaster spawning for the voxel world, factored out of the root so VoxelWorld stays a thin
# composition/harness root. Owns the volcano/lightning/meteor casts the sim and harness trigger; the
# root creates one of these in _ready and forwards its _process disaster hooks here. Dependency-free of
# the LAVoxelWorld type (dynamic access, no cyclic class reference). (Explicit types only — no ':=' .)

const MeteorScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Meteor.gd")
const VolcanoScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Volcano.gd")
const LightningScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/LightningStrike.gd")

var _world = null            # LAVoxelWorld (dynamic; method calls only)
var _terrain = null
var _ecology = null
var _actors_root: Node3D = null
var _camera: Camera3D = null
var _audio = null


func setup(world, terrain, ecology, actors_root: Node3D, camera: Camera3D, audio) -> void:
	_world = world
	_terrain = terrain
	_ecology = ecology
	_actors_root = actors_root
	_camera = camera
	_audio = audio


# The world always has one active volcano — placed on the highest of several sampled points so it's a
# proper mountain landmark, well away from the origin spawn.
func spawn_default_volcano() -> void:
	var best_h: float = -INF
	var best: Vector3 = Vector3(150.0, 0.0, 150.0)
	var ring: int = 12
	for i in range(ring):
		var ang: float = TAU * float(i) / float(ring)
		var r: float = 160.0
		var px: float = cos(ang) * r
		var pz: float = sin(ang) * r
		var h: float = _terrain.surface_height(px, pz)
		if not is_nan(h) and h > best_h:
			best_h = h
			best = Vector3(px, h, pz)
	if best_h > -INF:
		spawn_volcano(best)


func spawn_volcano(point: Vector3) -> Node:
	var v: Node = VolcanoScript.new()
	_actors_root.add_child(v)
	v.setup(_terrain, _ecology)
	v.erupt_at(point)
	return v


func spawn_lightning(point: Vector3) -> void:
	var b: Node = LightningScript.new()
	_actors_root.add_child(b)
	b.setup(_terrain, _ecology)
	b.strike(point)
	if _audio != null:
		_audio.play_sfx("thunder", point)


# A bolt at a random point in the play area (thunderstorm occurrence).
func strike_random_lightning() -> void:
	var ang: float = randf() * TAU
	var r: float = randf() * 250.0
	var px: float = cos(ang) * r
	var pz: float = sin(ang) * r
	var h: float = _terrain.surface_height(px, pz)
	if not is_nan(h):
		spawn_lightning(Vector3(px, h, pz))


# Strike the nearest tree (test: confirm fire emerges from the bolt's heat).
func fire_test_lightning() -> void:
	var best: float = INF
	var impact: Vector3 = Vector3.ZERO
	var found: bool = false
	for t in get_tree().get_nodes_in_group("tree"):
		if t is Node3D:
			var d: float = (_camera.global_position - (t as Node3D).global_position).length()
			if d < best:
				best = d
				impact = (t as Node3D).global_position
				found = true
	if found:
		spawn_lightning(impact)


# Launch a test meteor at the nearest tree (so it hits vegetation and can start a fire),
# falling back to the point under the camera's aim if there are no trees.
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
