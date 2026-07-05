class_name LAOceanPlane
extends MeshInstance3D

## LAOceanPlane — the sea around the island, as ONE static GPU-shaded plane at sea level.
##
## The ocean is deliberately NOT part of the material-field CA: rendering a whole flooded seabed as a
## per-cell surface mesh every step is the one thing that would tank perf. Instead the sea is a single
## large plane that follows the camera in XZ (so it always reaches the horizon and its wave subdivisions
## stay near the view) while the waves themselves are computed in WORLD space in the shader — so the
## swell stays put on the water as the plane slides under the camera. Depth against the scene gives
## shallow->deep colour and an automatic foam line at the beaches. See shaders/VoxelOcean.gdshader.
## (Explicit types only — no ':=' inferred typing.)

const SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/shaders/VoxelOcean.gdshader"

# The plane RESIZES with zoom (size ≈ zoom distance × SIZE_PER_DISTANCE, clamped) so it always reaches
# the horizon when pulled way out, yet stays finely tessellated when zoomed in close. Subdivisions are
# fixed, so cell size grows with the plane; fine ripple detail comes from the fragment shader normals,
# and the large swell from the vertex displacement, so coarse far-cells still read as water.
const SUBDIVISIONS: int = 240
const SIZE_PER_DISTANCE: float = 9.0      # plane side = zoom distance × this
const MIN_PLANE_SIZE: float = 2400.0
const MAX_PLANE_SIZE: float = 24000.0

var _camera: Node3D = null
var _sea_y: float = 0.0
var _material: ShaderMaterial = null
var _plane: PlaneMesh = null
var _plane_size: float = 0.0


## Build the ocean plane at world Y `sea_y`, following `camera` in XZ. Added as a child of the caller.
func setup(sea_y: float, camera: Node3D) -> void:
	_sea_y = sea_y
	_camera = camera
	name = "OceanPlane"
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_plane = PlaneMesh.new()
	_plane.subdivide_width = SUBDIVISIONS
	_plane.subdivide_depth = SUBDIVISIONS
	_resize_plane(MIN_PLANE_SIZE)
	mesh = _plane

	_material = ShaderMaterial.new()
	var sh: Shader = load(SHADER_PATH) as Shader
	if sh != null:
		_material.shader = sh
	material_override = _material

	global_position = Vector3(0.0, _sea_y, 0.0)


# Set the plane's side length + a matching oversized AABB (so it never frustum-culls when the camera
# looks along the sea). Only rebuilds when the size actually changes meaningfully.
func _resize_plane(size: float) -> void:
	_plane_size = size
	_plane.size = Vector2(size, size)
	custom_aabb = AABB(Vector3(-size, -4.0, -size), Vector3(size * 2.0, 8.0, size * 2.0))


## Set a shader uniform (tuning from the debug panel / VoxelWorld, e.g. wave_amp).
func set_ocean_param(param: String, value) -> void:
	if _material != null:
		_material.set_shader_parameter(param, value)


func _process(_delta: float) -> void:
	# Follow the camera in XZ (snapped to whole units so the world-space wave phase doesn't shimmer),
	# holding the sea surface at the fixed sea level, and size the plane to the current zoom so it always
	# reaches the horizon when pulled out (the reported "ocean stops short of the land" at full zoom).
	if _camera == null or not is_instance_valid(_camera):
		return
	if _camera.has_method("get_zoom_distance"):
		var target: float = clampf(_camera.get_zoom_distance() * SIZE_PER_DISTANCE, MIN_PLANE_SIZE, MAX_PLANE_SIZE)
		# Rebuild only on a meaningful change (avoid churning the mesh every frame while zooming).
		if absf(target - _plane_size) > _plane_size * 0.12:
			_resize_plane(target)
	var cp: Vector3 = _camera.global_position
	global_position = Vector3(round(cp.x), _sea_y, round(cp.z))
