class_name LAVoxelSpawnController
extends Node

## LAVoxelSpawnController — owns the INITIAL ecology/actor spawning: the "terrain ready" gate, the starting
## counts, forest/rock population, aquatic stocking, the geothermal core seed, and the persistent river
## springs (seed_water). Factored out of LAVoxelWorld so the "more actors / forests" concern is one file.
## The world composition root ticks try_spawn() each frame until the surface has meshed. (Explicit types.)

# A visibly BUSY world: land herbivores forage the emergent forests, predators/scavengers scale with the
# prey/carrion base, birds fill the sky. Far actors self-throttle via the creatures' distance-graded think
# LOD (Creature._think_stride), so a populous world stays playable — raise counts, don't cap the world small.
# Predator↔prey ratio: foxes ≈ rabbits/5, vultures track the bird/carrion base.
const INITIAL_COUNTS: Dictionary = {"plant": 260, "rabbit": 90, "fox": 10, "bird": 55, "villager": 12, "vulture": 12}
const ROCK_COUNT: int = 60
# Many forest SEEDS scattered onto the best (warm/fertile) ground; groves then DENSIFY emergently over the
# run wherever photosynthesis has built biomass (see LAEcologyService._tick_tree_seeding), thinning at the
# cold/snowy poles where the treeline gate blocks germination. Forests are a consequence of the chemistry.
const FOREST_CLUSTERS: int = 16

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
# Multiplier on the base counts below, set from the quality actor_budget (VoxelSettingsApplier.spawn_scale).
# 1.0 == the Medium preset; Low shrinks the world, High grows it. Weak GPUs run fewer actors.
var _spawn_scale: float = 1.0


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


## Scale factor applied to the base spawn counts (from the quality actor_budget). Set before the surface
## meshes so the first (and only) spawn uses it.
func set_spawn_scale(scale: float) -> void:
	_spawn_scale = maxf(0.05, scale)


## Spawn the starting ecology once terrain has streamed + collided at the surface. Idempotent — returns
## immediately once spawned. Called each frame from the world's _process. The planet is the SOLE world, so
## the old flat-island branch (caves, flat spring seeding, scripted volcano, vista framing) is gone — the
## unused view-mode params are kept only for the world's fixed call signature.
func try_spawn(_overview: bool, _farview: bool, _auto_meteor: bool, _auto_select: bool) -> void:
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
	# Radial world: ecology places life ON the sphere (surface_point spawn), fish in the sea shell; the
	# orbit camera frames the body; the planet centre is pinned hot for the radial geothermal gradient.
	_ecology.spawn_initial(_scaled_counts())
	_ecology.populate_environment(ROCK_COUNT, maxi(1, int(round(float(FOREST_CLUSTERS) * _spawn_scale))))
	if _ecology.has_method("stock_initial_aquatic"):
		_ecology.stock_initial_aquatic()
	if _camera.has_method("set_orbit_target"):
		_camera.set_orbit_target(_body.center(), _body.radius())
	if _material.has_method("add_magma_source"):
		# Geothermal core pin. NOTE: the field's thermal conduction carries this to the SURFACE far too
		# efficiently (the crust barely insulates) — at the old 1300°C pin the habitable surface baked to
		# ~110°C mean, well past creatures' 50°C lethal-heat limit, so every land animal died of heatstroke
		# within seconds of spawning (the real cause of the "ecosystem collapse", not starvation). Pinned to
		# 150°C so the ambient surface equilibrates ~28-35°C (habitable) while the radial gradient + pressure-
		# driven emergent volcanoes still function. Proper fix belongs in the field ThermalPass (crust
		# insulation / stronger surface radiative cooling so a hot core can coexist with a temperate surface).
		_material.add_magma_source(_body.center(), 150.0, 0.6)
	_spawned_initial = true
	_hud.set_status("World ready — spawn things, click to inspect, press V for scent.")


## The base counts scaled by the quality actor_budget factor (at least one of each).
func _scaled_counts() -> Dictionary:
	if is_equal_approx(_spawn_scale, 1.0):
		return INITIAL_COUNTS
	var counts: Dictionary = {}
	var total: int = 0
	for kind in INITIAL_COUNTS:
		var n: int = maxi(1, int(round(float(INITIAL_COUNTS[kind]) * _spawn_scale)))
		counts[kind] = n
		total += n
	print("SPAWN_SCALE={factor:%.2f, total:%d}" % [_spawn_scale, total])
	return counts
