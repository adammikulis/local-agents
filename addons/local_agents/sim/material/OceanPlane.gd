class_name LAOceanPlane
extends MeshInstance3D

## The sea shell, drawn as one spherical mesh of radius `sea_radius`.

const SPHERE_RADIAL_SEGMENTS: int = 96
const SPHERE_RINGS: int = 64
const SphereWaterShader: Shader = preload("res://addons/local_agents/sim/shaders/VoxelWaterSphere.gdshader")

var _sea_base_radius: float = 0.0   # un-tided shell radius, m


## Build the shell at `center` with radius `sea_radius`.
func setup_sphere(center: Vector3, sea_radius: float, transparent: bool = true) -> void:
	name = "OceanPlane"
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_sea_base_radius = sea_radius

	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = sea_radius
	sphere.height = sea_radius * 2.0
	sphere.radial_segments = SPHERE_RADIAL_SEGMENTS
	sphere.rings = SPHERE_RINGS
	mesh = sphere

	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = SphereWaterShader
	mat.set_shader_parameter("shell_alpha", 0.72 if transparent else 1.0)
	material_override = mat

	global_position = center


## Bind the sea-ice coverage texture (6 cube-face layers, one texel per surface column) to the shader.
func set_sea_ice_texture(tex: Texture2DArray) -> void:
	var mat: ShaderMaterial = material_override as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("sea_ice_tex", tex)
	mat.set_shader_parameter("sea_ice_enabled", 1.0)


func apply_tide(offset: float) -> void:
	if _sea_base_radius <= 0.0:
		return
	var factor: float = (_sea_base_radius + offset) / _sea_base_radius
	scale = Vector3.ONE * factor
