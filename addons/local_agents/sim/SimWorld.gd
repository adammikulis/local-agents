@tool
@icon("res://addons/local_agents/icons/local_agent_world.svg")
class_name LocalAgentSimWorld
extends Node3D

## LocalAgentSimWorld: the ONE-node facade for a self-contained ecosystem sim. Drop it in, pick a `world_type`
## (SPHERE planet or FLAT box), set its bounds, and call spawn_world() (or let it auto-run on _ready). It
## COMPOSES the existing controllers behind a tiny export surface, and it does NOT reimplement their logic:
##   - SPHERE : LAPlanetBody.setup({radius,…}) → its LAVoxelTerrainService → LAMaterialField3D.setup_sphere
##              over a LASphereGrid shell; ecology places life ON the sphere; a sun drives the field.
##   - FLAT   : an LAFlatGroundTerrain plane + LAMaterialField3D.setup_dims (an origin box volume); ecology
##              scatters life across the flat extent.
## Both share LAEcologyService.setup() (spawning, population dynamics, breeding) and the creature/agent
## nodes. This keeps the composition-root wiring OUT of the game shell (VoxelWorld) so a library user gets a
## planet or a flat sandbox in one node, with no HUD/camera/disaster/save machinery.
##
## godot_voxel IS OPTIONAL, AND THIS FILE IS WHERE THAT IS ENFORCED. SPHERE is built out of the
## zylann.voxel GDExtension; FLAT is not, and must keep working in a project that never installed it.
## That means nothing at the top of this file may reach LAPlanetBody / LAVoxelTerrainService. Those
## declare VoxelLodTerrain / VoxelTool / VoxelBuffer typed members, which do not resolve without the
## extension, and a top-level `preload` of them fails the WHOLE class, FLAT mode included. So the planet
## script is `load`ed at runtime inside the SPHERE path only, and asking for SPHERE without the
## extension is a hard, named failure (see spawn_world()).
##
## The heavy hubs stay untouched: LocalAgentSimWorld only INSTANTIATES + WIRES controllers (composition root), it adds
## no behaviour to LAMaterialField3D / VoxelWorld. (Explicit types only, no ':=' inferred typing.)
##
## @tool so the inspector can warn about a misconfigured world before you press play; every lifecycle
## callback below therefore early-outs on Engine.is_editor_hint() so dropping the node in a scene never
## starts building a planet inside the editor.

enum WorldType { SPHERE, FLAT }

const SphereGridScript: GDScript = preload("res://addons/local_agents/sim/sphere/SphereGrid.gd")
const MaterialFieldScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialField3D.gd")
const EcologyServiceScript: GDScript = preload("res://addons/local_agents/sim/ecology/EcologyService.gd")
const FlatTerrainScript: GDScript = preload("res://addons/local_agents/creatures/terrain/adapters/FlatGroundTerrain.gd")

# NOT a preload: see the class docs above. Resolved with load() inside _build_sphere().
const PLANET_BODY_PATH: String = "res://addons/local_agents/sim/system/PlanetBody.gd"

# Field cells past which a build is slow enough to be worth warning about in the inspector. Chosen as a
# round number well above the defaults (SPHERE default = 6*20*20*20 = 48,000 cells).
const SLOW_BUILD_CELLS: int = 250000


@export_group("World")
## Which substrate this node builds. SPHERE grows a cubed-sphere planet and NEEDS the godot_voxel
## GDExtension (addons/zylann.voxel/) installed; FLAT builds a ground plane plus a box field volume and
## needs nothing beyond this addon. Everything below splits on this choice.
@export var world_type: WorldType = WorldType.SPHERE: set = _set_world_type
## Build the world automatically in _ready(). Turn it off to choose the moment yourself by calling
## spawn_world() from a script (e.g. after a menu has picked the settings).
@export var build_on_ready: bool = true: set = _set_build_on_ready
## This world's seed. Terrain generation and every random draw this node makes derive from it, so two
## LocalAgentSimWorld nodes in one process with different seeds are independent worlds.
@export var world_seed: int = 1337

@export_group("Sphere bounds")
@export_subgroup("Shape")
## Mean solid radius of the planet, in world units. Relief, feature size and the field shell are all
## scaled from this. The numbers were tuned at 250, so 500 gives the same-looking planet twice as big.
@export_range(25.0, 2000.0, 1.0, "or_greater", "suffix:m") var radius: float = 250.0
## How far the whole surface is pushed inward, in world units, before relief is added, so a larger
## number means more ocean, not more land (negative pushes outward for a drier planet). 0 puts the mean
## surface exactly on the sea shell.
@export_range(-30.0, 60.0, 0.1, "or_less", "or_greater", "suffix:m") var ocean_bias: float = 3.0
## Carve winding cave tunnels into the crust while the terrain generates.
@export var caves_enabled: bool = true
## Passed straight through to the planet body as "tides_enabled". Nothing reads it yet. This facade
## builds no ocean shell, so today it only rides along in the setup dictionary. Exported anyway so the
## property does not appear-and-move when an ocean controller lands.
@export var tides_enabled: bool = false

@export_subgroup("Field grid")
## Field cells along one edge of each of the 6 cube faces. The shell holds 6 x res x res x depth cells
## in total, so this is the dominant cost knob: doubling it quadruples the grid.
@export_range(8, 64, 1, "suffix:cells") var grid_res: int = 20: set = _set_grid_res
## Radial layers in the field shell, from the innermost crust layer out to space.
@export_range(8, 32, 1, "suffix:layers") var grid_depth: int = 20: set = _set_grid_depth

@export_subgroup("Lighting")
## Add a fixed DirectionalLight3D so the field's solar/thermal pass has a real sun to heat the surface
## (which is what ends up driving plant growth). SPHERE only. The FLAT build adds no light of its own.
## Turn it off when your scene already lights the world.
@export var sun_enabled: bool = true

@export_group("Flat bounds")
# @export_custom rather than @export_range: the range annotation rejects a Vector3 outright ("requires a
# variable of type float…"), but the inspector's Vector3 editor does read a PROPERTY_HINT_RANGE hint
# string, so this still gets bounded per-axis spinboxes with the unit suffix.
## Size of the flat world's box field volume, in world units: width (x) by height (y) by depth (z). The
## box is centred horizontally on this node's origin, with its floor at Ground Y.
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
## How many of each kind to found the world with, as {kind: count}. Left empty, DEFAULT_COUNTS is used.
## Keys are the ecology's built-in kinds: "plant", "rabbit", "fox", "bird", "villager", "fish", "rock",
## "tree". Any species id shipped under creatures/species/ works too (e.g. "mouse", "trout", "butterfly").
## An unknown key spawns nothing.
## Typed so the inspector gives you String keys and int values. From code, assign it directly
## (`world.initial_counts = {"rabbit": 3}` converts fine); `set("initial_counts", {...})` with an
## untyped literal is silently dropped, so pass a typed local if you must go through set().
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


## Build the chosen substrate + ecology. Idempotent (a second call is a no-op). After this, life spawns
## either automatically (auto_spawn) via the per-frame ready-gate, or when you call spawn_life() yourself.
## Asking for SPHERE without godot_voxel, or FLAT with a non-positive cell size, builds NOTHING and pushes
## a named error — the repo convention is an explicit typed failure over silent degradation.
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


# --- SPHERE substrate --------------------------------------------------------------------------
func _build_sphere() -> bool:
	# load(), not preload(): PLANET_BODY_PATH pulls in LAVoxelTerrainService, whose VoxelLodTerrain /
	# VoxelTool / VoxelBuffer typed members do not resolve without addons/zylann.voxel/. Reaching it from
	# the top of this file made that failure take the whole class — and FLAT mode — down with it.
	var script_res: GDScript = load(PLANET_BODY_PATH)
	if script_res == null:
		push_error("VOXEL_BACKEND_REQUIRED: LocalAgentSimWorld could not load %s. That script needs the godot_voxel GDExtension (addons/zylann.voxel/); install it, or set world_type to FLAT." % PLANET_BODY_PATH)
		return false
	var scale: float = radius / 250.0                 # the sphere knobs were tuned at radius 250
	_body = script_res.new()
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
	# Cubed-sphere field shell enclosing the planet (crust + atmosphere), scaled with the radius.
	_material = MaterialFieldScript.new()
	_material.name = "MaterialField"
	add_child(_material)
	var grid: RefCounted = SphereGridScript.new()
	grid.build(grid_res, grid_depth, 170.0 * scale, 8.0 * scale, _body.center())
	_material.setup_sphere(grid, _terrain)
	if _material.has_method("sample_solidity"):
		_material.sample_solidity()
	if _sun != null and _material.has_method("set_sun"):
		_material.set_sun(_sun)
	return true


# --- FLAT substrate ----------------------------------------------------------------------------
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


# --- Spawning ----------------------------------------------------------------------------------
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
			var rng: LASimRng = _spawn_rng()
			var p: Vector3 = Vector3(rng.randf_range(-hx, hx), ground_y + 2.0, rng.randf_range(-hz, hz))
			_ecology.spawn(kind, p)


# --- Inspector warnings --------------------------------------------------------------------------
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
		out.append("These settings ask for %d field cells. Past roughly %d the world takes a while to build and holds a lot of memory. Lower Field Grid res/depth (Sphere) or raise Flat Cell Size." % [cells, SLOW_BUILD_CELLS])
	return out


## Field cells the current settings would allocate, so a host can size a world before building it.
## SPHERE: 6 cube faces x grid_res^2 surface cells x grid_depth radial layers (LASphereGrid.cell_count).
## FLAT: the extent divided by the cell size on each axis. 0 when the settings cannot produce a grid.
func planned_cell_count() -> int:
	if world_type == WorldType.SPHERE:
		return 6 * grid_res * grid_res * grid_depth
	if flat_cell_size <= 0.0:
		return 0
	var dx: int = maxi(1, int(round(flat_extent.x / flat_cell_size)))
	var dy: int = maxi(1, int(round(flat_extent.y / flat_cell_size)))
	var dz: int = maxi(1, int(round(flat_extent.z / flat_cell_size)))
	return dx * dy * dz


# The editor does not poll _get_configuration_warnings(); it re-reads them when a node asks it to. Every
# export those warnings depend on routes its setter through here. These are `set = _method` rather than
# inline `set(value):` blocks because an inline setter's parameter cannot carry a type annotation, and
# this project requires explicit types on every parameter.
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


func _set_grid_depth(value: int) -> void:
	grid_depth = value
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
## True once spawn_world() has actually built a substrate. Stays false when the build was refused
## (SPHERE without godot_voxel, or a non-positive Flat Cell Size), so a host can react to that.
func has_built() -> bool: return _built
## True once the founding population has been placed, by auto_spawn or by a spawn_life() call.
func has_spawned() -> bool: return _spawned
