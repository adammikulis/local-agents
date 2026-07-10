class_name LAWaterParticles
extends GPUParticles3D

## LAWaterParticles — the ONE atmosphere visual for the planet: a single GPUParticles3D whose custom
## process + draw shaders render whichever PHASE the field's water is in (cloud / fog / rain / snow),
## phase being a per-particle property classified from the sampled field-cover texture. It dissolves the
## old flat CloudLayer sheets (cloud + fog) and the RainLayer box into one field-driven, spherical system.
##
## Bridge: the field bakes a 6-layer RGBA cover texture (one texel per SphereGrid surface cell) at ~10Hz;
## this node feeds it plus the live camera/sun to the process shader, which places particles in the camera-
## facing dome, samples the texture by normalize(pos - center), gates them to the emergent bands, and drifts
## them SLOWLY. All per-particle work is on the GPU. (Explicit types only — project rule: no ':=' .)

const PROC_SHADER: String = "res://addons/local_agents/scenes/simulation/voxel/shaders/WaterParticles.gdshader"
const DRAW_SHADER: String = "res://addons/local_agents/scenes/simulation/voxel/shaders/WaterParticlesDraw.gdshader"
const MAX_PARTICLES: int = 12000
const LIFETIME: float = 7.0
const CAP_ANGLE: float = 1.4               # emit within this half-angle of the camera's radial (visible dome)

var _field = null
var _camera: Node3D = null
var _sun: DirectionalLight3D = null
var _center: Vector3 = Vector3.ZERO
var _sea_radius: float = 248.0
var _prevailing: Vector3 = Vector3(0.15, 1.0, 0.0)
var _pm: ShaderMaterial = null             # process material
var _dm: ShaderMaterial = null             # draw material
var _sky_tint: Color = Color(1.0, 1.0, 1.0)
var _tex_bound: bool = false


func setup(field, camera: Node3D, sun: DirectionalLight3D, center: Vector3, sea_radius: float) -> void:
	_field = field
	_camera = camera
	_sun = sun
	_center = center
	_sea_radius = sea_radius
	_prevailing = _prevailing.normalized()
	name = "WaterParticles"
	amount = MAX_PARTICLES
	lifetime = LIFETIME
	explosiveness = 0.0
	randomness = 0.5
	preprocess = 4.0
	local_coords = false
	draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var outer: float = _field.atmos_outer_r() if _field.has_method("atmos_outer_r") else (sea_radius + 82.0)
	visibility_aabb = AABB(_center - Vector3.ONE * outer, Vector3.ONE * (outer * 2.0))

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	_dm = ShaderMaterial.new()
	_dm.shader = load(DRAW_SHADER)
	_dm.set_shader_parameter("sky_tint", _sky_tint)
	_dm.set_shader_parameter("planet_center", _center)   # rain streaks orient toward the core
	quad.material = _dm
	draw_pass_1 = quad

	_pm = ShaderMaterial.new()
	_pm.shader = load(PROC_SHADER)
	process_material = _pm
	_pm.set_shader_parameter("planet_center", _center)
	_pm.set_shader_parameter("cap_cos", cos(CAP_ANGLE))
	_pm.set_shader_parameter("sea_radius", _sea_radius)
	_pm.set_shader_parameter("cloud_base_r", _field.atmos_cloud_base_r() if _field.has_method("atmos_cloud_base_r") else _sea_radius + 8.0)
	_pm.set_shader_parameter("fog_top_r", _field.atmos_fog_top_r() if _field.has_method("atmos_fog_top_r") else _sea_radius + 16.0)
	_pm.set_shader_parameter("fog_lo_r", _field.atmos_fog_lo_r() if _field.has_method("atmos_fog_lo_r") else _sea_radius - 6.0)
	_pm.set_shader_parameter("outer_r", outer)
	_pm.set_shader_parameter("prevailing", _prevailing)
	emitting = true


## Effects-level density scale (0..1) from the quality settings — Low runs far fewer particles on weak
## GPUs. Sets the live particle count off the MAX_PARTICLES budget; applied once at startup after setup().
func set_density_scale(scale: float) -> void:
	amount = maxi(1, int(round(float(MAX_PARTICLES) * clampf(scale, 0.02, 1.0))))


## Day/night colour tint pushed by VoxelSkyCycle (warm at dusk, cool at night). Per-particle terminator
## brightness is handled in-shader from the sun direction; this is an overall colour wash on top.
func set_sky_tint(c: Color) -> void:
	_sky_tint = c
	if _dm != null:
		_dm.set_shader_parameter("sky_tint", c)


func _process(_delta: float) -> void:
	if LAAblate.off("water"):
		return
	if _pm == null or _camera == null or not is_instance_valid(_camera):
		return
	var cp: Vector3 = _camera.global_position
	var cdir: Vector3 = (cp - _center).normalized()
	_pm.set_shader_parameter("cam_pos", cp)
	_pm.set_shader_parameter("cam_dir", cdir)
	if _sun != null and is_instance_valid(_sun):
		var sd: Vector3 = _sun.global_transform.basis.z
		_pm.set_shader_parameter("sun_dir", sd)
	# The cover texture is created on the field's first atmos refresh; bind it once (it updates in place).
	if not _tex_bound and _field != null and _field.has_method("field_cover_texture"):
		var tx = _field.field_cover_texture()
		if tx != null:
			_pm.set_shader_parameter("field_tex", tx)
			_tex_bound = true
