class_name LAVoxelTerrainService
extends RefCounted

## Terrain foundation for the from-scratch voxel simulation showcase.
## Wraps a native VoxelLodTerrain (Transvoxel + heightmap noise) and exposes the
## build/query/destruction API defined in the build contract. Everyone else CALLS this.

const SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/shaders/VoxelTerrainTriplanar.gdshader"
const PlanetGenScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/sphere/SpherePlanetGenerator.gd")

# --- Sea + cave-placement reference (world units). The planet's own terrain SDF comes from the sphere
# generator; these remain as the default sea surface and the land radius that carve_caves uses to place
# cave mouths. (Explicit types only — no ':=' inferred typing.)
const ISLAND_RADIUS: float = 180.0        # land core radius (world units) — used to place caves
const SEA_LEVEL_Y: float = 6.0            # world Y of the sea surface (default sea level)

var _terrain: VoxelLodTerrain = null
var _viewer: VoxelViewer = null
var _query_tool: VoxelTool = null          # cached SDF sampler for is_solid / sdf_at (the 3D-field rock test)
var _sea_level: float = SEA_LEVEL_Y
var _island_radius: float = ISLAND_RADIUS

# --- Planet shape (spherical world). `_shape` is "island" only as the pre-build placeholder; build_planet
# sets it to "planet", where "up" is radial (pos-_center).normalized(), the surface is a sphere of radius
# ~_planet_radius, and the sea is a shell at _sea_radius. sdf_at/is_solid/carve_sphere/fill_* stay world-space.
var _shape: String = "island"
var _center: Vector3 = Vector3.ZERO
var _planet_radius: float = 0.0
var _planet_relief: float = 0.0
var _sea_radius: float = 0.0

## True when this terrain is a spherical planet (radial up) rather than the flat island (+Y up).
func is_planet() -> bool:
	return _shape == "planet"

## Planet centre in world space (origin by default). Only meaningful in planet mode.
func planet_center() -> Vector3:
	return _center

## Mean solid radius of the planet (world units from centre). 0 in island mode.
func planet_radius() -> float:
	return _planet_radius

## Radius of the spherical sea shell (world units from centre). 0 in island mode.
func sea_radius() -> float:
	return _sea_radius

## Local "up" at a world point: radial from the planet centre.
func up_at(pos: Vector3) -> Vector3:
	var r: Vector3 = pos - _center
	return r.normalized() if r.length() > 0.001 else Vector3.UP

## World Y of the sea surface this terrain was shaped around (the ocean plane / MaterialField sea_level).
func sea_level() -> float:
	return _sea_level

## Land-core radius (world units) the island was shaped with — used to place caves/springs on land.
func island_radius() -> float:
	return _island_radius

## Build a SPHERICAL PLANET as a child of `parent` (radial up, magma-core-ready).
## opts: radius, sea_radius, relief, feature_size, octaves, seed, center, lod_count, lod_distance,
## view_distance. The terrain SDF comes from the native LASpherePlanetGenerator; sphere-enclosing bounds
## keep the whole body resident so off-camera edits (impacts, eruptions) apply anywhere.
func build_planet(parent: Node3D, opts: Dictionary = {}) -> void:
	if _terrain != null:
		return
	_shape = "planet"
	_center = opts.get("center", Vector3.ZERO)
	_planet_relief = float(opts.get("relief", 46.0))

	var pg: RefCounted = PlanetGenScript.new()
	var gen: VoxelGeneratorGraph = pg.build({
		"radius": float(opts.get("radius", 250.0)),
		"sea_radius": opts.get("sea_radius", float(opts.get("radius", 250.0))),
		"ocean_bias": float(opts.get("ocean_bias", 7.0)),
		"relief": _planet_relief,
		"feature_size": float(opts.get("feature_size", 155.0)),
		"octaves": int(opts.get("octaves", 3)),
		"seed": int(opts.get("seed", 1337)),
	})
	_planet_radius = pg.radius()
	_sea_radius = pg.sea_radius()

	var mesher: VoxelMesherTransvoxel = VoxelMesherTransvoxel.new()
	mesher.texturing_mode = 0

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
	terrain.lod_count = int(opts.get("lod_count", 5))
	terrain.lod_distance = float(opts.get("lod_distance", 56.0))
	terrain.view_distance = int(opts.get("view_distance", 2000))
	terrain.generate_collisions = true
	terrain.collision_layer = 1
	terrain.collision_mask = 0
	var rr: float = _planet_radius + _planet_relief + 80.0     # sphere-enclosing box (+ atmosphere headroom)
	terrain.voxel_bounds = AABB(
		_center - Vector3(rr, rr, rr), Vector3(rr * 2.0, rr * 2.0, rr * 2.0))
	terrain.full_load_mode_enabled = true
	parent.add_child(terrain)
	_terrain = terrain


## The VoxelLodTerrain node (null before build_planet()).
func terrain_node() -> Node:
	return _terrain


## Set a uniform on the terrain's triplanar shader material (e.g. the temperature texture that makes
## hot ground glow, or the heat-debug toggle). No-op before build().
func set_shader_param(param: String, value) -> void:
	if _terrain != null and _terrain.material is ShaderMaterial:
		(_terrain.material as ShaderMaterial).set_shader_parameter(param, value)

## Add a VoxelViewer under `camera` so terrain streams/meshes/collides around it.
func attach_viewer(camera: Node3D) -> void:
	if camera == null:
		return
	var viewer: VoxelViewer = VoxelViewer.new()
	viewer.view_distance = _terrain.view_distance if _terrain != null else 512
	viewer.requires_visuals = true
	viewer.requires_collisions = true
	camera.add_child(viewer)
	_viewer = viewer

## Destruction: remove SDF matter inside the sphere.
func carve_sphere(world_pos: Vector3, radius: float) -> void:
	_edit_sphere(world_pos, radius, VoxelTool.MODE_REMOVE)

## Add SDF matter inside the sphere.
func fill_sphere(world_pos: Vector3, radius: float) -> void:
	_edit_sphere(world_pos, radius, VoxelTool.MODE_ADD)

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


# --- Solidity query (the 3D field's rock/void test) --------------------------

# Cached SDF sampler bound to the terrain. get_voxel_f_interpolated reads the EDITED voxel data (so a
# carved cave/tube reads as void), which is exactly what the 3D MaterialField needs to know where fluids
# can occupy space vs where solid rock blocks them.
func _query_voxel_tool() -> VoxelTool:
	if _query_tool == null and _terrain != null:
		_query_tool = _terrain.get_voxel_tool()
		if _query_tool != null:
			_query_tool.set_channel(VoxelBuffer.CHANNEL_SDF)
	return _query_tool


## Signed distance to the rock surface at a world point: negative INSIDE rock, positive in air/void.
## 999 when the terrain is unavailable. Reads edited data (post-carve), so caves read as void.
func sdf_at(pos: Vector3) -> float:
	var vt: VoxelTool = _query_voxel_tool()
	if vt == null:
		return 999.0
	# VoxelTool samples in the terrain's LOCAL/voxel space; convert the world query so is_solid is correct
	# when the body is rotated (a spinning planet). No-op at identity (island / unrotated planet).
	return vt.get_voxel_f_interpolated(_terrain.to_local(pos))


## True where solid rock fills a world point — the primitive the 3D field uses to know rock vs void
## (open air, an underground cavern, a lava tube). Solid = SDF < 0.
func is_solid(pos: Vector3) -> bool:
	return sdf_at(pos) < 0.0


## Add a FLAT SDF box (world-space AABB centred at world_pos, given half extents). Used to build
## flat-topped deposits — e.g. solidifying lava layers that tile into a continuous rocky surface,
## instead of the rounded blobs a sphere leaves.
func fill_box(world_pos: Vector3, half_extents: Vector3) -> void:
	if _terrain == null:
		return
	var vt: VoxelTool = _terrain.get_voxel_tool()
	if vt == null:
		return
	vt.set_channel(VoxelBuffer.CHANNEL_SDF)
	vt.set_mode(VoxelTool.MODE_ADD)
	# Local/voxel-space AABB (correct under a rotated/spinning body; no-op at identity).
	var lp: Vector3 = _terrain.to_local(world_pos)
	vt.do_box(lp - half_extents, lp + half_extents)


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
	b = b.rotated(up, randf() * TAU)                    # random spin so no two rocks align (no grid look)
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

## The solid surface point directly beneath/above a WORLD point — re-seat it onto the ground along its own
## radial (centre→pos). NAN-vector if that patch is unmeshed. Replaces the old downward surface_height cast,
## which only hit at the +Y pole (a straight-down ray misses everywhere else on a sphere). Callers that want
## the local ground altitude use altitude_at(pos); those re-seating onto the surface use this.
func ground_point(pos: Vector3) -> Vector3:
	return surface_point(pos - _center)

## PLANET: world radius (distance from centre) of the solid surface along direction `dir`, via an inward
## radial physics ray from above the surface toward the core. NAN if that patch is unmeshed / the ray misses.
func surface_radius(dir: Vector3) -> float:
	var d: Vector3 = dir.normalized()
	var top: float = _planet_radius + _planet_relief + 60.0
	var from: Vector3 = _center + d * top
	var res: Dictionary = raycast_terrain(from, -d, top)      # cast inward toward the core
	if not res["hit"]:
		return NAN
	return (res["position"] - _center).length()

## PLANET: the world-space surface point along `dir` (centre + dir * surface_radius). NAN-vector if unmeshed.
func surface_point(dir: Vector3) -> Vector3:
	var r: float = surface_radius(dir)
	if is_nan(r):
		return Vector3(NAN, NAN, NAN)
	return _center + dir.normalized() * r

## PLANET: height of a world point ABOVE the local ground (>0 in the air, <0 underground). NAN if unmeshed.
func altitude_at(pos: Vector3) -> float:
	var d: Vector3 = pos - _center
	var sr: float = surface_radius(d)
	if is_nan(sr):
		return NAN
	return d.length() - sr

## True if terrain is meshed + collidable near world_pos.
func is_ready_at(world_pos: Vector3) -> bool:
	if _terrain == null:
		return false
	return not is_nan(surface_radius(world_pos - _center))

func _make_material() -> ShaderMaterial:
	var mat: ShaderMaterial = ShaderMaterial.new()
	var sh: Shader = load(SHADER_PATH) as Shader
	if sh != null:
		mat.shader = sh
	return mat
