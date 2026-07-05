class_name LAVoxelTerrainService
extends RefCounted

## Terrain foundation for the from-scratch voxel simulation showcase.
## Wraps a native VoxelLodTerrain (Transvoxel + heightmap noise) and exposes the
## build/query/destruction API defined in the build contract. Everyone else CALLS this.

const SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/shaders/VoxelTerrainTriplanar.gdshader"

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
var _sea_level: float = SEA_LEVEL_Y

## World Y of the sea surface this terrain was shaped around (the ocean plane / MaterialField sea_level).
func sea_level() -> float:
	return _sea_level

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

## True if terrain is meshed + collidable near world_pos.
func is_ready_at(world_pos: Vector3) -> bool:
	if _terrain == null:
		return false
	# Collision presence (a successful downward ray) is what actually gates spawning.
	return not is_nan(surface_height(world_pos.x, world_pos.z))

func _make_material() -> ShaderMaterial:
	var mat: ShaderMaterial = ShaderMaterial.new()
	var sh: Shader = load(SHADER_PATH) as Shader
	if sh != null:
		mat.shader = sh
	return mat
