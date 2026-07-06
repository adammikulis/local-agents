class_name LAVoxelDisasters
extends Node

# Natural-disaster spawning for the voxel world, factored out of the root so VoxelWorld stays a thin
# composition/harness root. Owns the volcano/lightning/meteor casts the sim and harness trigger; the
# root creates one of these in _ready and forwards its _process disaster hooks here. Dependency-free of
# the LAVoxelWorld type (dynamic access, no cyclic class reference). (Explicit types only — no ':=' .)

const MeteorScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Meteor.gd")
const VolcanoScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Volcano.gd")
const LightningScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/LightningStrike.gd")
const TornadoScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Tornado.gd")
const ThunderstormScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Thunderstorm.gd")
const HurricaneScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Hurricane.gd")

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


## A persistent tornado touches down at `point`. Its strength then lives or dies on the local warm/humid
## air it finds (see Tornado.gd) — this only births it.
func spawn_tornado(point: Vector3) -> Node:
	var t: Node = TornadoScript.new()
	_actors_root.add_child(t)
	t.setup(_terrain, _ecology)
	t.touch_down(point)
	return t


## A thunderstorm cell seeds vapor + aloft cooling at `point` so the emergent cycle builds a dense cloud
## → heavy rain, and fires lightning within its footprint while active.
func spawn_thunderstorm(point: Vector3) -> Node:
	var s: Node = ThunderstormScript.new()
	_actors_root.add_child(s)
	s.setup(_terrain, _ecology, self)
	s.begin(point)
	return s


## A hurricane spins up at `point`. It only sustains/intensifies over warm ocean and falls apart on land
## (genesis emerges from the reads); at strength it breeds embedded tornadoes + lightning.
func spawn_hurricane(point: Vector3) -> Node:
	var h: Node = HurricaneScript.new()
	_actors_root.add_child(h)
	h.setup(_terrain, _ecology, self)
	h.begin(point)
	return h


# Harness helper: fire an auto-storm of `kind` at a fitting site and return the world point to frame.
# A tornado over warm land near origin, a thunderstorm over origin, a hurricane over the nearest OPEN
# OCEAN (so its warm-ocean genesis kicks in and it can make landfall as it tracks inward).
func fire_auto_storm(kind: String) -> Vector3:
	if kind == "hurricane":
		var site: Vector3 = _find_ocean_point()
		spawn_hurricane(site)
		return site
	if kind == "thunderstorm":
		var gy: float = _terrain.surface_height(0.0, 0.0)
		var f: Vector3 = Vector3(0.0, (gy if not is_nan(gy) else 20.0), 0.0)
		spawn_thunderstorm(f)
		return f
	var oh: float = _terrain.surface_height(30.0, 30.0)
	var t: Vector3 = Vector3(30.0, (oh if not is_nan(oh) else 20.0), 30.0)
	spawn_tornado(t)
	return t


# Search rings outward for a point over open ocean (hurricane genesis). Falls back to a far offshore guess.
func _find_ocean_point() -> Vector3:
	var field = _ecology.material_field() if _ecology != null and _ecology.has_method("material_field") else null
	if field != null and field.has_method("is_ocean_at"):
		var rings: Array = [200.0, 240.0, 280.0]
		for r in rings:
			for i in range(16):
				var ang: float = TAU * float(i) / 16.0
				var px: float = cos(ang) * float(r)
				var pz: float = sin(ang) * float(r)
				if field.is_ocean_at(px, pz):
					var sea: float = field.sea_level if "sea_level" in field else 0.0
					return Vector3(px, sea, pz)
	return Vector3(0.0, 0.0, 260.0)


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
