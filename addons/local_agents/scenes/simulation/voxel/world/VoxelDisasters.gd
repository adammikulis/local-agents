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


## Seed a volcano on the SEABED — a vent whose surface sits BELOW the sea shell (an ocean basin). Its sustained
## lava supply then quenches underwater, solidifies, accretes and (given a long run) BREACHES the surface as a new
## island — the capstone. Searches radial directions for the DEEPEST sea floor well below sea level, PREFERRING the
## sunlit hemisphere (`sun_dir`, planet->sun) so the emerging island is well lit for the demo; falls back to the
## deepest sampled point. Returns [volcano_node, world_vent_point] so the harness can frame + prove it.
func spawn_sea_volcano(sun_dir: Vector3 = Vector3.ZERO) -> Array:
	if _terrain == null or not _terrain.has_method("planet_center") or not _terrain.has_method("sea_radius"):
		return [null, Vector3.ZERO]
	var center: Vector3 = _terrain.planet_center()
	var sea_r: float = _terrain.sea_radius()
	var lit: bool = sun_dir.length() > 0.01
	var best_dir: Vector3 = Vector3.ZERO
	var best_score: float = -1.0                 # depth below sea, biased toward the lit side
	var best_depth: float = 0.0
	# Sample a fibonacci-ish spread of directions on the sphere; keep the deepest submerged floor, favouring daylight.
	for i in range(160):
		var u: float = (float(i) + 0.5) / 160.0
		var phi: float = acos(1.0 - 2.0 * u)
		var theta: float = float(i) * 2.399963              # golden angle
		var dir: Vector3 = Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta)).normalized()
		var sr: float = _terrain.surface_radius(dir)
		if is_nan(sr):
			continue
		var depth: float = sea_r - sr                       # >0 means the floor is under the sea (a basin)
		if depth <= 2.0:
			continue                                        # not a genuine basin
		var facing: float = dir.dot(sun_dir) if lit else 0.0
		if lit and facing <= 0.15:
			continue                                        # skip the night side so the island renders lit
		var score: float = depth + facing * 8.0             # deep AND sunward preferred
		if score > best_score:
			best_score = score
			best_dir = dir
			best_depth = depth
	if best_dir == Vector3.ZERO and lit:
		return spawn_sea_volcano(Vector3.ZERO)               # no lit basin — retry without the daylight constraint
	if best_dir == Vector3.ZERO:
		return [null, Vector3.ZERO]                          # no genuine seabed basin found at all
	var floor_r: float = sea_r - best_depth
	var vent: Vector3 = center + best_dir * floor_r
	var v: Node = spawn_volcano(vent)
	return [v, vent]


## A persistent tornado touches down at `point`. Its strength then lives or dies on the local warm/humid
## air it finds (see Tornado.gd) — this only births it.
func spawn_tornado(point: Vector3) -> Node:
	var t: Node = TornadoScript.new()
	_actors_root.add_child(t)
	t.setup(_terrain, _ecology)
	t.touch_down(point)
	return t


## A thunderstorm cell seeds vapor + surface heat + aloft cooling at `point` so the emergent cycle builds a
## dense cloud → heavy rain; lightning then emerges from MaterialCharge3D as the cloud charges to breakdown
## (the cell no longer spawns bolts itself — it only seeds the ingredients).
func spawn_thunderstorm(point: Vector3) -> Node:
	var s: Node = ThunderstormScript.new()
	_actors_root.add_child(s)
	s.setup(_terrain, _ecology)
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
# OCEAN (so its warm-ocean genesis kicks in and it can make landfall as it tracks inward). The camera
# is set to FOLLOW the spawned storm (it wanders) at a framing distance sized to the storm, so it stays
# in shot — see LAVoxelCameraRig.track_target / stop_tracking.
func fire_auto_storm(kind: String) -> Vector3:
	if kind == "hurricane":
		var site: Vector3 = _find_ocean_point()
		var h: Node = spawn_hurricane(site)
		_track_storm(h, 360.0, 42.0)          # huge system — pull way back
		return site
	if kind == "thunderstorm":
		var gy: float = _terrain.surface_height(0.0, 0.0)
		var f: Vector3 = Vector3(0.0, (gy if not is_nan(gy) else 20.0), 0.0)
		var s: Node = spawn_thunderstorm(f)
		_track_storm(s, 155.0, 34.0)
		return f
	var oh: float = _terrain.surface_height(30.0, 30.0)
	var t: Vector3 = Vector3(30.0, (oh if not is_nan(oh) else 20.0), 30.0)
	var tw: Node = spawn_tornado(t)
	_track_storm(tw, 110.0, 30.0)             # frame the whole funnel column
	return t


# Point the camera at a live storm so it stays framed as the storm wanders (no-op if the rig lacks the
# follow API). Distance/pitch are sized per storm; the rig eases in and follows every frame.
func _track_storm(storm: Node, distance: float, pitch_deg: float) -> void:
	if storm is Node3D and _camera != null and _camera.has_method("track_target"):
		_camera.track_target(storm as Node3D, distance, pitch_deg)


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
