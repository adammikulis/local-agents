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

# A big plane so it covers out to the horizon within the camera's zoom range; enough subdivisions that
# the vertex swell reads as rolling water near the camera (fine ripple detail is added in the fragment
# shader, so the tessellation only needs to carry the large swell).
const PLANE_SIZE: float = 2600.0
const SUBDIVISIONS: int = 200

var _camera: Node3D = null
var _sea_y: float = 0.0
var _material: ShaderMaterial = null


## Build the ocean plane at world Y `sea_y`, following `camera` in XZ. Added as a child of the caller.
func setup(sea_y: float, camera: Node3D) -> void:
	_sea_y = sea_y
	_camera = camera
	name = "OceanPlane"
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(PLANE_SIZE, PLANE_SIZE)
	plane.subdivide_width = SUBDIVISIONS
	plane.subdivide_depth = SUBDIVISIONS
	mesh = plane

	_material = ShaderMaterial.new()
	var sh: Shader = load(SHADER_PATH) as Shader
	if sh != null:
		_material.shader = sh
	material_override = _material
	# Big AABB so the plane never frustum-culls when the camera looks along it.
	custom_aabb = AABB(Vector3(-PLANE_SIZE, -2.0, -PLANE_SIZE), Vector3(PLANE_SIZE * 2.0, 4.0, PLANE_SIZE * 2.0))

	global_position = Vector3(0.0, _sea_y, 0.0)


## Set a shader uniform (tuning from the debug panel / VoxelWorld, e.g. wave_amp).
func set_ocean_param(param: String, value) -> void:
	if _material != null:
		_material.set_shader_parameter(param, value)


func _process(_delta: float) -> void:
	# Follow the camera in XZ (snapped to whole units so the world-space wave phase doesn't shimmer),
	# holding the sea surface at the fixed sea level.
	if _camera == null or not is_instance_valid(_camera):
		return
	var cp: Vector3 = _camera.global_position
	global_position = Vector3(round(cp.x), _sea_y, round(cp.z))
