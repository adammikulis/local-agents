extends Node3D
class_name LocalAgentsCloudRenderer

const CloudLayerShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelCloudLayer.gdshader")
const VolumetricCloudShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelVolumetricClouds.gdshader")
const CloudSlicesShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelCloudSlices.gdshader")

const CLOUD_QUALITY_LOW := "low"
const CLOUD_QUALITY_MEDIUM := "medium"
const CLOUD_QUALITY_HIGH := "high"
const CLOUD_QUALITY_ULTRA := "ultra"

var _cloud_layer_instance: MeshInstance3D
var _cloud_layer_material: ShaderMaterial
var _volumetric_cloud_shell: MeshInstance3D
var _volumetric_cloud_material: ShaderMaterial
var _cloud_slices_instance: MultiMeshInstance3D
var _cloud_slices_material: ShaderMaterial
var _cloud_slices_mesh: PlaneMesh
var _quality_tier: String = CLOUD_QUALITY_MEDIUM
var _slice_density: float = 0.8
var _last_geometry_snapshot: Dictionary = {}

func clear_generated() -> void:
	if _cloud_layer_instance != null and is_instance_valid(_cloud_layer_instance):
		_cloud_layer_instance.queue_free()
	if _volumetric_cloud_shell != null and is_instance_valid(_volumetric_cloud_shell):
		_volumetric_cloud_shell.queue_free()
	if _cloud_slices_instance != null and is_instance_valid(_cloud_slices_instance):
		_cloud_slices_instance.queue_free()
	_cloud_layer_instance = null
	_cloud_layer_material = null
	_volumetric_cloud_shell = null
	_volumetric_cloud_material = null
	_cloud_slices_instance = null
	_cloud_slices_material = null
	_cloud_slices_mesh = null

func ensure_layers() -> void:
	_ensure_cloud_layer()
	_ensure_volumetric_cloud_shell()
	_ensure_cloud_slices()
	_apply_quality_settings()

func set_quality_tier(tier: String) -> void:
	var normalized = String(tier).to_lower().strip_edges()
	match normalized:
		CLOUD_QUALITY_LOW, CLOUD_QUALITY_MEDIUM, CLOUD_QUALITY_HIGH, CLOUD_QUALITY_ULTRA:
			_quality_tier = normalized
		_:
			_quality_tier = CLOUD_QUALITY_HIGH
	_apply_quality_settings()
	if not _last_geometry_snapshot.is_empty():
		update_geometry(_last_geometry_snapshot)

func set_slice_density(density: float) -> void:
	_slice_density = clampf(density, 0.25, 3.0)
	if not _last_geometry_snapshot.is_empty():
		update_geometry(_last_geometry_snapshot)

func update_geometry(generation_snapshot: Dictionary) -> void:
	_last_geometry_snapshot = generation_snapshot.duplicate(true)
	_ensure_cloud_layer()
	_ensure_volumetric_cloud_shell()
	_ensure_cloud_slices()
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
	_update_cloud_slices_geometry(width, depth, world_height, span)

func update_transform_stage(
	rain: float,
	cloud: float,
	humidity: float,
	wind: Vector2,
	wind_speed: float,
	transform_stage_a_field_tex: Texture2D,
	transform_stage_a_field_world_size: Vector2,
	lightning_flash: float
) -> void:
	_ensure_cloud_layer()
	_ensure_volumetric_cloud_shell()
	_ensure_cloud_slices()
	if _cloud_layer_material != null:
		_cloud_layer_material.set_shader_parameter("atmosphere_cover", cloud)
		_cloud_layer_material.set_shader_parameter("atmosphere_density", clampf(0.45 + humidity * 0.42, 0.0, 1.0))
		_cloud_layer_material.set_shader_parameter("atmosphere_precipitation", rain)
		_cloud_layer_material.set_shader_parameter("atmosphere_flow_dir", wind)
		_cloud_layer_material.set_shader_parameter("atmosphere_flow_speed", wind_speed)
		_cloud_layer_material.set_shader_parameter("atmosphere_pattern_scale", lerpf(0.032, 0.015, cloud))
		_cloud_layer_material.set_shader_parameter("layer_variation", clampf(0.25 + humidity * 0.5, 0.0, 1.0))
		_cloud_layer_material.set_shader_parameter("transform_field_tex", transform_stage_a_field_tex)
		_cloud_layer_material.set_shader_parameter("transform_field_world_size", transform_stage_a_field_world_size)
		_cloud_layer_material.set_shader_parameter("transform_field_blend", 1.0)
	if _volumetric_cloud_material != null:
		_volumetric_cloud_material.set_shader_parameter("atmosphere_precipitation", rain)
		_volumetric_cloud_material.set_shader_parameter("atmosphere_cover", cloud)
		_volumetric_cloud_material.set_shader_parameter("atmosphere_density", clampf(0.4 + humidity * 0.5, 0.0, 1.0))
		_volumetric_cloud_material.set_shader_parameter("atmosphere_flow_dir", wind)
		_volumetric_cloud_material.set_shader_parameter("atmosphere_flow_speed", wind_speed)
		_volumetric_cloud_material.set_shader_parameter("lightning_flash", lightning_flash)
	if _cloud_slices_material != null:
		_cloud_slices_material.set_shader_parameter("rain_intensity", rain)
		_cloud_slices_material.set_shader_parameter("cloud_cover", cloud)
		_cloud_slices_material.set_shader_parameter("cloud_density", clampf(0.4 + humidity * 0.5, 0.0, 1.0))
		_cloud_slices_material.set_shader_parameter("transform_wind_dir", wind)
		_cloud_slices_material.set_shader_parameter("transform_wind_speed", wind_speed)
		_cloud_slices_material.set_shader_parameter("lightning_flash", lightning_flash)

func apply_lightning(lightning_flash: float) -> void:
	if _volumetric_cloud_material != null:
		_volumetric_cloud_material.set_shader_parameter("lightning_flash", lightning_flash)
	if _cloud_slices_material != null:
		_cloud_slices_material.set_shader_parameter("lightning_flash", lightning_flash)

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

func _ensure_cloud_slices() -> void:
	if _cloud_slices_instance != null and is_instance_valid(_cloud_slices_instance):
		return
	_cloud_slices_mesh = PlaneMesh.new()
	_cloud_slices_mesh.size = Vector2(1.0, 1.0)
	_cloud_slices_material = ShaderMaterial.new()
	_cloud_slices_material.shader = CloudSlicesShader
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _cloud_slices_mesh
	mm.instance_count = 0
	_cloud_slices_instance = MultiMeshInstance3D.new()
	_cloud_slices_instance.name = "CloudSlices"
	_cloud_slices_instance.multimesh = mm
	_cloud_slices_instance.material_override = _cloud_slices_material
	add_child(_cloud_slices_instance)

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

func _update_cloud_slices_geometry(width: float, depth: float, world_height: float, span: float) -> void:
	if _cloud_slices_instance == null or not is_instance_valid(_cloud_slices_instance):
		return
	var mm := _cloud_slices_instance.multimesh
	if mm == null:
		return
	var base_count = _slice_base_count_for_tier(_quality_tier)
	var count = maxi(0, int(round(float(base_count) * _slice_density)))
	mm.instance_count = count
	var center = Vector3(width * 0.5, world_height + 18.0, depth * 0.5)
	var radius = maxf(32.0, span * 0.5)
	for i in range(count):
		var t = float(i) + 1.0
		var angle = t * 2.3999632
		var radial = radius * sqrt(clampf(_fractf(sin(t * 12.9898) * 43758.5453), 0.0, 1.0))
		var x = center.x + cos(angle) * radial
		var z = center.z + sin(angle) * radial
		var y_band = 0.15 + 0.8 * _fractf(sin(t * 78.233) * 12345.678)
		var y = center.y + 3.0 + y_band * 36.0
		var size = lerpf(28.0, 140.0, _fractf(sin(t * 21.17) * 96431.21))
		var transform = Transform3D(Basis.IDENTITY.scaled(Vector3(size, 1.0, size)), Vector3(x, y, z))
		mm.set_instance_transform(i, transform)
		var alpha = lerpf(0.12, 0.42, _fractf(sin(t * 4.711) * 1531.0))
		mm.set_instance_color(i, Color(1.0, 1.0, 1.0, alpha))
		mm.set_instance_custom_data(i, Color(_fractf(sin(t * 5.17) * 7123.0), _fractf(sin(t * 9.13) * 9941.0), _fractf(sin(t * 3.73) * 4487.0), 1.0))
	if _cloud_slices_material != null:
		_cloud_slices_material.set_shader_parameter("world_center_xz", Vector2(center.x, center.z))
		_cloud_slices_material.set_shader_parameter("world_span", span)

func _apply_quality_settings() -> void:
	if _cloud_layer_instance != null:
		_cloud_layer_instance.visible = true
	if _cloud_slices_instance != null:
		_cloud_slices_instance.visible = _quality_tier != CLOUD_QUALITY_LOW
	if _volumetric_cloud_shell != null:
		_volumetric_cloud_shell.visible = _quality_tier == CLOUD_QUALITY_HIGH or _quality_tier == CLOUD_QUALITY_ULTRA
		var sphere = _volumetric_cloud_shell.mesh as SphereMesh
		if sphere != null:
			match _quality_tier:
				CLOUD_QUALITY_ULTRA:
					sphere.radial_segments = 64
					sphere.rings = 32
				CLOUD_QUALITY_HIGH:
					sphere.radial_segments = 48
					sphere.rings = 24
				CLOUD_QUALITY_MEDIUM:
					sphere.radial_segments = 28
					sphere.rings = 14
				_:
					sphere.radial_segments = 20
					sphere.rings = 10

func _slice_base_count_for_tier(tier: String) -> int:
	match tier:
		CLOUD_QUALITY_LOW:
			return 0
		CLOUD_QUALITY_MEDIUM:
			return 24
		CLOUD_QUALITY_ULTRA:
			return 128
		_:
			return 64

func _fractf(value: float) -> float:
	return value - floor(value)
