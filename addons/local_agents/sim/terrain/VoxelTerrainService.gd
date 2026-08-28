class_name LAVoxelTerrainService
extends RefCounted


const SHADER_PATH: String = "res://addons/local_agents/sim/shaders/VoxelTerrainTriplanar.gdshader"
const PlanetGenScript: GDScript = preload("res://addons/local_agents/sim/terrain/SpherePlanetGenerator.gd")

const MAX_LOD: int = 23                   # godot_voxel's cap: VoxelLodTerrain rejects lod_count >= 24

var _terrain: VoxelLodTerrain = null
var _generator: VoxelGeneratorGraph = null   # the planet's SDF, queryable before anything is meshed
var _viewer: VoxelViewer = null
var _query_tool: VoxelTool = null          # cached SDF sampler for is_solid / sdf_at (the 3D-field rock test)
var _gen_opts: Dictionary = {}             # the dict build_planet handed LASpherePlanetGenerator.build()
var _center: Vector3 = Vector3.ZERO
var _planet_radius: float = 0.0
var _relief_ceiling: float = 0.0       # sum of every relief amplitude the generator adds to the sphere
var _sea_radius: float = 0.0

## Planet centre in world space (origin by default). Only meaningful in planet mode.
func planet_center() -> Vector3:
	return _center

## Mean solid radius of the planet (world units from centre). 0 in island mode.
func planet_radius() -> float:
	return _planet_radius

## Radius of the spherical sea shell (world units from centre). 0 in island mode.
func sea_radius() -> float:
	return _sea_radius

## Highest radius the terrain reaches: mean radius plus every relief amplitude. Nothing solid is above it.
func max_surface_radius() -> float:
	return _planet_radius + _relief_ceiling

## Local "up" at a world point: radial from the planet centre.
func up_at(pos: Vector3) -> Vector3:
	var r: Vector3 = pos - _center
	return r.normalized() if r.length() > 0.001 else Vector3.UP


func build_planet(parent: Node3D, opts: Dictionary = {}) -> void:
	if _terrain != null:
		return
	_center = opts.get("center", Vector3.ZERO)
	var pg: RefCounted = PlanetGenScript.new()
	var relief: float = float(opts.get("relief", 46.0))
	var feature: float = float(opts.get("feature_size", 155.0))
	var detail_relief: float = float(opts.get("detail_relief", 6.0))
	# TERRAIN IS SELF-AFFINE: the fine layer stands at the same slope as the continental one, so its
	# wavelength follows this world's own relief, not a default written for a different-sized body.
	var detail_size: float = float(opts.get("detail_size", feature * detail_relief / maxf(relief, 0.001)))
	var gen_opts: Dictionary = {
		"radius": float(opts.get("radius", 250.0)),
		"sea_radius": opts.get("sea_radius", float(opts.get("radius", 250.0))),
		"ocean_bias": float(opts.get("ocean_bias", 7.0)),
		"relief": relief,
		"feature_size": feature,
		"detail_relief": detail_relief,
		"detail_size": detail_size,
		"basin_relief": float(opts.get("basin_relief", 0.0)),
		"basin_size": float(opts.get("basin_size", 130.0)),
		"ridge_relief": float(opts.get("ridge_relief", 0.0)),
		"ridge_size": float(opts.get("ridge_size", 90.0)),
		"ridge_octaves": int(opts.get("ridge_octaves", 4)),
		# Fractal cave tunnels (see LASpherePlanetGenerator); caves_enabled=false / LA_CAVES=0 disables them.
		"caves_enabled": bool(opts.get("caves_enabled", true)),
		"cave_size": float(opts.get("cave_size", 70.0)),
		"cave_threshold": float(opts.get("cave_threshold", 0.08)),
		"cave_strength": float(opts.get("cave_strength", 40.0)),
		"cave_depth_fade": float(opts.get("cave_depth_fade", 24.0)),
		"octaves": int(opts.get("octaves", 3)),
		"seed": int(opts.get("seed", 1337)),
	}
	var gen: VoxelGeneratorGraph = pg.build(gen_opts)
	_relief_ceiling = relief + detail_relief + float(gen_opts["basin_relief"]) + float(gen_opts["ridge_relief"])
	_planet_radius = pg.radius()
	_sea_radius = pg.sea_radius()
	_generator = gen

	var mesher: VoxelMesherTransvoxel = VoxelMesherTransvoxel.new()

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
	# THE LOD PYRAMID SPANS THE BODY OR ITS FAR SIDE IS NEVER MESHED. The coarsest level reaches
	# lod_distance * 2^(lod_count-1) metres, and the body is metres of real radius, so the count is read
	# off the radius rather than typed. A viewer sees the whole body: the far limb stands 2R away.
	var lod_dist: float = float(opts.get("lod_distance", 56.0))
	terrain.lod_distance = lod_dist
	terrain.lod_count = clampi(int(ceil(log(maxf(_planet_radius, lod_dist) / lod_dist) / log(2.0))) + 1,
		1, MAX_LOD)
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


## Signed distance to the rock surface at a world point: negative INSIDE rock, positive in air/void.
## 999 when the terrain is unavailable. Reads edited data (post-carve), so caves read as void.
func sdf_at(pos: Vector3) -> float:
	if _query_tool == null and _terrain != null:
		_query_tool = _terrain.get_voxel_tool()
		if _query_tool != null:
			_query_tool.set_channel(VoxelBuffer.CHANNEL_SDF)
	if _query_tool == null:
		return 999.0
	# VoxelTool samples in the terrain's LOCAL/voxel space; convert the world query so is_solid is correct
	# when the body is rotated (a spinning planet). No-op at identity (island / unrotated planet).
	return _query_tool.get_voxel_f_interpolated(_terrain.to_local(pos))


func is_solid(pos: Vector3) -> bool:
	return sdf_at(pos) < 0.0


# A low-poly rock baked to a VoxelMeshSDF once, reused for every polygon stamp (do_mesh).
var _rock_sdf: VoxelMeshSDF = null

func _rock_mesh_sdf() -> VoxelMeshSDF:
	if _rock_sdf != null:
		return _rock_sdf
	var m: BoxMesh = BoxMesh.new()               # an angular block → faceted rock once rotated
	m.size = Vector3(2.0, 2.0, 2.0)
	var sdf: VoxelMeshSDF = VoxelMeshSDF.new()
	sdf.set_mesh(m)
	sdf.set_cell_count(24)
	sdf.bake()
	_rock_sdf = sdf
	return _rock_sdf


## Stamp an oriented faceted ROCK (a POLYGON mesh, not a sphere) into the terrain: up-axis aligned to
## `normal` with a random spin, scaled by `size` and flattened, so solidified lava reads as angular
## rock conforming to the slope it cooled on — never round blobs or axis-aligned Minecraft steps.
func fill_rock(world_pos: Vector3, size: float, normal: Vector3) -> void:
	if _terrain == null:
		return
	var vt: VoxelTool = _terrain.get_voxel_tool()
	if vt == null:
		return
	var sdf: VoxelMeshSDF = _rock_mesh_sdf()
	if sdf == null:
		return
	var up: Vector3 = normal.normalized()
	if up.length() < 0.5:
		up = Vector3.UP
	var ref: Vector3 = Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var right: Vector3 = up.cross(ref).normalized()
	var fwd: Vector3 = right.cross(up).normalized()
	var b: Basis = Basis(right, up, fwd)
	b = b.rotated(up, LASimRng.for_domain("planet").randf() * TAU)   # spin so no two rocks align
	b = b.scaled(Vector3(size, size * 0.55, size))      # flatter than tall → a crust, not a boulder
	vt.set_channel(VoxelBuffer.CHANNEL_SDF)
	vt.set_mode(VoxelTool.MODE_ADD)
	# do_mesh takes a LOCAL/voxel-space transform; compose with the terrain's inverse world transform so the
	# rock lands correctly on a rotated/spinning body (no-op at identity).
	vt.do_mesh(sdf, _terrain.global_transform.affine_inverse() * Transform3D(b, world_pos), 0.0)

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

## PLANET: world radius of the solid surface along `dir`, solved from the SDF the body is generated from,
## so one direction gives one radius whatever a viewer has streamed. NAN when there is no terrain.
func surface_radius(dir: Vector3) -> float:
	return _generated_surface_radius(dir)


# Dry land is where the solid surface stands above the sea shell.
const LAND_SAMPLES: int = 128


## A direction from the centre where dry land stands above the sea shell, preferring the hemisphere
## `prefer` points into. Vector3.UP when the sweep finds none: this world's surface is all ocean.
func land_direction(prefer: Vector3 = Vector3.ZERO) -> Vector3:
	if _generator == null:
		return Vector3.UP
	# A Fibonacci sphere: even coverage from one deterministic sequence, no clustering at the poles.
	var golden: float = PI * (3.0 - sqrt(5.0))
	var found: Vector3 = Vector3.UP
	for i in range(LAND_SAMPLES):
		var y: float = 1.0 - 2.0 * (float(i) + 0.5) / float(LAND_SAMPLES)
		var d: Vector3 = Vector3(cos(golden * i), 0.0, sin(golden * i)) * sqrt(maxf(0.0, 1.0 - y * y)) + Vector3.UP * y
		if surface_radius(d) <= _sea_radius:
			continue
		found = d
		if prefer.length() < 0.001 or d.dot(prefer.normalized()) > 0.4:
			break
	return found


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
	var r_bot: float = maxf(_planet_radius - _relief_ceiling - SURFACE_RAY_MARGIN, 1.0)
	var r_a: float = r_top
	var r_b: float = r_bot
	var r_hit: float = NAN
	for stride in [GEN_RAY_COARSE, GEN_RAY_STRIDE, GEN_RAY_REFINE]:
		var hit: float = _generator.raycast_sdf_approx(_center + d * r_a, _center + d * r_b, stride)
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
	var e: float = float(_terrain.get_mesh_block_size())
	var box: AABB = AABB(_terrain.to_local(world_pos) - Vector3(e, e, e), Vector3(e, e, e) * 2.0)
	for lod in range(_terrain.lod_count):
		if _terrain.is_area_meshed(box, lod):
			return pow(2.0, float(lod))
	return INF


func _make_material() -> ShaderMaterial:
	var mat: ShaderMaterial = ShaderMaterial.new()
	var sh: Shader = load(SHADER_PATH) as Shader
	if sh != null:
		mat.shader = sh
	return mat
