class_name LAVoxelTerrainService
extends RefCounted

## Terrain foundation for the from-scratch voxel simulation showcase.
## Wraps a native VoxelLodTerrain (Transvoxel + heightmap noise) and exposes the
## build/query/destruction API defined in the build contract. Everyone else CALLS this.

const SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/shaders/VoxelTerrainTriplanar.gdshader"

var _terrain: VoxelLodTerrain = null
var _viewer: VoxelViewer = null

## Build a large natural terrain as a child of `parent`.
## opts (all optional): seed, lod_count, lod_distance, view_distance, period,
## height_start, height_range.
func build(parent: Node3D, opts: Dictionary = {}) -> void:
	if _terrain != null:
		return

	var seed_val: int = int(opts.get("seed", 1337))
	var lod_count: int = int(opts.get("lod_count", 4))
	var lod_distance: float = float(opts.get("lod_distance", 48.0))
	var view_distance: int = int(opts.get("view_distance", 512))
	var period: float = float(opts.get("period", 220.0))
	var height_start: float = float(opts.get("height_start", -30.0))
	var height_range: float = float(opts.get("height_range", 180.0))

	# Fractal FBM noise: low frequency => broad rolling landmasses.
	# VoxelGeneratorNoise2D.noise is typed as Godot's built-in `Noise`, so use FastNoiseLite
	# (built-in), not godot_voxel's ZN_FastNoiseLite. `frequency` = 1/period.
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = seed_val
	noise.frequency = 1.0 / maxf(1.0, period)
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 5
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5

	# Curve shapes normalized noise into gentle hills with occasional mountains.
	var curve := Curve.new()
	curve.min_value = 0.0
	curve.max_value = 1.0
	curve.add_point(Vector2(0.0, 0.05))
	curve.add_point(Vector2(0.45, 0.22))
	curve.add_point(Vector2(0.75, 0.50))
	curve.add_point(Vector2(1.0, 1.0))

	var gen := VoxelGeneratorNoise2D.new()
	gen.noise = noise
	gen.curve = curve
	gen.channel = VoxelBuffer.CHANNEL_SDF
	gen.height_start = height_start
	gen.height_range = height_range

	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = 0 # TEXTURES_NONE; we color via the triplanar shader.

	var terrain := VoxelLodTerrain.new()
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
	var half_xz: int = int(opts.get("bounds_half_xz", 224))
	var y_min: int = int(opts.get("bounds_y_min", -64))
	var y_max: int = int(opts.get("bounds_y_max", 192))
	terrain.voxel_bounds = AABB(
		Vector3(-half_xz, y_min, -half_xz),
		Vector3(half_xz * 2, y_max - y_min, half_xz * 2))
	terrain.full_load_mode_enabled = true
	parent.add_child(terrain)
	_terrain = terrain

## The VoxelLodTerrain node (null before build()).
func terrain_node() -> Node:
	return _terrain

## Add a VoxelViewer under `camera` so terrain streams/meshes/collides around it.
func attach_viewer(camera: Node3D) -> void:
	if camera == null:
		return
	var viewer := VoxelViewer.new()
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
	var vt := _terrain.get_voxel_tool()
	if vt == null:
		return
	vt.set_channel(VoxelBuffer.CHANNEL_SDF)
	vt.set_mode(mode)
	vt.do_sphere(world_pos, radius)

## Physics-space raycast against the terrain body (collision_mask=1).
## Returns {"hit": bool, "position": Vector3, "normal": Vector3}.
func raycast_terrain(from: Vector3, dir: Vector3, max_distance: float) -> Dictionary:
	var miss := {"hit": false, "position": Vector3.ZERO, "normal": Vector3.UP}
	if _terrain == null:
		return miss
	var world := _terrain.get_world_3d()
	if world == null:
		return miss
	var space := world.direct_space_state
	if space == null:
		return miss
	var to := from + dir.normalized() * max_distance
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return miss
	return {"hit": true, "position": hit.position, "normal": hit.normal}

## World Y of the terrain surface at (x, z) via a downward physics ray.
## Returns NAN when the area is unmeshed or the ray misses.
func surface_height(x: float, z: float, top: float = 300.0) -> float:
	var res := raycast_terrain(Vector3(x, top, z), Vector3.DOWN, top + 600.0)
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
	var mat := ShaderMaterial.new()
	var sh := load(SHADER_PATH) as Shader
	if sh != null:
		mat.shader = sh
	return mat
