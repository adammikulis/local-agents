class_name LASimWorld
extends Node3D

## LASimWorld — the ONE-node facade for a self-contained ecosystem sim. Drop it in, pick a `world_type`
## (SPHERE planet or FLAT box), set its bounds, and call spawn_world() (or let it auto-run on _ready). It
## COMPOSES the existing controllers behind a tiny export surface — it does NOT reimplement their logic:
##   - SPHERE : LAPlanetBody.setup({radius,…}) → its LAVoxelTerrainService → LAMaterialField3D.setup_sphere
##              over a LASphereGrid shell; ecology places life ON the sphere; a sun drives the field.
##   - FLAT   : an LAFlatGroundTerrain plane + LAMaterialField3D.setup_dims (an origin box volume); ecology
##              scatters life across the flat extent.
## Both share LAEcologyService.setup() (spawning, population dynamics, breeding) and the creature/agent
## nodes. This keeps the composition-root wiring OUT of the game shell (VoxelWorld) so a library user gets a
## planet or a flat sandbox in one node, with no HUD/camera/disaster/save machinery.
##
## The heavy hubs stay untouched: LASimWorld only INSTANTIATES + WIRES controllers (composition root), it adds
## no behaviour to LAMaterialField3D / VoxelWorld. (Explicit types only — project rule: no ':=' inferred typing.)

enum WorldType { SPHERE, FLAT }

const PlanetBodyScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/system/PlanetBody.gd")
const SphereGridScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/sphere/SphereGrid.gd")
const MaterialFieldScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialField3D.gd")
const EcologyServiceScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ecology/EcologyService.gd")
const FlatTerrainScript: GDScript = preload("res://addons/local_agents/creatures/terrain/adapters/FlatGroundTerrain.gd")

# --- Headline: which substrate this world is. Everything below splits on it. ---
@export var world_type: WorldType = WorldType.SPHERE

# --- SPHERE bounds (used when world_type == SPHERE) ---------------------------------------------
@export_group("Sphere bounds")
## Mean solid radius of the planet (world units). Relief/feature/field-shell all scale with this.
@export var radius: float = 250.0
## Extra land bias: higher = more land above the sea shell (0 ≈ Earth-like ocean fraction).
@export var ocean_bias: float = 3.0
## Per-cube-face field resolution (8..64). Higher = finer field grid but more GPU cost.
@export_range(8, 64, 1) var grid_res: int = 20
## Radial shell depth of the field (crust + atmosphere layers).
@export_range(8, 32, 1) var grid_depth: int = 20
## Carve emergent cave tunnels into the crust.
@export var caves_enabled: bool = true
## Reserved: drive the ocean tidal cycle. The bare facade builds no ocean shell, so this is informational
## until an ocean controller is wired; kept as a first-class export so the world surface is stable.
@export var tides_enabled: bool = false

# --- FLAT bounds (used when world_type == FLAT) --------------------------------------------------
@export_group("Flat bounds")
## Box extent (world units) of the flat world's field volume: width (x) × height (y) × depth (z).
@export var flat_extent: Vector3 = Vector3(120.0, 40.0, 120.0)
## Field cell size (world units). extent / cell_size cells per axis.
@export var flat_cell_size: float = 5.0
## World Y of the flat ground plane creatures stand on.
@export var ground_y: float = 0.0

# --- Shared ------------------------------------------------------------------------------------
@export_group("Population")
## Spawn the starting ecology automatically once the world is built + ready.
@export var auto_spawn: bool = true
## Starting per-kind counts. Empty → DEFAULT_COUNTS below.
@export var initial_counts: Dictionary = {}
## Forest seed clusters (SPHERE only; FLAT scatters plants flat instead).
@export var forest_clusters: int = 6
## Build the world automatically in _ready. Turn off to call spawn_world() yourself.
@export var build_on_ready: bool = true

# A small, lively founding stock for a demo world (kept modest so it boots fast).
const DEFAULT_COUNTS: Dictionary = {"rabbit": 14, "fox": 3, "bird": 10, "plant": 40}

var _body = null                 # LAPlanetBody (SPHERE mode)
var _terrain = null              # LAVoxelTerrainService (sphere) or LAFlatGroundTerrain (flat)
var _material = null             # LAMaterialField3D
var _ecology = null              # LAEcologyService
var _actors_root: Node3D = null
var _sun: DirectionalLight3D = null

var _built: bool = false
var _spawned: bool = false
var _ready_ticks: int = 0
# Headless / off-screen harness: `-- --run-frames=N` counts frames then prints a report + quits.
var _run_frames: int = 0
var _frame: int = 0


func _ready() -> void:
	_parse_run_frames()
	if build_on_ready:
		spawn_world()


## Build the chosen substrate + ecology. Idempotent (a second call is a no-op). After this, life spawns
## either automatically (auto_spawn) via the per-frame ready-gate, or when you call spawn_life() yourself.
func spawn_world() -> void:
	if _built:
		return
	_built = true
	if world_type == WorldType.SPHERE:
		_build_sphere()
	else:
		_build_flat()
	# Ecology is shared by both modes: it drives spawning + population dynamics against the duck-typed terrain.
	_ecology = EcologyServiceScript.new()
	_ecology.name = "Ecology"
	add_child(_ecology)
	_ecology.setup(_terrain, _actors_root)
	if _ecology.has_method("set_material_field"):
		_ecology.set_material_field(_material)


# --- SPHERE substrate --------------------------------------------------------------------------
func _build_sphere() -> void:
	var scale: float = radius / 250.0                 # the sphere knobs were tuned at radius 250
	_body = PlanetBodyScript.new()
	_body.name = "PlanetBody"
	add_child(_body)
	_body.setup({
		"radius": radius, "sea_radius": radius, "ocean_bias": ocean_bias,
		"relief": 28.0 * scale, "feature_size": 155.0 * scale,
		"basin_relief": 12.0 * scale, "basin_size": 130.0 * scale,
		"ridge_relief": 4.0 * scale, "ridge_size": 95.0 * scale, "ridge_octaves": 2,
		"detail_relief": 1.0 * scale,
		"caves_enabled": caves_enabled, "cave_size": 60.0 * scale, "cave_threshold": 0.09,
		"cave_strength": 40.0, "cave_depth_fade": 14.0 * scale,
		"tides_enabled": tides_enabled, "view_distance": 2000, "seed": 1337,
	})
	_terrain = _body.terrain()
	_actors_root = _body.actors_root
	# A sun so the field's solar/thermal pass has a real light (drives heating → biomass). Fixed in space.
	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.rotation = Vector3(-0.9, 0.4, 0.0)
	add_child(_sun)
	# Cubed-sphere field shell enclosing the planet (crust + atmosphere), scaled with the radius.
	_material = MaterialFieldScript.new()
	_material.name = "MaterialField"
	add_child(_material)
	var grid: RefCounted = SphereGridScript.new()
	grid.build(grid_res, grid_depth, 170.0 * scale, 8.0 * scale, _body.center())
	_material.setup_sphere(grid, _terrain)
	if _material.has_method("sample_solidity"):
		_material.sample_solidity()
	if _material.has_method("set_sun"):
		_material.set_sun(_sun)


# --- FLAT substrate ----------------------------------------------------------------------------
func _build_flat() -> void:
	_terrain = FlatTerrainScript.new(ground_y)
	_actors_root = Node3D.new()
	_actors_root.name = "Actors"
	add_child(_actors_root)
	_material = MaterialFieldScript.new()
	_material.name = "MaterialField"
	add_child(_material)
	# Box field volume centred on the extent, its floor at ground_y. setup_dims allocates the box channels +
	# wires the CPU box-step (heat diffuses/rises) — no planet, no GPU kernels.
	var dx: int = maxi(1, int(round(flat_extent.x / flat_cell_size)))
	var dy: int = maxi(1, int(round(flat_extent.y / flat_cell_size)))
	var dz: int = maxi(1, int(round(flat_extent.z / flat_cell_size)))
	var origin: Vector3 = Vector3(-0.5 * flat_extent.x, ground_y, -0.5 * flat_extent.z)
	_material.setup_dims(dx, dy, dz, flat_cell_size, origin)


# --- Spawning ----------------------------------------------------------------------------------
func _process(_delta: float) -> void:
	if _built and not _spawned and auto_spawn:
		_try_spawn_life()
	if _run_frames > 0:
		_frame += 1
		if _frame == _run_frames:
			_emit_report_and_quit()


## Spawn the starting ecology now (bypassing the auto gate). Safe to call once the world is built.
func spawn_life() -> void:
	if not _built or _spawned:
		return
	_spawned = true
	var counts: Dictionary = initial_counts if not initial_counts.is_empty() else DEFAULT_COUNTS
	if world_type == WorldType.SPHERE:
		_ecology.spawn_initial(counts)
		_ecology.populate_environment(0, forest_clusters)
	else:
		_scatter_flat(counts)


# SPHERE spawns wait for the top-of-planet patch to mesh + collide (like the game's spawn controller); FLAT
# ground is always ready, so it spawns at once. A few settle ticks avoid spawning into a half-meshed surface.
func _try_spawn_life() -> void:
	if world_type == WorldType.SPHERE:
		if _body == null:
			return
		var probe: Vector3 = _body.center() + _body.up_at(_body.center() + Vector3.UP) * (_body.radius() + 30.0)
		if not _body.is_ready_at(_body.center() + Vector3.UP * (_body.radius() + 30.0)):
			return
		_ready_ticks += 1
		if _ready_ticks <= 6:
			return
	spawn_life()


# FLAT scatter: place each kind at random points within the flat extent, just above the ground plane, via the
# ecology's public spawn() (which projects onto the flat terrain). Bounded to the extent — the sphere random
# sampler is unsuitable for a plane, so a plane world scatters flat here instead.
func _scatter_flat(counts: Dictionary) -> void:
	var hx: float = 0.45 * flat_extent.x
	var hz: float = 0.45 * flat_extent.z
	for kind_v in counts.keys():
		var kind: String = String(kind_v)
		var n: int = int(counts[kind_v])
		for i in range(n):
			var p: Vector3 = Vector3(randf_range(-hx, hx), ground_y + 2.0, randf_range(-hz, hz))
			_ecology.spawn(kind, p)


# --- Accessors (for a host that wires a camera / HUD onto the facade) ----------------------------
func material_field(): return _material
func ecology(): return _ecology
func terrain(): return _terrain
func planet_body(): return _body
func actors_root() -> Node3D: return _actors_root


# --- Headless run-frames harness ---------------------------------------------------------------
func _parse_run_frames() -> void:
	for arg in OS.get_cmdline_user_args():
		if String(arg).begins_with("--run-frames="):
			_run_frames = maxi(0, int(String(arg).get_slice("=", 1)))


func _emit_report_and_quit() -> void:
	var creatures: int = get_tree().get_nodes_in_group("creature").size()
	var plants: int = get_tree().get_nodes_in_group("plant").size()
	var kind: String = "SPHERE" if world_type == WorldType.SPHERE else "FLAT"
	print("SIM_WORLD_REPORT={\"world_type\":\"%s\",\"frames\":%d,\"creatures\":%d,\"plants\":%d,\"spawned\":%s}"
		% [kind, _frame, creatures, plants, str(_spawned)])
	LAAppExit.request(self, 0)
