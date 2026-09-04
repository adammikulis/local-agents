class_name LAVoxelSkyCycle
extends Node

## The sky the frame is drawn through: one scattering atmosphere over the body, lit by the star that is
## actually in the scene. Presentation only — the field reads the star's irradiance itself.

# Scale height of the Rayleigh atmosphere, m (U.S. Standard Atmosphere); the shader carries the same one.
const AIR_SCALE_HEIGHT_M: float = 8000.0
# Rayleigh volume-scattering coefficient of the standard atmosphere at sea level, 550 nm, 1/m: the
# vertical optical depth 0.0973 spread over the scale height.
const RAYLEIGH_BETA_SEA_LEVEL: float = 0.0973 / AIR_SCALE_HEIGHT_M

var _sun: DirectionalLight3D = null
var _sun_shine: Vector3 = Vector3(0, -1, 0)  # world direction the sunlight travels (star -> planet)
var _sky_shader_mat: ShaderMaterial = null
var _env: Environment = null
var _want_fog: bool = true
var _camera: Node3D = null                   # the camera the frame is drawn through
var _planet_centre: Vector3 = Vector3.ZERO
var _sea_radius: float = 0.0
var _star: Node3D = null
var _moon: Node3D = null

# Scene refs read each frame (the field's precipitation and cloud cover dim the sun).
var _material: Node = null
var _water: Node = null


func setup(world: Node3D, render_opts: Dictionary = {}) -> void:
	var want_ssao: bool = bool(render_opts.get("ssao", true))
	var want_glow: bool = bool(render_opts.get("glow", true))
	var want_shadows: bool = bool(render_opts.get("sun_shadows", true))

	var env: WorldEnvironment = WorldEnvironment.new()
	var e: Environment = Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky: Sky = Sky.new()
	var sky_mat: ShaderMaterial = ShaderMaterial.new()
	sky_mat.shader = load("res://addons/local_agents/sim/shaders/VoxelSky.gdshader")
	sky.sky_material = sky_mat
	e.sky = sky
	# The sky IS the ambient: what fills a shadow is the scattered light drawn overhead, so it darkens
	# with altitude and goes out at night without a second dial.
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 1.0
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.ssao_enabled = want_ssao
	e.ssao_radius = 3.5
	e.ssao_intensity = 2.2
	e.ssao_power = 1.6
	e.ssao_detail = 0.4
	e.ssao_horizon = 0.09
	e.ssao_sharpness = 0.95

	e.glow_enabled = want_glow
	e.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	e.glow_intensity = 0.85
	e.glow_strength = 1.0
	e.glow_bloom = 0.05
	e.glow_hdr_threshold = 1.05
	e.glow_hdr_scale = 2.0
	e.glow_hdr_luminance_cap = 12.0
	e.glow_normalized = false
	e.set_glow_level(1, 0.0)
	e.set_glow_level(2, 0.0)
	e.set_glow_level(3, 1.0)
	e.set_glow_level(4, 0.8)
	e.set_glow_level(5, 0.0)

	e.fog_enabled = bool(render_opts.get("fog", true))
	e.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	# The fog IS the air the sky is drawn out of, so its colour is that sky along the same ray and never
	# a painted one. No height band: this body's surface stands at every world Y from -R to +R.
	e.fog_aerial_perspective = 1.0
	e.fog_sun_scatter = 0.0
	e.fog_light_energy = 1.0
	e.fog_sky_affect = 0.0
	e.fog_height_density = 0.0
	e.fog_density = RAYLEIGH_BETA_SEA_LEVEL

	env.environment = e
	world.add_child(env)
	_sky_shader_mat = sky_mat
	_env = e
	_want_fog = e.fog_enabled

	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.shadow_enabled = want_shadows
	sun.directional_shadow_max_distance = 400.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_split_1 = 0.08
	sun.directional_shadow_split_2 = 0.2
	sun.directional_shadow_split_3 = 0.5
	sun.directional_shadow_fade_start = 0.85
	sun.shadow_blur = 1.2
	sun.shadow_normal_bias = 1.5
	sun.shadow_bias = 0.04
	world.add_child(sun)
	_sun = sun


## AIM THE SUNLIGHT ALONG star -> body. Called whenever the orbit moves either one; the transform is read
## the moment the view is composed, so a light still carrying its constructed rotation opens the view on
## whatever side of the body that pointed at.
func set_sun_shine(shine_dir: Vector3) -> void:
	if shine_dir.length() < 0.001:
		return
	_sun_shine = shine_dir.normalized()
	_update_sky()


# Bind the scene systems the cycle reads each frame. Called after material/water-particles exist.
func bind_scene(material: Node, water: Node) -> void:
	_material = material
	_water = water


## The bodies whose discs the sky draws. Both are real nodes with real orbits; nothing here places them.
func bind_bodies(star: Node3D, moon: Node3D) -> void:
	_star = star
	_moon = moon


## The camera the frame is drawn through, and the body it stands on. The render layer owns both and hands
## them over; nothing here goes looking for a camera.
func bind_camera(camera: Node3D, planet_centre: Vector3, sea_radius: float) -> void:
	_camera = camera
	_planet_centre = planet_centre
	_sea_radius = sea_radius


func sun() -> DirectionalLight3D:
	return _sun


func env() -> Environment:
	return _env


## WHERE THE SUN STANDS AT THE EYE, on the conventional dial: 0.25 sunrise, 0.5 noon, 0.75 sunset. Read
## off the sun's own elevation, so a world with no clock still has a time of day.
func time_of_day() -> float:
	return fposmod(0.5 - asin(clampf(_sun_elevation(), -1.0, 1.0)) / PI, 1.0)


func set_ssao(on: bool) -> void:
	if _env != null:
		_env.ssao_enabled = on


func set_shadows(on: bool) -> void:
	if _sun != null:
		_sun.shadow_enabled = on


func update(_delta: float) -> void:
	_update_sky()


func _update_sky() -> void:
	if _sun == null:
		return
	var up: Vector3 = _local_up()
	var pup: Vector3 = Vector3.UP if absf(_sun_shine.dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
	_sun.look_at_from_position(Vector3.ZERO, _sun_shine, pup)
	# The radiance unit is the sun's own irradiance at the eye; cloud and rain take the beam down.
	var beam: float = _weather_dim()
	_sun.light_energy = beam
	var eye_r: float = _eye_radius()
	if _sky_shader_mat != null:
		_sky_shader_mat.set_shader_parameter("planet_up", up)
		_sky_shader_mat.set_shader_parameter("eye_radius_m", eye_r)
		_sky_shader_mat.set_shader_parameter("sea_radius_m", _sea_radius)
		_sky_shader_mat.set_shader_parameter("sun_dir", _sun.global_transform.basis.z)
		_sky_shader_mat.set_shader_parameter("sun_color", _sun.light_color)
		_sky_shader_mat.set_shader_parameter("sun_irradiance", beam)
		_sky_shader_mat.set_shader_parameter("sun_cos_radius",
			_cos_angular_radius(_star, float(LABodySeeds.of("star").get("radius_m", -1.0))))
		_apply_moon()
	if _env != null:
		_env.fog_enabled = _want_fog
		# The air thins with height, and the scattering coefficient thins with it.
		_env.fog_density = RAYLEIGH_BETA_SEA_LEVEL \
			* exp(-maxf(eye_r - _sea_radius, 0.0) / AIR_SCALE_HEIGHT_M)
	if _water != null and _water.has_method("set_sky_tint"):
		_water.set_sky_tint(Color(1.0, 1.0, 1.0) * beam)


## The moon disc: where it stands, how big it looks, and which way the sun lights it. Absent when the
## system carries no moon — an unaimed disc would be a moon nailed to a world axis.
func _apply_moon() -> void:
	var visible: bool = _moon != null and is_instance_valid(_moon) and _star != null \
		and is_instance_valid(_star) and _camera != null and is_instance_valid(_camera)
	if not visible:
		_sky_shader_mat.set_shader_parameter("moon_cos_radius", 1.0)
		return
	var eye: Vector3 = _camera.global_position
	_sky_shader_mat.set_shader_parameter("moon_dir", (_moon.global_position - eye).normalized())
	_sky_shader_mat.set_shader_parameter("moon_sun_dir",
		(_star.global_position - _moon.global_position).normalized())
	_sky_shader_mat.set_shader_parameter("moon_cos_radius",
		_cos_angular_radius(_moon, float(_moon.radius()) if _moon.has_method("radius") else -1.0))


## Cosine of the angle a body of radius `r` subtends at the eye. 1.0 — a disc of no size — when the body
## or its radius is absent, so nothing is drawn rather than something the wrong size.
func _cos_angular_radius(node: Node3D, r: float) -> float:
	if node == null or not is_instance_valid(node) or r <= 0.0 or _camera == null:
		return 1.0
	var d: float = _camera.global_position.distance_to(node.global_position)
	if d <= r:
		return 1.0
	return sqrt(1.0 - (r / d) * (r / d))


## Precipitating cell share to a 0..1 sky dial. The scale is the renderer's, not the field's.
const RAIN_FULL_SHARE: float = 0.025
func _rain_dial() -> float:
	if _material == null or not _material.has_method("precipitation"):
		return NAN
	var p: float = float(_material.precipitation())
	return clampf(p / RAIN_FULL_SHARE, 0.0, 1.0) if is_finite(p) else NAN


## HOW MUCH THE FIELD'S OWN WEATHER DIMS THE SUN, 0..1. Each dial is a measurement: a world whose
## processes hold no condensation measures no cloud, and an unmeasured dial dims by nothing. A
## non-finite reading never reaches a light, where it blackens the whole frame.
func _weather_dim() -> float:
	var dim: float = 1.0
	var rain: float = _rain_dial()
	if is_finite(rain):
		dim *= 1.0 - rain * 0.68
	if _material != null and _material.has_method("avg_cloud_cover"):
		var cover: float = float(_material.avg_cloud_cover())
		if is_finite(cover):
			dim *= 1.0 - clampf(cover * 1.5, 0.0, 0.6)
	return dim


## Sine of the sun's elevation at the eye: the sun stands opposite the direction its light travels.
func _sun_elevation() -> float:
	return -_sun_shine.dot(_local_up())


## Distance from the body centre to the eye. The sea radius before a camera is bound, which is the
## surface — the only altitude a world with no viewer has.
func _eye_radius() -> float:
	if _camera == null or not is_instance_valid(_camera):
		return _sea_radius
	return _camera.global_position.distance_to(_planet_centre)


## The local vertical at the eye: the sky's zenith, and the axis its air mass and its horizon are
## measured from. World +Y before a camera is bound, which is the pole and not the horizon anywhere else.
func _local_up() -> Vector3:
	if _camera == null or not is_instance_valid(_camera):
		return Vector3.UP
	var r: Vector3 = _camera.global_position - _planet_centre
	return r.normalized() if r.length() > 0.001 else Vector3.UP
