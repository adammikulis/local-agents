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
const INITIAL_COUNTS: Dictionary = {"plant": 150, "rabbit": 70, "fox": 14, "bird": 45, "villager": 14, "vulture": 16}
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
	_ecology.spawn_initial(INITIAL_COUNTS)
	_ecology.populate_environment(ROCK_COUNT, FOREST_CLUSTERS)
	if _ecology.has_method("stock_initial_aquatic"):
		_ecology.stock_initial_aquatic()
	if _camera.has_method("set_orbit_target"):
		_camera.set_orbit_target(_body.center(), _body.radius())
	if _material.has_method("add_magma_source"):
		_material.add_magma_source(_body.center(), 1300.0, 0.6)
	_spawned_initial = true
	_hud.set_status("World ready — spawn things, click to inspect, press V for scent.")
