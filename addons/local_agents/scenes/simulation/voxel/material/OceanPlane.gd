class_name LAOceanPlane
extends MeshInstance3D

## LAOceanPlane — the planet sea, drawn as ONE fixed spherical shell of radius `sea_radius` centred on
## the planet. Land above the shell pokes out; the sea floor below sits submerged. A static shell: no
## camera follow and no per-frame wave/ripple upload — the planet's real (radial) normals are kept and lit
## by a simple translucent water material.
## (Explicit types only — no ':=' inferred typing.)

# SphereMesh radial/ring resolution — high enough to read smooth at planet scale.
const SPHERE_RADIAL_SEGMENTS: int = 96
const SPHERE_RINGS: int = 64

# The spherical open-sea shader (radial-displaced waves + altitude LOD) so the shell matches the near-cap sea.
const SphereWaterShader: Shader = preload("res://addons/local_agents/scenes/simulation/voxel/shaders/VoxelWaterSphere.gdshader")

var _sea_base_radius: float = 0.0   # the un-tided shell radius; tides scale the node around this


## Build the sea as a FIXED spherical shell of radius `sea_radius` centred on `center` (the planet
## centre = world origin). Land above `sea_radius` pokes out; sea floor below is submerged. A finite
## planet sea does NOT follow the camera — it is a static sphere. Added as a child of the caller.
## `transparent` (from the quality preset) chooses the fill cost: an alpha-blended shell reads as
## semi-transparent water but is drawn in the no-early-Z transparent pass, so this planet-filling sphere
## costs ~40 ms of overdraw at 720p on a mid GPU — the single biggest default-frame cost measured. The
## DEFAULT preset therefore builds it OPAQUE (early-Z, no blending): a solid deep-blue sea that looks nearly
## identical at planet scale for a fraction of the cost. Only HIGH keeps the translucent shell.
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

	# Sphere-aware water: VoxelWaterSphere.gdshader displaces each vertex along its RADIAL normal (correct on
	# a sphere) and fades wave detail with camera altitude, so the shell reads as the SAME animated sea as the
	# near-cap surface up close and LODs to a calm blue marble at orbit instead of popping. On the DEFAULT
	# preset it is drawn OPAQUE (early-Z, no overdraw — the single biggest measured default-frame cost);
	# HIGH turns on translucency via `shell_alpha`.
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


## Apply the moon-driven tide: raise/lower the whole sea shell by `offset` world units around its base radius.
## Uniform node scaling keeps the shell centred on the planet, so land near the coast floods/drains for free
## and the near-cap surface (which is fed the same tided radius) stays in lock-step. Called each frame by the
## solar-system driver (LASystemOrbits) — a scalar set, no mesh rebuild.
func apply_tide(offset: float) -> void:
	if _sea_base_radius <= 0.0:
		return
	var factor: float = (_sea_base_radius + offset) / _sea_base_radius
	scale = Vector3.ONE * factor
