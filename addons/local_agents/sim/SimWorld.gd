@tool
@icon("res://addons/local_agents/icons/local_agent_world.svg")
class_name LocalAgentSimWorld
extends Node3D


enum WorldType { SPHERE, FLAT }

## spawn_world() finished: terrain(), material_field() and ecology() are live.
signal world_built

const MaterialFieldScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialField3D.gd")
const EcologyServiceScript: GDScript = preload("res://addons/local_agents/sim/ecology/EcologyService.gd")
const FlatTerrainScript: GDScript = preload("res://addons/local_agents/creatures/terrain/adapters/FlatGroundTerrain.gd")

const PLANET_BODY_PATH: String = "res://addons/local_agents/sim/system/PlanetBody.gd"

# Field cells past which a build is slow enough to be worth warning about in the inspector.
const SLOW_BUILD_CELLS: int = 250000

@export_group("World")
@export var world_type: WorldType = WorldType.SPHERE: set = _set_world_type
## Build the world automatically in _ready(). Turn it off to choose the moment yourself by calling
## spawn_world() from a script (e.g. after a menu has picked the settings).
@export var build_on_ready: bool = true: set = _set_build_on_ready
## This world's seed. Terrain generation and every random draw this node makes derive from it.
@export var world_seed: int = 1337

@export_group("Sphere bounds")
@export_subgroup("Shape")
## Which row of LABodySeeds this world is built from. A body's SIZE is not set here: it follows from the
## mass and composition that row declares, and after the seal it is measured off the matter itself.
@export var body_seed: String = "planet"
## Carve winding cave tunnels into the crust while the terrain generates.
@export var caves_enabled: bool = true
@export var tides_enabled: bool = false

@export_subgroup("Field grid")
## Root cells along one edge of the box. Where res://docs/CELL_BUDGET declares a budget, the build refines
## the band around the surface under it.
@export_range(8, 64, 1, "suffix:cells") var grid_res: int = 20: set = _set_grid_res

@export_subgroup("Slice")
## Cells per axis of a SLICE box laid on the body instead of a box around the whole planet. ZERO = no
## slice here; the project setting / LA_SLICE_BOX env can still configure one (node wins when set).
@export var slice_cells: Vector3i = Vector3i.ZERO
## Cell edge of the slice box, metres: the COARSEST the box carries.
@export_range(1.0, 1.0e5, 1.0, "or_greater", "suffix:m") var slice_cell_size_m: float = 4000.0
## Finest cell edge the slice refines to, metres. Must be slice_cell_size_m halved a whole number of times.
@export_range(0.1, 1.0e5, 0.1, "or_greater", "suffix:m") var slice_fine_m: float = 4000.0
## Offset of the slice box's centre from the body centre, metres, body frame. Its direction is the
## slice's local vertical, so it must be nonzero.
@export var slice_offset_m: Vector3 = Vector3.ZERO

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

@export_group("Wiring")
## The star the body orbits. SPHERE only; unset, the build makes the one LABodySeeds declares and sets it
## here.
@export var star: LAStar: set = _set_star

# A small, lively founding stock for a demo world (kept modest so it boots fast).
const DEFAULT_COUNTS: Dictionary = {"rabbit": 14, "fox": 3, "bird": 10, "plant": 40}

var _body: Variant = null        # LAPlanetBody (SPHERE mode). Untyped on purpose: naming the class here
                                 # would drag godot_voxel back into this file's parse.
var _terrain: Variant = null     # LAVoxelTerrainService (sphere) or LAFlatGroundTerrain (flat)
var _material: Variant = null    # LAMaterialField3D
var _ecology: Variant = null     # LAEcologyService
var _actors_root: Node3D = null
var _loop: LASimLoop = null
var _orbits: LASystemOrbits = null

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
	if world_type == WorldType.SPHERE and not LAMaterialSphereGPU3D.available():
		push_error("GPU_REQUIRED: LocalAgentSimWorld world_type=SPHERE steps its field on a compute device, and this renderer offers none (a --headless run has none). Run with a RenderingDevice, or set world_type to FLAT.")
		return
	if world_type == WorldType.FLAT and flat_cell_size <= 0.0:
		push_error("LocalAgentSimWorld: flat_cell_size must be greater than 0, because the flat build divides the extent by it. Got %s." % str(flat_cell_size))
		return
	_built = true
	# WHICH PROCESSES THIS WORLD CONTAINS, settled before anything is built.
	LAProcessSet.declare_world(LAProcessSet.UNSET)
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
	_wire_loop()
	world_built.emit()


## THE ONE DRIVER, as the game's. A SPHERE world holds simulated time while its field seeds, then each
## step turns the body and advances the orbit before the field steps; the ecology steps in both modes.
func _wire_loop() -> void:
	_loop = LASimLoop.new()
	_loop.name = "SimLoop"
	add_child(_loop)
	if world_type == WorldType.SPHERE:
		_loop.hold()
		_loop.seeding.connect(_on_seeding)
		_loop.stepped.connect(_on_step)
		_loop.stepped.connect(Callable(_material.step_driver(), "step"))
	_loop.stepped.connect(_ecology.on_sim_step)


func _on_seeding(_tick: int) -> void:
	if _material.step_driver().seed_tick():
		_loop.release()


## One simulated step of what surrounds the field: the body turns on its measured spin, the orbit
## advances and publishes the star's irradiance, and the ecology learns where the star stands.
func _on_step(_step: int) -> void:
	var dt: float = LASimLoop.step_seconds()
	var spin: float = _body.angular_velocity_rad_s()
	if is_finite(spin):
		_body.rotate(_body.spin_axis(), spin * dt)
	_orbits.update(dt)
	var centre: Vector3 = _body.center()
	_ecology.set_sun((star.global_position - centre).normalized(), centre)


## The radius the seeded matter fills before it is laid down: its mass over the density of what it is made
## of. Only the terrain generator needs it — after the seal the body measures its own.
func seed_radius() -> float:
	return LABodySeeds.seed_radius_m(body_seed)


## Edge of one field cell, metres: the box spans the body plus its air column, cut grid_res ways.
func field_cell_size_m() -> float:
	return 2.0 * (seed_radius() + LAFieldGridBudget.air_extent_m(
		body_seed, seed_radius(), LABodySeeds.surface_temp_c())) / float(maxi(grid_res, 1))


func _build_sphere() -> bool:
	var script_res: GDScript = load(PLANET_BODY_PATH)
	if script_res == null:
		push_error("VOXEL_BACKEND_REQUIRED: LocalAgentSimWorld could not load %s. That script needs the godot_voxel GDExtension (addons/zylann.voxel/); install it, or set world_type to FLAT." % PLANET_BODY_PATH)
		return false
	_body = script_res.new()
	_body.name = "PlanetBody"
	add_child(_body)
	_body.setup({
		"radius": seed_radius(), "seed_key": body_seed, "caves_enabled": caves_enabled,
		"tides_enabled": tides_enabled, "seed": world_seed,
	})
	_terrain = _body.terrain()
	_actors_root = _body.actors_root
	if star == null:
		star = LAStar.new()
		star.name = "Star"
		add_child(star)
	star.setup({})
	# Cartesian box enclosing the planet and the air above it. METRES: the gravity solve is SI.
	_material = MaterialFieldScript.new()
	_material.name = "MaterialField"
	add_child(_material)
	# Node exports outrank the project setting, which outranks LA_SLICE_BOX.
	if slice_cells != Vector3i.ZERO:
		_material.set_meta(LAFieldSlice3D.META_BOX, "%f,%f,%f,%d,%d,%d,%f,%f" % [
			slice_offset_m.x, slice_offset_m.y, slice_offset_m.z,
			slice_cells.x, slice_cells.y, slice_cells.z, slice_cell_size_m, slice_fine_m])
	var slice: LAFieldSlice3D = LAFieldSlice3D.of(_material)
	if slice != null:
		if not slice.apply(_material, _body, _terrain):
			push_error("SLICE_INVALID: %s" % slice.error)
			return false
	else:
		# The box holds the whole body, so every face's exterior is vacuum unless a spec says otherwise.
		if not _material.has_meta(LAFieldBoundary3D.META_FACES) \
				and LAFieldBoundary3D.explicit_spec() == "":
			_material.set_meta(LAFieldBoundary3D.META_FACES, "space,space,space,space,space,space")
		var air_m: float = LAFieldGridBudget.air_extent_m(body_seed, seed_radius(), LABodySeeds.surface_temp_c())
		var rock_m: float = LAFieldGridBudget.rock_extent_m(seed_radius(), LABodySeeds.surface_temp_c())
		if not is_finite(air_m) or not is_finite(rock_m):
			push_error("GRID_EXTENT_UNSOLVED: the seeded air has no Knudsen top (%s) or the geotherm no lid (%s), so the box has no extent to enclose." % [air_m, rock_m])
			return false
		var extent_m: float = seed_radius() + air_m
		var cell_m: float = field_cell_size_m()
		var dims: Vector3i = LAVoxelGrid.dims_for(extent_m, cell_m)
		var half: float = 0.5 * float(dims.x) * cell_m
		# RESOLUTION FOLLOWS POSITION: the shell that holds the air column and the regolith under it is
		# refined; the vacuum corners and the deep interior stay coarsest.
		_material.setup_box(_body.center() - Vector3(half, half, half), dims, cell_m, _terrain,
			_body.center(), rock_m, air_m,
			LAFieldGridBudget.target_edge_m(body_seed, seed_radius(), LABodySeeds.surface_temp_c()), seed_radius())
	# Slot-opposite reciprocity is the contract every gather kernel the field steps depends on.
	var grid_check: Dictionary = _material._grid.validate()
	if not bool(grid_check.get("ok", false)):
		push_error("GRID_INVALID: %s" % JSON.stringify(grid_check))
		return false
	if _material.has_method("sample_solidity"):
		_material.sample_solidity()
	# The star's irradiance along the line from it to the body centre.
	_material.set_star(star)
	_material.set_body(_body)
	# The body IS the field's matter: its mass, inertia and spin are read back off it, never typed.
	_body.set_field(_material)
	_orbits = LASystemOrbits.new()
	_orbits.name = "SystemOrbits"
	add_child(_orbits)
	_orbits.setup(_body, star, _material)
	return true


func _build_flat() -> bool:
	_terrain = FlatTerrainScript.new(ground_y)
	_actors_root = Node3D.new()
	_actors_root.name = "Actors"
	add_child(_actors_root)
	_material = MaterialFieldScript.new()
	_material.name = "MaterialField"
	add_child(_material)
	# Box field volume centred on the extent, its floor at ground_y. setup_box allocates the box channels +
	# wires the CPU box-step (heat diffuses/rises) — no planet, no GPU kernels.
	var dx: int = maxi(1, int(round(flat_extent.x / flat_cell_size)))
	var dy: int = maxi(1, int(round(flat_extent.y / flat_cell_size)))
	var dz: int = maxi(1, int(round(flat_extent.z / flat_cell_size)))
	var origin: Vector3 = Vector3(-0.5 * flat_extent.x, ground_y, -0.5 * flat_extent.z)
	_material.setup_box(origin, Vector3i(dx, dy, dz), flat_cell_size)
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
		_ecology.populate_environment(forest_clusters)
	else:
		_scatter_flat(counts)


# SPHERE spawns wait for the body to be built (like the game's spawn controller); FLAT ground is always
# ready, so it spawns at once. A few settle ticks then let the first frames of the world go by.
func _try_spawn_life() -> void:
	if world_type == WorldType.SPHERE:
		if _body == null or _body.radius() <= 0.0:
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
	if star != null and world_type == WorldType.FLAT:
		out.append("Star is set but World Type is Flat. A flat world has no body to orbit it, so nothing reads the star.")
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


func _set_star(value: LAStar) -> void:
	star = value
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
