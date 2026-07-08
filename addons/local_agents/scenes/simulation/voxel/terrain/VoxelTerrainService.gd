class_name LAVoxelTerrainService
extends RefCounted

## Terrain foundation for the from-scratch voxel simulation showcase.
## Wraps a native VoxelLodTerrain (Transvoxel + heightmap noise) and exposes the
## build/query/destruction API defined in the build contract. Everyone else CALLS this.

const SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/shaders/VoxelTerrainTriplanar.gdshader"
const PlanetGenScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/sphere/SpherePlanetGenerator.gd")

# --- Island shaping (world units). The terrain is a single landmass rising out of an ocean: a broad
# FBM landmass in the interior, radially faded down to a seabed well below sea level past the coast, so
# the coastline (where the heightfield crosses SEA_LEVEL_Y) and its beaches EMERGE from the height field
# rather than being placed. Everything is baked once into a heightmap Image and generated NATIVELY by
# VoxelGeneratorImage — no per-voxel GDScript. (Explicit types only — no ':=' inferred typing.)
const ISLAND_RADIUS: float = 180.0        # land core radius (world units from origin)
const COAST_WIDTH: float = 60.0           # radial band over which land fades to seabed (the shore ramp)
const SEA_LEVEL_Y: float = 6.0            # world Y of the sea surface (the ocean plane sits here)
const HEIGHT_START: float = -70.0         # world Y of image value 0.0 (deep seabed floor)
const HEIGHT_RANGE: float = 280.0         # world Y span of image value 0..1 (peaks reach HEIGHT_START+RANGE)

var _terrain: VoxelLodTerrain = null
var _viewer: VoxelViewer = null
var _query_tool: VoxelTool = null          # cached SDF sampler for is_solid / sdf_at (the 3D-field rock test)
var _sea_level: float = SEA_LEVEL_Y
var _island_radius: float = ISLAND_RADIUS

# --- Planet shape (spherical world). Additive: island mode is unchanged when _shape=="island".
# When _shape=="planet", "up" is radial (pos-_center).normalized(), the surface is a sphere of radius
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

## Local "up" at a world point: radial on a planet, +Y on the island.
func up_at(pos: Vector3) -> Vector3:
	if _shape == "planet":
		var r: Vector3 = pos - _center
		return r.normalized() if r.length() > 0.001 else Vector3.UP
	return Vector3.UP

## World Y of the sea surface this terrain was shaped around (the ocean plane / MaterialField sea_level).
func sea_level() -> float:
	return _sea_level

## Land-core radius (world units) the island was shaped with — used to place caves/springs on land.
func island_radius() -> float:
	return _island_radius

## Build a large natural terrain as a child of `parent`.
## opts (all optional): seed, lod_count, lod_distance, view_distance, period,
## island_radius, coast_width, sea_level.
func build(parent: Node3D, opts: Dictionary = {}) -> void:
	if _terrain != null:
		return

	var seed_val: int = int(opts.get("seed", 1337))
	var lod_count: int = int(opts.get("lod_count", 4))
	var lod_distance: float = float(opts.get("lod_distance", 48.0))
	var view_distance: int = int(opts.get("view_distance", 512))
	var period: float = float(opts.get("period", 200.0))
	var island_radius: float = float(opts.get("island_radius", ISLAND_RADIUS))
	var coast_width: float = float(opts.get("coast_width", COAST_WIDTH))
	_sea_level = float(opts.get("sea_level", SEA_LEVEL_Y))
	_island_radius = island_radius

	var half_xz: int = int(opts.get("bounds_half_xz", 224))
	var y_min: int = int(opts.get("bounds_y_min", -80))
	var y_max: int = int(opts.get("bounds_y_max", 224))

	# Bake the island heightmap (native FBM image + radial falloff) and feed it to a native
	# VoxelGeneratorImage — one image sampled over the whole play area, centred on the origin.
	var img: Image = _bake_island_image(half_xz * 2, seed_val, period, island_radius, coast_width)
	var gen: VoxelGeneratorImage = VoxelGeneratorImage.new()
	gen.image = img
	gen.channel = VoxelBuffer.CHANNEL_SDF
	gen.height_start = HEIGHT_START
	gen.height_range = HEIGHT_RANGE
	# Centre the image on the origin: world (x,z) samples pixel (x+half, z+half).
	gen.offset = Vector2i(half_xz, half_xz)
	gen.blur_enabled = true

	var mesher: VoxelMesherTransvoxel = VoxelMesherTransvoxel.new()
	mesher.texturing_mode = 0 # TEXTURES_NONE; we color via the triplanar shader.

	var terrain: VoxelLodTerrain = VoxelLodTerrain.new()
	terrain.name = "VoxelTerrain"
	terrain.mesher = mesher
	terrain.generator = gen
	terrain.material = _make_material()
	terrain.lod_count = lod_count
	terrain.lod_distance = lod_distance
	terrain.view_distance = view_distance
	terrain.generate_collisions = true
	terrain.collision_layer = 1
	terrain.collision_mask = 0
	# Keep ALL voxel data resident within a bounded (but large) play area so edits apply
	# anywhere — including off-camera meteor strikes — not just near the viewer's LOD0 range.
	# Meshing/collision stay lazy near viewers; only the SDF data is fully loaded.
	terrain.voxel_bounds = AABB(
		Vector3(-half_xz, y_min, -half_xz),
		Vector3(half_xz * 2, y_max - y_min, half_xz * 2))
	terrain.full_load_mode_enabled = true
	parent.add_child(terrain)
	_terrain = terrain


## Build a SPHERICAL PLANET as a child of `parent` (radial up, magma-core-ready).
## opts: radius, sea_radius, relief, feature_size, octaves, seed, center, lod_count, lod_distance,
## view_distance. The terrain SDF comes from the native LASpherePlanetGenerator; sphere-enclosing bounds
## keep the whole body resident so off-camera edits (impacts, eruptions) apply anywhere.
func build_planet(parent: Node3D, opts: Dictionary = {}) -> void:
	if _terrain != null:
		return
	_shape = "planet"
	_center = opts.get("center", Vector3.ZERO)
	_planet_relief = float(opts.get("relief", 16.0))

	var pg: RefCounted = PlanetGenScript.new()
	var gen: VoxelGeneratorGraph = pg.build({
		"radius": float(opts.get("radius", 250.0)),
		"sea_radius": opts.get("sea_radius", float(opts.get("radius", 250.0)) * 0.93),
		"relief": _planet_relief,
		"feature_size": float(opts.get("feature_size", 78.0)),
		"octaves": int(opts.get("octaves", 4)),
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


# Bake the island heightmap: a normalised FBM landmass (native FastNoiseLite.get_image) radially faded
# to a seabed past the coast. Returns an RF Image whose red channel is the height fraction [0,1] that
# VoxelGeneratorImage maps to world Y via HEIGHT_START + value * HEIGHT_RANGE. `size` = image side in
# world units (1 px = 1 unit), centred on the origin.
func _bake_island_image(size: int, seed_val: int, period: float, island_radius: float, coast_width: float) -> Image:
	var noise: FastNoiseLite = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = seed_val
	noise.frequency = 1.0 / maxf(1.0, period)
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	# Fewer octaves + lower gain => broad, gentle rolling hills rather than jagged mountains everywhere.
	noise.fractal_octaves = 4
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.42
	# Native FBM sample of the whole plane in one call (normalised to [0,1]).
	var nimg: Image = noise.get_image(size, size, false, false, true)

	# Height fractions (of HEIGHT_START..HEIGHT_START+HEIGHT_RANGE) for the two regimes.
	# Seabed sits clearly below the sea; land rises well above it, so the coast crosses SEA_LEVEL_Y.
	var sea_frac: float = (_sea_level - HEIGHT_START) / HEIGHT_RANGE      # fraction at the waterline
	var seabed_lo: float = ((-46.0) - HEIGHT_START) / HEIGHT_RANGE        # deepest seabed
	var seabed_hi: float = ((-12.0) - HEIGHT_START) / HEIGHT_RANGE        # shallow seabed near shore
	# A gentle, mostly-green isle: low rolling land with only a few modest hills, not mountains.
	var land_lo: float = ((_sea_level + 2.0) - HEIGHT_START) / HEIGHT_RANGE   # lowest land (just above beach)
	var land_hi: float = ((78.0) - HEIGHT_START) / HEIGHT_RANGE           # highest hilltops

	var img: Image = Image.create(size, size, false, Image.FORMAT_RF)
	var half: float = float(size) * 0.5
	var edge0: float = island_radius
	var edge1: float = island_radius + coast_width
	for py in range(size):
		var z: float = float(py) - half
		for px in range(size):
			var x: float = float(px) - half
			var r: float = sqrt(x * x + z * z)
			# Land mask: 1 inside the core, smoothly to 0 past the coast band.
			var t: float = clampf((edge1 - r) / coast_width, 0.0, 1.0)
			var s: float = t * t * (3.0 - 2.0 * t)
			# Bias the height distribution toward the low end so most of the isle is gentle lowland and
			# only a few spots rise into hills (a flatter, less mountainous island).
			var n: float = pow(nimg.get_pixel(px, py).r, 1.5)
			var seabed: float = lerpf(seabed_lo, seabed_hi, n)
			var land: float = lerpf(land_lo, land_hi, n)
			var hf: float = clampf(lerpf(seabed, land, s), 0.0, 1.0)
			img.set_pixel(px, py, Color(hf, 0.0, 0.0))
	return img


## The VoxelLodTerrain node (null before build()).
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
	vt.do_sphere(world_pos, radius)


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
	return vt.get_voxel_f_interpolated(pos)


## True where solid rock fills a world point — the primitive the 3D field uses to know rock vs void
## (open air, an underground cavern, a lava tube). Solid = SDF < 0.
func is_solid(pos: Vector3) -> bool:
	return sdf_at(pos) < 0.0


# --- 3D caves ---------------------------------------------------------------
# Real 3D voids carved into the SDF (surface entrances winding down into tunnels + chambers), so the
# world is genuinely 3D: fluids can pour into a tube, water can pool in a cavern, gas can rise a shaft.
# Carved natively via do_sphere along noise-perturbed paths — a few sparse systems, cheap (~hundreds of
# edits total). Called once after the terrain has streamed.
const CAVE_SYSTEMS: int = 5
const CAVE_STEPS: int = 110
const CAVE_STEP_LEN: float = 2.3
const CAVE_RADIUS: float = 2.8

func carve_caves(seed_val: int) -> void:
	if _terrain == null:
		return
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_val
	var wander: FastNoiseLite = FastNoiseLite.new()
	wander.seed = seed_val ^ 0x51ED
	wander.frequency = 0.03
	for sys in range(CAVE_SYSTEMS):
		# Entrance: a point on the island's land (well inside the coast) — carve a mouth from just above
		# the surface so the tunnel opens to daylight.
		var ang: float = rng.randf() * TAU
		var rr: float = rng.randf_range(28.0, _island_radius * 0.62)
		var ex: float = cos(ang) * rr
		var ez: float = sin(ang) * rr
		var ey: float = surface_height(ex, ez)
		if is_nan(ey) or ey <= _sea_level + 3.0:
			continue                                    # skip mouths that would open underwater
		var pos: Vector3 = Vector3(ex, ey + 1.5, ez)
		# Head inward and down into the hillside.
		var head: Vector3 = Vector3(-cos(ang) * 0.35, -0.72, -sin(ang) * 0.35).normalized()
		for step in range(CAVE_STEPS):
			carve_sphere(pos, CAVE_RADIUS + rng.randf_range(-0.5, 1.0))
			if rng.randf() < 0.07:                       # occasional chamber
				carve_sphere(pos, CAVE_RADIUS * 2.3)
			# Wind the tunnel with 3D noise; bias gently downward so it descends into the isle.
			var nx: float = wander.get_noise_3d(pos.x, pos.y, pos.z)
			var ny: float = wander.get_noise_3d(pos.x + 137.0, pos.y - 71.0, pos.z)
			var nz: float = wander.get_noise_3d(pos.x, pos.y + 91.0, pos.z + 137.0)
			head = (head + Vector3(nx, ny * 0.5 - 0.12, nz) * 0.65).normalized()
			pos += head * CAVE_STEP_LEN
			# Keep tunnels inside the island body and out of the deep seabed; dive back under if the path
			# would break the surface mid-run (so we don't gash open trenches across the hillside).
			if Vector2(pos.x, pos.z).length() > _island_radius * 0.95:
				break
			if pos.y < _sea_level - 42.0:
				break
			var surf: float = surface_height(pos.x, pos.z)
			if not is_nan(surf) and pos.y > surf - 1.5:
				head.y = -absf(head.y) - 0.25
				head = head.normalized()

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
	vt.do_box(world_pos - half_extents, world_pos + half_extents)


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
	vt.do_mesh(sdf, Transform3D(b, world_pos), 0.0)

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

## World Y of the terrain surface at (x, z) via a downward physics ray.
## Returns NAN when the area is unmeshed or the ray misses.
func surface_height(x: float, z: float, top: float = 300.0) -> float:
	var res: Dictionary = raycast_terrain(Vector3(x, top, z), Vector3.DOWN, top + 600.0)
	if not res["hit"]:
		return NAN
	var pos: Vector3 = res["position"]
	return pos.y

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
	if _shape == "planet":
		return not is_nan(surface_radius(world_pos - _center))
	# Collision presence (a successful downward ray) is what actually gates spawning.
	return not is_nan(surface_height(world_pos.x, world_pos.z))

func _make_material() -> ShaderMaterial:
	var mat: ShaderMaterial = ShaderMaterial.new()
	var sh: Shader = load(SHADER_PATH) as Shader
	if sh != null:
		mat.shader = sh
	return mat
