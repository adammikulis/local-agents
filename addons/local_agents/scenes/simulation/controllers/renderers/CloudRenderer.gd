extends Node3D
class_name LocalAgentsCloudRenderer

const CloudLayerShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelCloudLayer.gdshader")
const VolumetricCloudShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelVolumetricClouds.gdshader")

var _cloud_layer_instance: MeshInstance3D
var _cloud_layer_material: ShaderMaterial
var _volumetric_cloud_shell: MeshInstance3D
var _volumetric_cloud_material: ShaderMaterial

func clear_generated() -> void:
	if _cloud_layer_instance != null and is_instance_valid(_cloud_layer_instance):
		_cloud_layer_instance.queue_free()
	if _volumetric_cloud_shell != null and is_instance_valid(_volumetric_cloud_shell):
		_volumetric_cloud_shell.queue_free()
	_cloud_layer_instance = null
	_cloud_layer_material = null
	_volumetric_cloud_shell = null
	_volumetric_cloud_material = null

func ensure_layers() -> void:
	_ensure_cloud_layer()
	_ensure_volumetric_cloud_shell()

func update_geometry(generation_snapshot: Dictionary) -> void:
	_ensure_cloud_layer()
	_ensure_volumetric_cloud_shell()
	var width = maxf(8.0, float(generation_snapshot.get("width", 32)))
	var depth = maxf(8.0, float(generation_snapshot.get("height", 32)))
	var voxel_world: Dictionary = generation_snapshot.get("voxel_world", {})
	var world_height = maxf(8.0, float(voxel_world.get("height", 32)))
	var span = maxf(width, depth) * 3.6
	var plane = _cloud_layer_instance.mesh as PlaneMesh
	if plane != null:
		plane.size = Vector2(span, span)
	_cloud_layer_instance.position = Vector3(width * 0.5, world_height + 18.0, depth * 0.5)
	_update_volumetric_geometry(generation_snapshot)

func update_weather(
	rain: float,
	cloud: float,
	humidity: float,
	wind: Vector2,
	wind_speed: float,
	weather_field_tex: Texture2D,
	weather_field_world_size: Vector2,
	lightning_flash: float
) -> void:
	_ensure_cloud_layer()
	_ensure_volumetric_cloud_shell()
	if _cloud_layer_material != null:
		_cloud_layer_material.set_shader_parameter("cloud_cover", cloud)
		_cloud_layer_material.set_shader_parameter("cloud_density", clampf(0.45 + humidity * 0.42, 0.0, 1.0))
		_cloud_layer_material.set_shader_parameter("rain_intensity", rain)
		_cloud_layer_material.set_shader_parameter("weather_wind_dir", wind)
		_cloud_layer_material.set_shader_parameter("weather_wind_speed", wind_speed)
		_cloud_layer_material.set_shader_parameter("weather_cloud_scale", lerpf(0.032, 0.015, cloud))
		_cloud_layer_material.set_shader_parameter("layer_variation", clampf(0.25 + humidity * 0.5, 0.0, 1.0))
		_cloud_layer_material.set_shader_parameter("weather_field_tex", weather_field_tex)
		_cloud_layer_material.set_shader_parameter("weather_field_world_size", weather_field_world_size)
		_cloud_layer_material.set_shader_parameter("weather_field_blend", 1.0)
	if _volumetric_cloud_material != null:
		_volumetric_cloud_material.set_shader_parameter("rain_intensity", rain)
		_volumetric_cloud_material.set_shader_parameter("cloud_cover", cloud)
		_volumetric_cloud_material.set_shader_parameter("cloud_density", clampf(0.4 + humidity * 0.5, 0.0, 1.0))
		_volumetric_cloud_material.set_shader_parameter("weather_wind_dir", wind)
		_volumetric_cloud_material.set_shader_parameter("weather_wind_speed", wind_speed)
		_volumetric_cloud_material.set_shader_parameter("lightning_flash", lightning_flash)

func apply_lightning(lightning_flash: float) -> void:
	if _volumetric_cloud_material != null:
		_volumetric_cloud_material.set_shader_parameter("lightning_flash", lightning_flash)

func _ensure_cloud_layer() -> void:
	if _cloud_layer_instance != null and is_instance_valid(_cloud_layer_instance):
		return
	_cloud_layer_instance = MeshInstance3D.new()
	_cloud_layer_instance.name = "CloudLayer"
	_cloud_layer_material = ShaderMaterial.new()
	_cloud_layer_material.shader = CloudLayerShader
	var plane := PlaneMesh.new()
	plane.size = Vector2(256.0, 256.0)
	plane.subdivide_width = 16
	plane.subdivide_depth = 16
	_cloud_layer_instance.mesh = plane
	_cloud_layer_instance.material_override = _cloud_layer_material
	add_child(_cloud_layer_instance)

func _ensure_volumetric_cloud_shell() -> void:
	if _volumetric_cloud_shell != null and is_instance_valid(_volumetric_cloud_shell):
		return
	_volumetric_cloud_shell = MeshInstance3D.new()
	_volumetric_cloud_shell.name = "VolumetricCloudShell"
	var sphere := SphereMesh.new()
	sphere.radius = 220.0
	sphere.height = 440.0
	sphere.radial_segments = 48
	sphere.rings = 24
	_volumetric_cloud_shell.mesh = sphere
	_volumetric_cloud_material = ShaderMaterial.new()
	_volumetric_cloud_material.shader = VolumetricCloudShader
	_volumetric_cloud_shell.material_override = _volumetric_cloud_material
	add_child(_volumetric_cloud_shell)

func _update_volumetric_geometry(generation_snapshot: Dictionary) -> void:
	if _volumetric_cloud_shell == null or not is_instance_valid(_volumetric_cloud_shell):
		return
	var width = maxf(8.0, float(generation_snapshot.get("width", 32)))
	var depth = maxf(8.0, float(generation_snapshot.get("height", 32)))
	var voxel_world: Dictionary = generation_snapshot.get("voxel_world", {})
	var world_height = maxf(8.0, float(voxel_world.get("height", 32)))
	var span = maxf(width, depth) * 6.0
	_volumetric_cloud_shell.position = Vector3(width * 0.5, world_height + 38.0, depth * 0.5)
	var sphere = _volumetric_cloud_shell.mesh as SphereMesh
	if sphere != null:
		sphere.radius = span
		sphere.height = span * 2.0
	if _volumetric_cloud_material != null:
		_volumetric_cloud_material.set_shader_parameter("shell_radius", span)

