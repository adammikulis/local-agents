class_name LAOceanPlane
extends MeshInstance3D

## The sea shell, drawn as one spherical mesh of radius `sea_radius`.

const SPHERE_RADIAL_SEGMENTS: int = 96
const SPHERE_RINGS: int = 64
const SphereWaterShader: Shader = preload("res://addons/local_agents/sim/shaders/VoxelWaterSphere.gdshader")

## Build the shell at `center` with radius `sea_radius`.
func setup_sphere(center: Vector3, sea_radius: float, transparent: bool = true) -> void:
	name = "OceanPlane"
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

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
