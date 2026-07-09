class_name LAVoxelSpawnController
extends Node

## LAVoxelSpawnController — owns the INITIAL ecology/actor spawning: the "terrain ready" gate, the starting
## counts, forest/rock population, aquatic stocking, the geothermal core seed, and the persistent river
## springs (seed_water). Factored out of LAVoxelWorld so the "more actors / forests" concern is one file.
## The world composition root ticks try_spawn() each frame until the surface has meshed. (Explicit types.)

const INITIAL_COUNTS: Dictionary = {"plant": 70, "rabbit": 16, "fox": 3, "bird": 14, "villager": 6, "vulture": 5}
const ROCK_COUNT: int = 44
const FOREST_CLUSTERS: int = 7
const SPRING_RATE: float = 0.9              # depth per second per spring (river headwaters)

var _world: Node = null
var _body: Node3D = null
var _terrain = null
var _ecology: Node = null
var _camera: Camera3D = null
var _material: Node = null
var _hud: CanvasLayer = null
var _disasters: Node = null

var _spawned_initial: bool = false
var _ready_wait_ticks: int = 0
# Persistent springs (world XZ) seeded on high ground so rivers form downhill.
var _springs: Array = []
var _springs_seeded: bool = false


func setup(world: Node, body: Node3D, terrain, ecology: Node, camera: Camera3D, material: Node, hud: CanvasLayer, disasters: Node) -> void:
	_world = world
	_body = body
	_terrain = terrain
	_ecology = ecology
	_camera = camera
	_material = material
	_hud = hud
	_disasters = disasters


func is_spawned() -> bool:
	return _spawned_initial


## Spawn the starting ecology once terrain has streamed + collided at the surface. Idempotent — returns
## immediately once spawned. Called each frame from the world's _process.
func try_spawn(overview: bool, farview: bool, auto_meteor: bool, auto_select: bool) -> void:
	if _spawned_initial or _body == null:
		return
	# Gate on the surface being meshed. On a planet, "ready" = the top-of-planet patch has collided.
	var ready_probe: Vector3 = _body.center() + Vector3.UP * (_body.radius() + 30.0)
	if not _body.is_ready_at(ready_probe):
		return
	_ready_wait_ticks += 1
	if _ready_wait_ticks <= 6:
		return
	LASimReport.reset()
	if _terrain.is_planet():
		# Radial world: ecology places life ON the sphere (surface_point spawn), fish in the sea shell;
		# the orbit camera frames the body. Still-flat steps (caves, flat sea seeding, scripted volcano)
		# are skipped pending their radial versions (Phase B field / Phase C).
		_ecology.spawn_initial(INITIAL_COUNTS)
		_ecology.populate_environment(ROCK_COUNT, FOREST_CLUSTERS)
		if _ecology.has_method("stock_initial_aquatic"):
			_ecology.stock_initial_aquatic()
		if _camera.has_method("set_orbit_target"):
			_camera.set_orbit_target(_body.center(), _body.radius())
		# Magma CORE: pin the planet's centre hot → radial geothermal gradient.
		if _material.has_method("add_magma_source"):
			_material.add_magma_source(_body.center(), 1300.0, 0.6)
	else:
		if _terrain.has_method("carve_caves"):
			_terrain.carve_caves(1337)
		_ecology.spawn_initial(INITIAL_COUNTS)
		_ecology.populate_environment(ROCK_COUNT, FOREST_CLUSTERS)
		_seed_water()
		if _ecology.has_method("stock_initial_aquatic"):
			_ecology.stock_initial_aquatic()
		_disasters.spawn_default_volcano()
		if overview and _camera.has_method("frame_overview"):
			var ohv: float = _terrain.surface_height(0.0, 0.0)
			_camera.frame_overview(Vector3(0.0, (ohv if not is_nan(ohv) else 20.0), 0.0), 1250.0 if farview else 360.0)
		elif not auto_meteor and not auto_select and _camera.has_method("frame_vista"):
			var oh: float = _terrain.surface_height(0.0, 0.0)
			if not is_nan(oh):
				_camera.frame_vista(Vector3(0.0, oh, 0.0))
	_spawned_initial = true
	_hud.set_status("World ready — spawn things, click to inspect, press V for scent.")


## Sync the terrain shader's beach/snow bands to the island's sea level and register a few high interior
## peaks as PERSISTENT springs on the field (the 3D field injects them itself each step) so rivers run
## downhill to the coast and drain into the ocean (continuous water). One-shot.
func _seed_water() -> void:
	if _material == null or _terrain == null:
		return
	# The terrain was shaped around a fixed sea level (the field already has it from setup); sync the shader.
	var sea: float = _terrain.sea_level() if _terrain.has_method("sea_level") else 0.0
	if _terrain.has_method("set_shader_param"):
		_terrain.set_shader_param("sea_level", sea)
		# Snow only lightly caps the very highest hilltops (the isle tops out ~78 above a sea of ~6), so
		# the island reads green with rocky slopes rather than a snowfield.
		_terrain.set_shader_param("snow_height", sea + 66.0)
	# Sample interior rings and take the highest points as spring heads (headwaters up on the island so
	# streams flow the full length down to the sea). Must be clearly above the sea to feed real rivers.
	var candidates: Array = []
	var rings: Array = [50.0, 95.0, 140.0]
	var per: int = 8
	for ri in range(rings.size()):
		var r: float = float(rings[ri])
		for i in range(per):
			var ang: float = TAU * float(i) / float(per) + float(ri) * 0.7   # stagger rings
			var px: float = cos(ang) * r
			var pz: float = sin(ang) * r
			var h: float = _terrain.surface_height(px, pz)
			if not is_nan(h) and h > sea + 25.0:
				candidates.append({"pos": Vector3(px, h, pz), "h": h})
	candidates.sort_custom(func(a, b): return float(a["h"]) > float(b["h"]))
	_springs.clear()
	for i in range(mini(4, candidates.size())):
		_springs.append(candidates[i]["pos"])
	# Register each spring ONCE as a persistent source; the 3D field injects it internally every step
	# (modest headwaters — streams/ponds, not a flooded interior).
	if _material.has_method("add_source"):
		for p in _springs:
			_material.add_source(p, 0.8)
	_springs_seeded = true
