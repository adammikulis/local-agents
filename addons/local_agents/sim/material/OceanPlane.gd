class_name LAOceanPlane
extends MeshInstance3D

## LAOceanPlane: the planet sea, drawn as ONE fixed spherical shell of radius `sea_radius` centred on

# SphereMesh radial/ring resolution — high enough to read smooth at planet scale.
const SPHERE_RADIAL_SEGMENTS: int = 96
const SPHERE_RINGS: int = 64

# The spherical open-sea shader (radial-displaced waves + altitude LOD) so the shell matches the near-cap sea.
const SphereWaterShader: Shader = preload("res://addons/local_agents/sim/shaders/VoxelWaterSphere.gdshader")

var _sea_base_radius: float = 0.0   # the un-tided shell radius; tides scale the node around this


## centre = world origin). Land above `sea_radius` pokes out; sea floor below is submerged. A finite
func setup_sphere(center: Vector3, sea_radius: float, transparent: bool = true) -> void:
	name = "OceanPlane"
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_sea_base_radius = sea_radius

	# A smooth SphereMesh at planet scale (radius = sea_radius, full height = diameter).
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

	# Static shell: fixed at the planet centre, no camera follow, no per-frame wave/ripple upload (waves +
	# the altitude LOD animate entirely in-shader from TIME / CAMERA_POSITION_WORLD).
	global_position = center


## Feed the emergent sea-ice texture (6-layer cube-face coverage, one texel per surface column) to the shell
## shader so frozen sea reads WHITE from orbit. Bound once by LASeaIceShaderController; the shell samples it by
## its own radial each frame (no per-frame upload here). A no-op on the flat island (no spherical shell).
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
