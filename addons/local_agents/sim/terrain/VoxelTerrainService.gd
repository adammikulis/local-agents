class_name LAVoxelTerrainService
extends RefCounted


const SHADER_PATH: String = "res://addons/local_agents/sim/shaders/VoxelTerrainTriplanar.gdshader"
const PlanetGenScript: GDScript = preload("res://addons/local_agents/sim/terrain/SpherePlanetGenerator.gd")

const MAX_LOD: int = 23                   # godot_voxel's cap: VoxelLodTerrain rejects lod_count >= 24

var _terrain: VoxelLodTerrain = null
var _generator: VoxelGeneratorGraph = null   # the planet's SDF, queryable before anything is meshed
var _viewer: VoxelViewer = null
var _gen_opts: Dictionary = {}             # the dict build_planet handed LASpherePlanetGenerator.build()
var _center: Vector3 = Vector3.ZERO
var _planet_radius: float = 0.0
var _coast_dir: Vector3 = Vector3.ZERO   # the coast site the last box asked for
var _planet_gen: RefCounted = null       # LASpherePlanetGenerator: the seed's shape, dropped at the seal
## Where the body's water settled: the fill's per-node surface elevation over the mean crust radius.
var _water_level: PackedFloat32Array = PackedFloat32Array()
var _water_nlat: int = 0
var _water_nlon: int = 0

## Planet centre in world space (origin by default). Only meaningful in planet mode.
func planet_center() -> Vector3:
	return _center

## Mean solid radius of the planet (world units from centre). 0 in island mode.
func planet_radius() -> float:
	return _planet_radius

## Highest radius the terrain reaches: the mean crust radius plus the highest elevation the hypsographic
## curve carries over its own mean. Nothing solid stands above it.
func max_surface_radius() -> float:
	return _planet_radius + LAPhysical.HYPSOMETRY_HIGHEST_M - LAPlanetComposition.hypsometry_mean_m()

## Lowest radius the terrain reaches: the mean crust radius plus the deepest elevation the curve carries.
func min_surface_radius() -> float:
	return _planet_radius + LAPhysical.HYPSOMETRY_DEEPEST_M - LAPlanetComposition.hypsometry_mean_m()


## WHERE THE BODY'S WATER STANDS along a body-frame direction: the world radius of the free surface over
## it, NAN where the fill left that column dry. Not a shell: an ocean and a lake read different levels.
func water_radius(body_dir: Vector3) -> float:
	if _water_level.is_empty():
		return NAN
	var e: float = LAWaterFill.level_at(_water_level, _water_nlat, _water_nlon, body_dir)
	return NAN if is_nan(e) else _planet_radius + e

## Local "up" at a world point: radial from the planet centre.
func up_at(pos: Vector3) -> Vector3:
	var r: Vector3 = pos - _center
	return r.normalized() if r.length() > 0.001 else Vector3.UP


func build_planet(parent: Node3D, opts: Dictionary = {}) -> void:
	if _terrain != null:
		return
	_center = opts.get("center", Vector3.ZERO)
	var pg: RefCounted = PlanetGenScript.new()
	# THE SHAPE IS LAPlanetShape'S, WHOLE. A default written here would be a second declaration of the
	# body, and the one nobody reads.
	var body: Dictionary = LABodySeeds.of(String(opts.get("seed_key", "planet")))
	var rho_w: float = float(LASubstances.table().get("h2o", {}).get("density", 0.0))
	if rho_w <= 0.0 or not body.has("hydrosphere_kg") or not body.has("groundwater_kg"):
		push_error("VoxelTerrainService: no hydrosphere declared or no water density, so the body has no water to lay down.")
		return
	var gen_opts: Dictionary = LAPlanetShape.opts(float(opts.get("radius", 0.0)), int(opts.get("seed", 1337)))
	var gen: VoxelGeneratorGraph = pg.build(gen_opts)
	_planet_radius = pg.radius()
	_generator = gen
	_planet_gen = pg
	_fill_water((float(body["hydrosphere_kg"]) - float(body["groundwater_kg"])) / rho_w)

	var mesher: VoxelMesherTransvoxel = VoxelMesherTransvoxel.new()   # LA_APPROX: godot_voxel_mesher_over_generator
	# TRANSVOXEL'S TRANSITION CELLS CLOSE THE STEP BETWEEN TWO LEVELS OF DETAIL; the terrain shader moves
	# their vertices onto the coarse surface.
	mesher.transitions_enabled = true

	var terrain: VoxelLodTerrain = VoxelLodTerrain.new()
	terrain.name = "VoxelTerrain"
	terrain.mesher = mesher
	terrain.generator = gen
	terrain.material = _make_material()
	# Tell the triplanar shader to band climate RADIALLY (snow/beach/slope keyed off height over the mean
	# crust radius + radial up) instead of by world-Y — else all the "snow" piles at the +Y pole.
	if terrain.material is ShaderMaterial:
		var tm: ShaderMaterial = terrain.material
		tm.set_shader_parameter("planet_enabled", 1.0)
		tm.set_shader_parameter("planet_center", _center)
		tm.set_shader_parameter("planet_crust_radius", _planet_radius)
	terrain.lod_count = _lod_count_for(terrain.lod_distance)
	terrain.view_distance = int(opts.get("view_distance", 8000))
	terrain.generate_collisions = true
	terrain.collision_layer = 1
	terrain.collision_mask = 0
	var rr: float = max_surface_radius() + 80.0     # sphere-enclosing box (+ atmosphere headroom)
	terrain.voxel_bounds = AABB(
		_center - Vector3(rr, rr, rr), Vector3(rr * 2.0, rr * 2.0, rr * 2.0))
	# STREAMED, NOT HELD WHOLE. Full load mode asks for every voxel of the body in memory; on one this size
	# the LOD pyramid never descends and nothing near a viewer is ever drawn.
	terrain.full_load_mode_enabled = false
	parent.add_child(terrain)
	_terrain = terrain
	_gen_opts = gen_opts


## The VoxelLodTerrain node (null before build_planet()).
func terrain_node() -> Node:
	return _terrain


## The generator options this planet's SDF was built from. Empty before build_planet(). Every input the
## generated terrain depends on is in here, so a cache over that terrain keys on it.
func generator_options() -> Dictionary:
	return _gen_opts.duplicate()


## Set a uniform on the terrain's triplanar shader material (e.g. the temperature texture that makes
## hot ground glow, or the heat-debug toggle). No-op before build().
func set_shader_param(param: String, value) -> void:
	if _terrain != null and _terrain.material is ShaderMaterial:
		(_terrain.material as ShaderMaterial).set_shader_parameter(param, value)

## THE LOD PYRAMID SPANS THE BODY OR ITS FAR SIDE IS NEVER MESHED. The coarsest level reaches
## lod_distance * 2^(lod_count-1) metres and the far limb stands 2R away, so the count is read off the
## radius rather than typed.
func _lod_count_for(lod_dist: float) -> int:
	return clampi(int(ceil(log(maxf(_planet_radius, lod_dist) / lod_dist) / log(2.0))) + 1, 1, MAX_LOD)


## How far the terrain streams and draws around a viewer, in metres — the draw-distance setting.
func set_view_distance(metres: float) -> void:
	if _terrain != null:
		_terrain.view_distance = int(maxf(1000.0, metres))
		if _viewer != null:
			_viewer.view_distance = _terrain.view_distance


func attach_viewer(camera: Node3D, visuals: bool = true) -> void:
	if camera == null or _terrain == null:
		return
	var viewer: VoxelViewer = VoxelViewer.new()
	viewer.view_distance = _terrain.view_distance
	viewer.requires_visuals = visuals
	viewer.requires_collisions = visuals
	camera.add_child(viewer)
	_viewer = viewer

## Signed distance to the rock surface at a world point: negative INSIDE rock, positive in air or void,
## from the body's own shape rather than from what a viewer has streamed. 999 when there is no terrain.
func sdf_at(pos: Vector3) -> float:
	if _terrain == null:
		return 999.0
	var d: Vector3 = pos - _center
	var r: float = d.length()
	if r <= min_surface_radius():
		return r - min_surface_radius()
	if r >= max_surface_radius():
		return r - max_surface_radius()
	var sr: float = surface_radius(d)
	return 999.0 if is_nan(sr) else r - sr


func is_solid(pos: Vector3) -> bool:
	return sdf_at(pos) < 0.0


## Physics-space raycast against the terrain body (collision_mask=1).
## Returns {"hit": bool, "position": Vector3, "normal": Vector3}.
func raycast_terrain(from: Vector3, dir: Vector3, max_distance: float) -> Dictionary:
	var miss: Dictionary = {"hit": false, "position": Vector3.ZERO, "normal": Vector3.UP}
	if _terrain == null:
		return miss
	var world: World3D = _terrain.get_world_3d()
	if world == null:
		return miss
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	if space == null:
		return miss
	var to: Vector3 = from + dir.normalized() * max_distance
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to, 1)
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return miss
	return {"hit": true, "position": hit.position, "normal": hit.normal}

func ground_point(pos: Vector3) -> Vector3:
	return surface_point(pos - _center)

## PLANET: world radius of the solid surface along the WORLD direction `dir`, read off the body's own
## shape, so one direction gives one radius whatever a viewer has streamed. NAN without terrain.
func surface_radius(dir: Vector3) -> float:
	return _generated_surface_radius(to_body_dir(dir))


## The same radius along a direction fixed IN THE BODY: a place on the planet, which the world direction
## sweeps past as the body turns.
func body_surface_radius(body_dir: Vector3) -> float:
	return _generated_surface_radius(body_dir)


## The crust's radius along many WORLD directions at once. A walk over a box's cells asks once.
func surface_radii(dirs: PackedVector3Array) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	if _planet_gen == null:
		out.resize(dirs.size())
		out.fill(NAN)
		return out
	var body: PackedVector3Array = PackedVector3Array()
	body.resize(dirs.size())
	for i in dirs.size():
		body[i] = to_body_dir(dirs[i])
	out = _planet_gen.elevations_at(body)
	for i in out.size():
		out[i] += _planet_radius
	return out


## THE WATER'S free-surface radius along a WORLD direction; NAN where that column is dry.
func water_surface_radius(dir: Vector3) -> float:
	return water_radius(to_body_dir(dir))


## The same along many WORLD directions at once, NAN per dry column.
func water_radii(dirs: PackedVector3Array) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(dirs.size())
	for i in dirs.size():
		out[i] = water_radius(to_body_dir(dirs[i]))
	return out


## The body's own frame is the frame its shape is written in; the world frame is that one turned by the
## body's rotation. A direction given in one means a different place on the planet in the other.
func to_world_dir(body_dir: Vector3) -> Vector3:
	return body_dir if _terrain == null \
		else (_terrain.global_transform.basis.orthonormalized() * body_dir)


func to_body_dir(world_dir: Vector3) -> Vector3:
	return world_dir if _terrain == null \
		else (_terrain.global_transform.basis.orthonormalized().inverse() * world_dir)


## WHERE TO STAND A DEMO BOX SO IT HOLDS A SHORE, read off the fill over a few hundred directions at seed
## time. Vector3.ZERO when this body's surface holds none; asked with no footprint, the last box's site.
func coast_site_dir(footprint_m: float) -> Vector3:
	if footprint_m <= 0.0:
		return _coast_dir
	var g: Dictionary = LAPlanetComposition.coast_site(self, _planet_radius, footprint_m)
	_coast_dir = g.get("dir", Vector3.ZERO)
	return _coast_dir


## The coast site as a WORLD direction now: the body-frame site turned by the body's own rotation.
func coast_site_world_dir() -> Vector3:
	return Vector3.ZERO if _coast_dir == Vector3.ZERO else to_world_dir(_coast_dir)


## What the crust under a footprint at `d` is: the site rule is read off this reading.
func footprint_ground(d: Vector3, footprint_m: float) -> Dictionary:
	return LAPlanetComposition.footprint_ground(self, d, _planet_radius, footprint_m)


## Nodes across the fill lattice. The fill decides a LEVEL; the crust is compared against it at its own
## resolution, so a shoreline is as fine as the cells are.
## LA_APPROX: water_fill_lattice
const FILL_NLAT: int = 180
const FILL_NLON: int = 360


func _fill_water(water_m3: float) -> void:
	var elev: PackedFloat32Array = _planet_gen.elevation_lattice(FILL_NLAT, FILL_NLON)
	if elev.is_empty():
		push_error("VoxelTerrainService: the crust carries no elevation lattice, so the body's water has nowhere to settle.")
		return
	var f: Dictionary = LAWaterFill.solve(elev, FILL_NLAT, FILL_NLON, _planet_radius, water_m3)
	if f.is_empty():
		return
	_water_level = f["level_m"]
	_water_nlat = FILL_NLAT
	_water_nlon = FILL_NLON
	print("WATER_FILL=%s" % JSON.stringify({"bodies": f["bodies"], "basins": f["basins"],
		"wet_nodes": f["wet_nodes"], "nodes": FILL_NLAT * FILL_NLON}))


## The crust's radius along a body-frame direction: the mean radius plus the cascade's own elevation, the
## same expression the compiled SDF evaluates. NAN before the generator is built.
func _generated_surface_radius(dir: Vector3) -> float:
	if _planet_gen == null:
		return NAN
	var e: float = _planet_gen.elevation_at(dir)
	return NAN if is_nan(e) else _planet_radius + e


## PLANET: the world-space surface point along `dir` (centre + dir * surface_radius).
func surface_point(dir: Vector3) -> Vector3:
	var r: float = surface_radius(dir)
	return Vector3(NAN, NAN, NAN) if is_nan(r) else _center + dir.normalized() * r

## PLANET: height of a world point ABOVE the local ground (>0 in the air, <0 underground). NAN if unmeshed.
func altitude_at(pos: Vector3) -> float:
	var d: Vector3 = pos - _center
	var sr: float = surface_radius(d)
	return NAN if is_nan(sr) else d.length() - sr

## HOW FINELY THE GROUND UNDER `world_pos` IS DRAWN: voxel edge in metres of the finest meshed level of
## detail there, INF where none is. A drawn surface stands within about one of its own voxels of the real
## one, so this is the error bar on what a camera over it sees.
func meshed_resolution_at(world_pos: Vector3) -> float:
	if _terrain == null:
		return INF
	# THE BLOCK'S OWN MESH STATE, not whether its voxels are loaded: a loaded block whose surface the
	# mesher has not built yet draws nothing, and a shot taken against it photographs absent ground.
	var bs: int = int(_terrain.get_mesh_block_size())
	var local: Vector3 = _terrain.to_local(world_pos)
	for lod in range(_terrain.lod_count):
		var step: float = float(bs << lod)
		var bp: Vector3i = Vector3i(int(floor(local.x / step)), int(floor(local.y / step)),
			int(floor(local.z / step)))
		var info: Dictionary = _terrain.debug_get_mesh_block_info(bp, lod)
		if bool(info.get("meshed", false)) and bool(info.get("visible", false)):
			return pow(2.0, float(lod))
	return INF


func _make_material() -> ShaderMaterial:
	var mat: ShaderMaterial = ShaderMaterial.new()
	var sh: Shader = load(SHADER_PATH) as Shader
	if sh != null:
		mat.shader = sh
	return mat
