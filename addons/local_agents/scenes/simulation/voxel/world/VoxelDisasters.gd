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
const EarthquakeScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Earthquake.gd")

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
	if _terrain == null or not _terrain.has_method("surface_point"):
		return
	# Pick the HIGHEST (largest surface radius) of a ring of directions tilted off the pole — a mountain landmark.
	var best_r: float = -INF
	var best: Vector3 = Vector3(NAN, NAN, NAN)
	var ring: int = 12
	for i in range(ring):
		var ang: float = TAU * float(i) / float(ring)
		var dir: Vector3 = Vector3(cos(ang) * 0.5, 1.0, sin(ang) * 0.5).normalized()
		var sr: float = _terrain.surface_radius(dir)
		if is_nan(sr) or sr <= best_r:
			continue
		best_r = sr
		best = _terrain.surface_point(dir)
	if not is_nan(best.x):
		spawn_volcano(best)


# A world-space surface spawn point along a direction from the planet centre (falls back to the sea shell
# along that direction if that patch is unmeshed). The radial replacement for the old fixed-XZ surface_height picks.
func _surface_spawn(dir: Vector3) -> Vector3:
	if _terrain != null and _terrain.has_method("surface_point"):
		var sp: Vector3 = _terrain.surface_point(dir)
		if not is_nan(sp.x):
			return sp
	var c: Vector3 = _terrain.planet_center() if _terrain != null and _terrain.has_method("planet_center") else Vector3.ZERO
	var sea_r: float = _terrain.sea_radius() if _terrain != null and _terrain.has_method("sea_radius") else 100.0
	return c + dir.normalized() * sea_r


## Rupture an earthquake at `point`: it releases one seismic pulse into the shared shock field (the propagating
## wave IS the quake — camera shake + wildlife panic emerge from it). Used by plate tectonics at fault boundaries.
func spawn_earthquake(point: Vector3) -> Node:
	var q: Node = EarthquakeScript.new()
	_actors_root.add_child(q)
	q.setup(_terrain, _ecology)
	q.rupture(point)
	return q


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
## (genesis emerges from the reads); its eyewall pump builds charge so embedded lightning emerges from the
## field's own charge physics (no scripted breeding).
func spawn_hurricane(point: Vector3) -> Node:
	var h: Node = HurricaneScript.new()
	_actors_root.add_child(h)
	h.setup(_terrain, _ecology)
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
		var f: Vector3 = _surface_spawn(Vector3.UP)
		var s: Node = spawn_thunderstorm(f)
		_track_storm(s, 155.0, 34.0)
		return f
	var t: Vector3 = _surface_spawn(Vector3(0.3, 1.0, 0.3).normalized())
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
	var center: Vector3 = _terrain.planet_center() if _terrain != null and _terrain.has_method("planet_center") else Vector3.ZERO
	var sea_r: float = _terrain.sea_radius() if _terrain != null and _terrain.has_method("sea_radius") else 0.0
	if field != null and field.has_method("is_ocean_at") and sea_r > 0.0:
		# Scan a spread of radial directions for a sea-surface point over an ocean basin (a golden-angle spiral).
		for i in range(200):
			var u: float = (float(i) + 0.5) / 200.0
			var phi: float = acos(1.0 - 2.0 * u)
			var theta: float = float(i) * 2.399963
			var dir: Vector3 = Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta)).normalized()
			var pt: Vector3 = center + dir * sea_r
			if field.is_ocean_at(pt):
				return pt
	return center + Vector3.UP * (sea_r if sea_r > 0.0 else 260.0)


func spawn_lightning(point: Vector3) -> void:
	var b: Node = LightningScript.new()
	_actors_root.add_child(b)
	b.setup(_terrain, _ecology)
	b.strike(point)
	if _audio != null:
		_audio.play_sfx("thunder", point)


# A bolt at a random point in the play area (thunderstorm occurrence).
func strike_random_lightning() -> void:
	if _terrain == null or not _terrain.has_method("surface_point"):
		return
	var dir: Vector3 = Vector3(randf() * 2.0 - 1.0, randf() * 2.0 - 1.0, randf() * 2.0 - 1.0)
	if dir.length_squared() < 1.0e-4:
		dir = Vector3.UP
	var sp: Vector3 = _terrain.surface_point(dir.normalized())
	if not is_nan(sp.x):
		spawn_lightning(sp)


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


## Rain a BARRAGE of large meteors onto the camera-aimed region — bombard the planet to expose its deep
## geology (crust -> mantle -> magma) and, with enough hits, fracture it to pieces. Concentrated (small
## spread) so the impacts STACK into a deep crater rather than scattering shallowly; each rock is size-scaled
## big so a single volley digs toward the mantle.
func fire_barrage(count: int = 18, size_scale: float = 5.5, spread: float = 20.0) -> void:
	if _camera == null or _terrain == null:
		return
	var ray: Dictionary = _camera.aim_ray()
	var hit: Dictionary = _terrain.raycast_terrain(ray["origin"], ray["dir"], 3000.0)
	if not bool(hit.get("hit", false)):
		return
	var impact: Vector3 = hit["position"]
	for i in count:
		var j: Vector3 = Vector3(randf() * 2.0 - 1.0, randf() * 2.0 - 1.0, randf() * 2.0 - 1.0) * spread
		var m: MeteorScript = MeteorScript.new()
		_actors_root.add_child(m)
		m.setup(_terrain, _ecology)
		m.launch(impact + j, _camera.global_position + j * 4.0, size_scale)
	_world.set_destruction(1.0)


## Fling a meteor toward `target` FROM an explicit world position (the trailer director aims one in from the
## frame edge). It then coasts under real N-body gravity like any launched meteor.
func fire_meteor_at(target: Vector3, from_pos: Vector3) -> void:
	var m: MeteorScript = MeteorScript.new()
	_actors_root.add_child(m)
	m.setup(_terrain, _ecology)
	m.launch(target, from_pos)
