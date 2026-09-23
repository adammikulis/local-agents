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
var _sea_radius: float = 0.0
var _coast_dir: Vector3 = Vector3.ZERO   # the coast site the last box asked for

## Planet centre in world space (origin by default). Only meaningful in planet mode.
func planet_center() -> Vector3:
	return _center

## Mean solid radius of the planet (world units from centre). 0 in island mode.
func planet_radius() -> float:
	return _planet_radius

## Radius of the spherical sea shell (world units from centre). 0 in island mode.
func sea_radius() -> float:
	return _sea_radius

## Highest radius the terrain reaches: the sea shell plus the highest elevation the declared hypsographic
## curve carries. Nothing solid stands above it.
func max_surface_radius() -> float:
	return _planet_radius + LAPhysical.HYPSOMETRY_HIGHEST_M

## Lowest radius the terrain reaches: the sea shell plus the deepest elevation the curve carries.
func min_surface_radius() -> float:
	return _planet_radius + LAPhysical.HYPSOMETRY_DEEPEST_M

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
		push_error("VoxelTerrainService: no hydrosphere declared or no water density, so the sea has no level.")
		return
	var sea_level: float = LAPlanetComposition.sea_level_m(float(opts.get("radius", 0.0)), (float(body["hydrosphere_kg"]) - float(body["groundwater_kg"])) / rho_w,
		PackedFloat64Array(LAPhysical.HYPSOMETRY_AREA_BELOW), PackedFloat64Array(LAPhysical.HYPSOMETRY_ELEVATION_M))
	var gen_opts: Dictionary = LAPlanetShape.opts(float(opts.get("radius", 0.0)), int(opts.get("seed", 1337)), bool(opts.get("caves_enabled", true)), sea_level)
	var gen: VoxelGeneratorGraph = pg.build(gen_opts)
	_planet_radius = pg.radius()
	_sea_radius = pg.sea_radius()
	_generator = gen

	var mesher: VoxelMesherTransvoxel = VoxelMesherTransvoxel.new()
	# TRANSVOXEL'S TRANSITION CELLS CLOSE THE STEP BETWEEN TWO LEVELS OF DETAIL; the terrain shader moves
	# their vertices onto the coarse surface.
	mesher.transitions_enabled = true

	var terrain: VoxelLodTerrain = VoxelLodTerrain.new()
	terrain.name = "VoxelTerrain"
	terrain.mesher = mesher
	terrain.generator = gen
	terrain.material = _make_material()
	# Tell the triplanar shader to band climate RADIALLY (snow/beach/slope keyed off height above the sea
	# shell + radial up) instead of by world-Y — else all the "snow" piles at the +Y pole.
	if terrain.material is ShaderMaterial:
		var tm: ShaderMaterial = terrain.material
		tm.set_shader_parameter("planet_enabled", 1.0)
		tm.set_shader_parameter("planet_center", _center)
		tm.set_shader_parameter("planet_sea_radius", _sea_radius)
	terrain.lod_count = _lod_count_for(terrain.lod_distance)
	terrain.view_distance = int(opts.get("view_distance", 8000))
	# NO COLLISION MESH: what stops a body is the field's ground, and a ray is marched through the SDF, so
	# nothing depends on which levels of detail a viewer has streamed.
	terrain.generate_collisions = false
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
	viewer.requires_collisions = false
	camera.add_child(viewer)
	_viewer = viewer

## Destruction: remove SDF matter inside the sphere.
func carve_sphere(world_pos: Vector3, radius: float) -> void:
	_edit_sphere(world_pos, radius, VoxelTool.MODE_REMOVE)

func _edit_sphere(world_pos: Vector3, radius: float, mode: int) -> void:
	if _terrain == null:
		return
	var vt: VoxelTool = _terrain.get_voxel_tool()
	if vt == null:
		return
	vt.set_channel(VoxelBuffer.CHANNEL_SDF)
	vt.set_mode(mode)
	# VoxelTool operates in the terrain's LOCAL/voxel space; convert so edits land correctly when the body
	# is rotated/translated (a spinning planet). At identity this is a no-op.
	vt.do_sphere(_terrain.to_local(world_pos), radius)


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


## Solidification: add SDF matter inside the sphere. The inverse of carve_sphere, at the same seam.
func fill_sphere(world_pos: Vector3, radius: float) -> void:
	_edit_sphere(world_pos, radius, VoxelTool.MODE_ADD)


## The first crossing of the body's SDF along a world ray, coarse to fine as surface_radius brackets it.
## Returns {"hit": bool, "position": Vector3, "normal": Vector3}; the normal is the radial up.
func raycast_terrain(from: Vector3, dir: Vector3, max_distance: float) -> Dictionary:
	var miss: Dictionary = {"hit": false, "position": Vector3.ZERO, "normal": Vector3.UP}
	if _generator == null or _terrain == null or max_distance <= 0.0:
		return miss
	var d: Vector3 = dir.normalized()
	var t_a: float = 0.0
	var t_b: float = max_distance
	var t_hit: float = NAN
	for stride in [GEN_RAY_COARSE, GEN_RAY_STRIDE, GEN_RAY_REFINE]:
		var hit: float = _generator.raycast_sdf_approx(
			_terrain.to_local(from + d * t_a), _terrain.to_local(from + d * t_b), stride)
		if hit < 0.0:
			break
		t_hit = t_a + hit
		t_a = maxf(t_hit - stride, 0.0)
		t_b = minf(t_hit + stride, max_distance)
	if is_nan(t_hit):
		return miss
	var at: Vector3 = from + d * t_hit
	return {"hit": true, "position": at, "normal": up_at(at)}

func ground_point(pos: Vector3) -> Vector3:
	return surface_point(pos - _center)

## PLANET: world radius of the solid surface along the WORLD direction `dir`, solved from the SDF the body
## is generated from, so one direction gives one radius whatever a viewer has streamed. NAN without terrain.
func surface_radius(dir: Vector3) -> float:
	return _generated_surface_radius(dir)


## The same radius along a direction fixed IN THE BODY: a place on the planet, which the world direction
## sweeps past as the body turns.
func body_surface_radius(body_dir: Vector3) -> float:
	return _generated_surface_radius(to_world_dir(body_dir))


## The body's own frame is the frame its SDF is written in; the world frame is that one turned by the
## body's rotation. A direction given in one means a different place on the planet in the other.
func to_world_dir(body_dir: Vector3) -> Vector3:
	return body_dir if _terrain == null \
		else (_terrain.global_transform.basis.orthonormalized() * body_dir)


## WHERE TO STAND A DEMO BOX SO IT HOLDS A SHORE, solved in LAPlanetComposition over a few hundred
## directions at seed time. Vector3.ZERO when this body's surface holds none; asked with no footprint,
## the site the last box chose.
func coast_site_dir(footprint_m: float) -> Vector3:
	if footprint_m <= 0.0:
		return _coast_dir
	print("SITE_CHOOSER_STANDIN=%s" % JSON.stringify({
		"file": "addons/local_agents/gdextensions/localagents/src/LAPlanetTables.cpp",
		"expr": "LAPlanetComposition::coast_site: la_surface_radius(dir) - p_sea_r_m",
		"replaced_by": "the hydrosphere fill's own liquid-at-surface columns"}))
	var g: Dictionary = LAPlanetComposition.coast_site(self, _planet_radius, _sea_radius, footprint_m)
	_coast_dir = g.get("dir", Vector3.ZERO)
	return _coast_dir


## The coast site as a WORLD direction now: the body-frame site turned by the body's own rotation.
func coast_site_world_dir() -> Vector3:
	return Vector3.ZERO if _coast_dir == Vector3.ZERO else to_world_dir(_coast_dir)


## What the crust under a footprint at `d` is: the site rule is read off this reading.
func footprint_ground(d: Vector3, footprint_m: float) -> Dictionary:
	return LAPlanetComposition.footprint_ground(self, d, _planet_radius, _sea_radius, footprint_m)


# Bracket the SDF crossing coarsely over the whole relief band, then twice across the bracket it found.
const GEN_RAY_COARSE: float = 32.0
const GEN_RAY_STRIDE: float = 1.0
const GEN_RAY_REFINE: float = 0.05
const SURFACE_RAY_MARGIN: float = GEN_RAY_COARSE   # air above the ceiling / below the floor to start in


func _generated_surface_radius(dir: Vector3) -> float:
	if _generator == null:
		return NAN
	var d: Vector3 = dir.normalized()
	var r_top: float = max_surface_radius() + SURFACE_RAY_MARGIN
	var r_bot: float = maxf(min_surface_radius() - SURFACE_RAY_MARGIN, 1.0)
	var r_a: float = r_top
	var r_b: float = r_bot
	var r_hit: float = NAN
	# The generator is sampled in the terrain's OWN space; every caller here speaks world.
	for stride in [GEN_RAY_COARSE, GEN_RAY_STRIDE, GEN_RAY_REFINE]:
		var hit: float = _generator.raycast_sdf_approx(
			_terrain.to_local(_center + d * r_a), _terrain.to_local(_center + d * r_b), stride)
		if hit < 0.0:
			return r_hit
		r_hit = r_a - hit
		r_a = minf(r_hit + stride, r_top)
		r_b = maxf(r_hit - stride, r_bot)
	return r_hit


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
