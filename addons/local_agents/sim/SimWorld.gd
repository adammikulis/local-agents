@tool
@icon("res://addons/local_agents/icons/local_agent_world.svg")
class_name LocalAgentSimWorld
extends Node3D


enum WorldType { SPHERE, FLAT }

const MaterialFieldScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialField3D.gd")
const EcologyServiceScript: GDScript = preload("res://addons/local_agents/sim/ecology/EcologyService.gd")
const FlatTerrainScript: GDScript = preload("res://addons/local_agents/creatures/terrain/adapters/FlatGroundTerrain.gd")

const PLANET_BODY_PATH: String = "res://addons/local_agents/sim/system/PlanetBody.gd"

# Field cells past which a build is slow enough to be worth warning about in the inspector.
const SLOW_BUILD_CELLS: int = 250000

# Height of the air column above the mean surface the field box encloses, metres. Earth's homosphere ends
# near the 100 km turbopause; above it the remaining mass is negligible against the crust in the same box.
const MODELLED_ATMOSPHERE_HEIGHT_M: float = 1.0e5

# The body's shape, METRES, because the grid and the gravity solve are SI. Terrestrial continental relief
# and its wavelength; basins, ridges and cave tunnels are the same lengths one order down.
const RELIEF_M: float = 9.4e3
const FEATURE_M: float = 5.2e4
const BASIN_RELIEF_M: float = 4.0e3
const BASIN_SIZE_M: float = 4.4e4
const RIDGE_RELIEF_M: float = 1.35e3
const RIDGE_SIZE_M: float = 3.2e4
const DETAIL_RELIEF_M: float = 3.4e2
const CAVE_SIZE_M: float = 2.0e4
const CAVE_DEPTH_FADE_M: float = 4.7e3

@export_group("World")
@export var world_type: WorldType = WorldType.SPHERE: set = _set_world_type
## Build the world automatically in _ready(). Turn it off to choose the moment yourself by calling
## spawn_world() from a script (e.g. after a menu has picked the settings).
@export var build_on_ready: bool = true: set = _set_build_on_ready
## This world's seed. Terrain generation and every random draw this node makes derive from it, so two
## LocalAgentSimWorld nodes in one process with different seeds are independent worlds.
@export var world_seed: int = 1337

@export_group("Sphere bounds")
@export_subgroup("Shape")
## Mean solid radius of the planet, METRES. Relief and feature size are declared lengths and no longer
## scale with it, so changing this changes the body's size without silently rescaling its geology.
@export_range(1.0e5, 1.0e7, 1.0e3, "or_greater", "suffix:m") var radius: float = 2.4397e6
@export_range(-1.0e4, 1.0e4, 10.0, "or_less", "or_greater", "suffix:m") var ocean_bias: float = 1.0e3
## Carve winding cave tunnels into the crust while the terrain generates.
@export var caves_enabled: bool = true
@export var tides_enabled: bool = false

@export_subgroup("Field grid")
## Field cells along one edge of the box. The box holds res^3 cells, so this is the dominant cost knob:
## doubling it multiplies the grid by eight.
@export_range(8, 64, 1, "suffix:cells") var grid_res: int = 20: set = _set_grid_res

@export_subgroup("Lighting")
@export var sun_enabled: bool = true

@export_group("Flat bounds")
@export_custom(PROPERTY_HINT_RANGE, "1,2000,1,or_greater,suffix:m") var flat_extent: Vector3 = Vector3(120.0, 40.0, 120.0): set = _set_flat_extent
## Edge length of one field cell, in world units. Must be greater than 0: the build divides the extent
## by it to get the cell counts per axis. Smaller = finer simulation and many more cells.
@export_range(0.5, 25.0, 0.1, "or_greater", "suffix:m") var flat_cell_size: float = 5.0: set = _set_flat_cell_size
## World-space Y of the flat ground plane creatures stand on.
@export_range(-500.0, 500.0, 0.1, "or_less", "or_greater", "suffix:m") var ground_y: float = 0.0

@export_group("Population")
## Spawn the starting ecology automatically, as soon as the world is built and its ground is queryable.
## Turn it off to pick the moment yourself with spawn_life().
@export var auto_spawn: bool = true: set = _set_auto_spawn
@export var initial_counts: Dictionary[String, int] = {}
## Forest seed clusters scattered across the world at start. SPHERE only: a FLAT world gets its plants
## from initial_counts instead.
@export_range(0, 64, 1, "or_greater", "suffix:clusters") var forest_clusters: int = 6

# A small, lively founding stock for a demo world (kept modest so it boots fast).
const DEFAULT_COUNTS: Dictionary = {"rabbit": 14, "fox": 3, "bird": 10, "plant": 40}

var _body: Variant = null        # LAPlanetBody (SPHERE mode). Untyped on purpose: naming the class here
                                 # would drag godot_voxel back into this file's parse.
var _terrain: Variant = null     # LAVoxelTerrainService (sphere) or LAFlatGroundTerrain (flat)
var _material: Variant = null    # LAMaterialField3D
var _ecology: Variant = null     # LAEcologyService
var _actors_root: Node3D = null
var _sun: DirectionalLight3D = null

var _built: bool = false
var _spawned: bool = false
var _ready_ticks: int = 0

# This world's own placement stream, derived from world_seed. Owned here, not shared with any other world.
var _rng: LASimRng = null


func _spawn_rng() -> LASimRng:
	if _rng == null:
		_rng = LASimRng.make(world_seed, "simworld_spawn")
	return _rng


## True when the godot_voxel GDExtension (addons/zylann.voxel/) is present, which is what a SPHERE world
## is built out of. A FLAT world does not need it. Safe to call from the editor and from a script.
static func has_voxel_backend() -> bool:
	return ClassDB.class_exists("VoxelLodTerrain")


func _ready() -> void:
	if Engine.is_editor_hint():
		# @tool, so this node is alive in the editor purely to answer _get_configuration_warnings().
		# It must never build or step a world there — dropping it in a scene would start meshing a planet.
		set_process(false)
		return
	if build_on_ready:
		spawn_world()


func spawn_world() -> void:
	if _built:
		return
	if world_type == WorldType.SPHERE and not has_voxel_backend():
		push_error("VOXEL_BACKEND_REQUIRED: LocalAgentSimWorld world_type=SPHERE needs the godot_voxel GDExtension (addons/zylann.voxel/). Install it, or set world_type to FLAT.")
		return
	if world_type == WorldType.FLAT and flat_cell_size <= 0.0:
		push_error("LocalAgentSimWorld: flat_cell_size must be greater than 0, because the flat build divides the extent by it. Got %s." % str(flat_cell_size))
		return
	_built = true
	var ok: bool = false
	if world_type == WorldType.SPHERE:
		ok = _build_sphere()
	else:
		ok = _build_flat()
	if not ok:
		_built = false
		return
	# Ecology is shared by both modes: it drives spawning + population dynamics against the duck-typed terrain.
	_ecology = EcologyServiceScript.new()
	_ecology.name = "Ecology"
	add_child(_ecology)
	_ecology.setup(_terrain, _actors_root)
	if _ecology.has_method("set_material_field"):
		_ecology.set_material_field(_material)


func _build_sphere() -> bool:
	var script_res: GDScript = load(PLANET_BODY_PATH)
	if script_res == null:
		push_error("VOXEL_BACKEND_REQUIRED: LocalAgentSimWorld could not load %s. That script needs the godot_voxel GDExtension (addons/zylann.voxel/); install it, or set world_type to FLAT." % PLANET_BODY_PATH)
		return false
	_body = script_res.new()
	_body.name = "PlanetBody"
	add_child(_body)
	_body.setup({
		"radius": radius, "sea_radius": radius, "ocean_bias": ocean_bias,
		"relief": RELIEF_M, "feature_size": FEATURE_M,
		"basin_relief": BASIN_RELIEF_M, "basin_size": BASIN_SIZE_M,
		"ridge_relief": RIDGE_RELIEF_M, "ridge_size": RIDGE_SIZE_M, "ridge_octaves": 2,
		"detail_relief": DETAIL_RELIEF_M,
		"caves_enabled": caves_enabled, "cave_size": CAVE_SIZE_M, "cave_threshold": 0.09,
		"cave_strength": 40.0, "cave_depth_fade": CAVE_DEPTH_FADE_M,
		"tides_enabled": tides_enabled, "view_distance": 2000, "seed": world_seed,
	})
	_terrain = _body.terrain()
	_actors_root = _body.actors_root
	# A sun so the field's solar/thermal pass has a real light (drives heating → biomass). Fixed in space.
	if sun_enabled:
		_sun = DirectionalLight3D.new()
		_sun.name = "Sun"
		_sun.rotation = Vector3(-0.9, 0.4, 0.0)
		add_child(_sun)
	# Cartesian box enclosing the planet and the air above it. METRES: the gravity solve is SI.
	_material = MaterialFieldScript.new()
	_material.name = "MaterialField"
	add_child(_material)
	var extent_m: float = radius + MODELLED_ATMOSPHERE_HEIGHT_M
	_material.setup_body(_body.center(), extent_m, 2.0 * extent_m / float(maxi(grid_res, 1)), _terrain)
	if _material.has_method("sample_solidity"):
		_material.sample_solidity()
	if _sun != null and _material.has_method("set_sun"):
		_material.set_sun(_sun)
	return true


func _build_flat() -> bool:
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
	return true


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _built and not _spawned and auto_spawn:
		_try_spawn_life()


## Spawn the starting ecology now (bypassing the auto gate). Safe to call once the world is built.
func spawn_life() -> void:
	if not _built or _spawned:
		return
	_spawned = true
	var counts: Dictionary = DEFAULT_COUNTS
	if not initial_counts.is_empty():
		counts = initial_counts
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
		if not _body.is_ready_at(_body.center() + Vector3.UP * (_body.radius() + 30.0)):
			return
		_ready_ticks += 1
		if _ready_ticks <= 6:
			return
	spawn_life()


func _scatter_flat(counts: Dictionary) -> void:
	var hx: float = 0.45 * flat_extent.x
	var hz: float = 0.45 * flat_extent.z
	for kind_v in counts.keys():
		var kind: String = String(kind_v)
		var n: int = int(counts[kind_v])
		for i in range(n):
			var rng: LASimRng = _spawn_rng()
			var p: Vector3 = Vector3(rng.randf_range(-hx, hx), ground_y + 2.0, rng.randf_range(-hz, hz))
			_ecology.spawn(kind, p)


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if world_type == WorldType.SPHERE and not has_voxel_backend():
		out.append("World Type is Sphere, but the godot_voxel GDExtension (addons/zylann.voxel/) is not installed, so no planet can be built and spawn_world() will report VOXEL_BACKEND_REQUIRED. Install godot_voxel, or set World Type to Flat, which needs nothing beyond this addon.")
	if flat_cell_size <= 0.0:
		out.append("Flat Cell Size must be greater than 0: the flat build divides Flat Extent by it to size the field grid.")
	if flat_extent.x <= 0.0 or flat_extent.y <= 0.0 or flat_extent.z <= 0.0:
		out.append("Flat Extent needs a positive size on every axis; %s has a zero or negative component, which leaves the flat field volume empty." % str(flat_extent))
	if auto_spawn and not build_on_ready:
		out.append("Auto Spawn is on but Build On Ready is off, so no world exists to spawn into until something calls spawn_world() from a script.")
	var cells: int = planned_cell_count()
	if cells > SLOW_BUILD_CELLS:
		out.append("These settings ask for %d field cells. Past roughly %d the world takes a while to build and holds a lot of memory. Lower Field Grid res (Sphere) or raise Flat Cell Size." % [cells, SLOW_BUILD_CELLS])
	return out


func planned_cell_count() -> int:
	if world_type == WorldType.SPHERE:
		return grid_res * grid_res * grid_res
	if flat_cell_size <= 0.0:
		return 0
	var dx: int = maxi(1, int(round(flat_extent.x / flat_cell_size)))
	var dy: int = maxi(1, int(round(flat_extent.y / flat_cell_size)))
	var dz: int = maxi(1, int(round(flat_extent.z / flat_cell_size)))
	return dx * dy * dz


func _refresh_warnings() -> void:
	if Engine.is_editor_hint():
		update_configuration_warnings()


func _set_world_type(value: WorldType) -> void:
	world_type = value
	_refresh_warnings()


func _set_build_on_ready(value: bool) -> void:
	build_on_ready = value
	_refresh_warnings()


func _set_grid_res(value: int) -> void:
	grid_res = value
	_refresh_warnings()


func _set_flat_extent(value: Vector3) -> void:
	flat_extent = value
	_refresh_warnings()


func _set_flat_cell_size(value: float) -> void:
	flat_cell_size = value
	_refresh_warnings()


func _set_auto_spawn(value: bool) -> void:
	auto_spawn = value
	_refresh_warnings()


# --- Accessors (for a host that wires a camera / HUD onto the facade) ----------------------------
## The LAMaterialField3D substrate, or null before spawn_world() succeeds.
func material_field() -> Variant: return _material
## The LAEcologyService driving spawning + population dynamics, or null before spawn_world() succeeds.
func ecology() -> Variant: return _ecology
## The duck-typed terrain adapter: LAVoxelTerrainService (SPHERE) or LAFlatGroundTerrain (FLAT).
func terrain() -> Variant: return _terrain
## The LAPlanetBody, or null in FLAT mode / before a SPHERE world is built.
func planet_body() -> Variant: return _body
## Parent node every spawned creature is added under.
func actors_root() -> Node3D: return _actors_root
func has_built() -> bool: return _built
## True once the founding population has been placed, by auto_spawn or by a spawn_life() call.
func has_spawned() -> bool: return _spawned
