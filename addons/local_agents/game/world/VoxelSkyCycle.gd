class_name LAVoxelSkyCycle
extends Node


var _sun: DirectionalLight3D = null
var _planet_mode: bool = false              # true = viewed from space: dark starfield, low ambient, fixed sun
var _sun_shine: Vector3 = Vector3(0, -1, 0) # world direction the sunlight travels (star -> planet)
const SPACE_AMBIENT: float = 0.14           # low ambient so the planet's night side darkens (stark terminator)
const SPACE_BG: Color = Color(0.01, 0.015, 0.03)      # near-black space
const SPACE_AMBIENT_COLOR: Color = Color(0.10, 0.13, 0.22)  # faint cool fill on the night side
const SURFACE_ATMO_T: float = 0.12
const SURFACE_AMBIENT: float = 0.55         # ground-level ambient energy
const SURFACE_FILL_COLOR: Color = Color(0.50, 0.56, 0.66)   # soft blue-grey day fill (ambient at the surface)
# Rayleigh volume-scattering coefficient of the standard atmosphere at sea level, 550 nm, 1/m.
const FOG_DENSITY_SURFACE: float = 1.2e-5

func set_space_mode(shine_dir: Vector3) -> void:
	if shine_dir.length() < 0.001:
		return
	_sun_shine = shine_dir.normalized()
	_planet_mode = true
	# AIM THE SUN NOW. Its transform is read the moment the view is composed, and a light still carrying
	# its constructed rotation would open the view on whatever side of the body that pointed at.
	_update_day_night()
var _moon: DirectionalLight3D = null         # cool moonlight; energy tracks the lunar phase
var _sky_shader_mat: ShaderMaterial = null   # VoxelSky.gdshader: stars + phase-shaded moon disc
var _env: Environment = null
var _camera: Node3D = null                   # the camera that draws the frame; source of the atmosphere blend
var _planet_centre: Vector3 = Vector3.ZERO   # the body the eye stands on; the local vertical is radial from it
var _want_fog: bool = true                   # effective fog toggle (quality preset + NOFOG), applied near surface
var _time_of_day: float = 0.30              # start just after dawn (dawn = .25) so the sun is already
                                            # up and climbing — the world reads as a lit morning
# Lunar cycle: derived from the same elapsed time, on a longer period.
var _lunar_phase: float = 0.15              # 0=new, 0.25=first quarter, 0.5=full, 0.75=last quarter
# Where on the day/lunar cycle this world STARTED. Both phases are now the world's elapsed time plus these
var _tod_seed: float = 0.30
var _lunar_seed: float = 0.15

# Scene refs read each frame by the cycle (the field's precipitation and cloud cover dim the sky).
var _material: Node = null
var _water: Node = null      # LAWaterParticles — the day/night colour tint is pushed to it each frame

const LUNAR_DAYS: float = 8.0               # in-game days per full new->full->new cycle
const SUN_ENERGY_NOON: float = 1.45
const AMBIENT_DAY: float = 0.62
const AMBIENT_NIGHT: float = 0.09           # dark floor; the moon lifts brightness on lit nights
const MOON_ENERGY_FULL: float = 0.32        # directional moonlight at full moon (navigable)
const MOON_AMBIENT: float = 0.14            # extra ambient fill at a full-moon night
const MOON_COLOR: Color = Color(0.55, 0.66, 0.95)
const SKY_TOP_DAY: Color = Color(0.36, 0.56, 0.86)
const SKY_TOP_NIGHT: Color = Color(0.02, 0.03, 0.11)
# Pale, near-white horizon so the surround reads cloudlike.
const SKY_HORIZON_DAY: Color = Color(0.86, 0.90, 0.94)
const SKY_HORIZON_NIGHT: Color = Color(0.05, 0.06, 0.15)
const SKY_HORIZON_DUSK: Color = Color(0.92, 0.48, 0.24)


func setup(world: Node3D, time_of_day: float, lunar_phase: float, render_opts: Dictionary = {}) -> void:
	_time_of_day = time_of_day
	_lunar_phase = lunar_phase
	_tod_seed = time_of_day
	_lunar_seed = lunar_phase
	var want_ssao: bool = bool(render_opts.get("ssao", true))
	var want_glow: bool = bool(render_opts.get("glow", true))
	var want_shadows: bool = bool(render_opts.get("sun_shadows", true))
	var want_fog: bool = bool(render_opts.get("fog", true))

	var env: WorldEnvironment = WorldEnvironment.new()
	var e: Environment = Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky: Sky = Sky.new()
	var sky_mat: ShaderMaterial = ShaderMaterial.new()
	sky_mat.shader = load("res://addons/local_agents/sim/shaders/VoxelSky.gdshader")
	sky_mat.set_shader_parameter("sky_top_color", SKY_TOP_DAY)
	sky_mat.set_shader_parameter("sky_horizon_color", SKY_HORIZON_DAY)
	sky_mat.set_shader_parameter("night", 0.0)
	sky_mat.set_shader_parameter("star_intensity", 1.0)
	sky_mat.set_shader_parameter("moon_phase", _lunar_phase)
	sky_mat.set_shader_parameter("moon_color", Color(0.85, 0.90, 1.0))
	sky_mat.set_shader_parameter("moon_energy", 1.0)
	sky_mat.set_shader_parameter("sun_color", Color(1.0, 1.0, 1.0))
	sky_mat.set_shader_parameter("sun_energy", SUN_ENERGY_NOON)
	sky.sky_material = sky_mat
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = AMBIENT_DAY
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.ssao_enabled = want_ssao
	e.ssao_radius = 3.5
	e.ssao_intensity = 2.2
	e.ssao_power = 1.6
	e.ssao_detail = 0.4
	e.ssao_horizon = 0.09
	e.ssao_sharpness = 0.95

	e.glow_enabled = want_glow and not OS.has_environment("NOGLOW")
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

	e.fog_enabled = want_fog and not OS.has_environment("NOFOG")
	e.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	e.fog_light_color = SKY_HORIZON_DAY
	e.fog_light_energy = 1.0
	e.fog_sun_scatter = 0.15
	e.fog_density = FOG_DENSITY_SURFACE
	e.fog_aerial_perspective = 0.55
	e.fog_sky_affect = 0.05
	# No height fog: Godot's is a band in world Y, and this body's surface stands at every Y from -R to
	# +R, so a height band fogs one hemisphere and leaves the other clear.
	e.fog_height_density = 0.0

	env.environment = e
	world.add_child(env)
	_sky_shader_mat = sky_mat
	_env = e
	_want_fog = e.fog_enabled

	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -47.0, 0.0)
	sun.light_energy = SUN_ENERGY_NOON
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

	var moon: DirectionalLight3D = DirectionalLight3D.new()
	moon.light_color = MOON_COLOR
	moon.light_energy = 0.0
	moon.shadow_enabled = false
	world.add_child(moon)
	_moon = moon


# Bind the scene systems the cycle reads each frame. Called after material/water-particles exist.
func bind_scene(material: Node, water: Node) -> void:
	_material = material
	_water = water


## The camera the frame is drawn through and the body it stands on. The render layer owns both and hands
## them over; nothing here goes looking for a camera.
func bind_camera(camera: Node3D, planet_centre: Vector3) -> void:
	_camera = camera
	_planet_centre = planet_centre


func sun() -> DirectionalLight3D:
	return _sun


func env() -> Environment:
	return _env


func time_of_day() -> float:
	return _time_of_day


func set_ssao(on: bool) -> void:
	if _env != null:
		_env.ssao_enabled = on


func set_shadows(on: bool) -> void:
	if _sun != null:
		_sun.shadow_enabled = on


# Drive all sky lighting from the world clock. VoxelWorld calls this from _physics_process.
func update(_delta: float) -> void:
	_update_day_night()


## Day and lunar phase read off LASimClock's elapsed days, each wrapped at its own period.
func _advance_clocks() -> void:
	var clock: LASimClock = LASimClock.active()
	if clock == null:
		return
	var days: float = clock.days_elapsed()
	_time_of_day = fposmod(_tod_seed + days, 1.0)
	_lunar_phase = fposmod(_lunar_seed + days / LUNAR_DAYS, 1.0)


# Sun elevation is a sine of the time of day; light energy, horizon warmth and night ambient all follow it.
func _update_day_night() -> void:
	if _sun == null:
		return
	# PLANET-FROM-SPACE: fixed star sun + low ambient + dark sky.
	if _planet_mode:
		var pstorm: float = _weather_dim()
		var pup: Vector3 = Vector3.UP if absf(_sun_shine.dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
		_sun.look_at_from_position(Vector3.ZERO, _sun_shine, pup)   # light travels along _sun_shine
		_sun.light_energy = SUN_ENERGY_NOON * pstorm
		# The sky draws its own sun from these, and a disc aimed by an unset uniform is aimed nowhere.
		if _sky_shader_mat != null:
			_sky_shader_mat.set_shader_parameter("sun_dir", _sun.global_transform.basis.z)
			_sky_shader_mat.set_shader_parameter("sun_energy", _sun.light_energy)
			_sky_shader_mat.set_shader_parameter("sun_color", _sun.light_color)
			_sky_shader_mat.set_shader_parameter("night", 0.0)
			_sky_shader_mat.set_shader_parameter("planet_up", _local_up())
		# The water-particle renderer's day/night comes from per-particle sun shading.
		if _water != null and _water.has_method("set_sky_tint"):
			_water.set_sky_tint(Color(1.0, 1.0, 1.0) * (0.55 + 0.45 * pstorm))
		_apply_surface_atmosphere()
		return
	_advance_clocks()
	# Sun elevation: -1 (midnight) .. +1 (noon), zero at dawn (.25) and dusk (.75).
	var elev: float = sin((_time_of_day - 0.25) * TAU)
	var daylight: float = clampf(elev, 0.0, 1.0)
	var storm: float = _weather_dim()

	# Sun arc: steep overhead at noon, shallow at the horizon near dawn/dusk; sweeps E->W.
	_sun.rotation_degrees = Vector3(-(6.0 + daylight * 66.0), -47.0 + (_time_of_day - 0.5) * 90.0, 0.0)
	_sun.light_energy = SUN_ENERGY_NOON * daylight * storm
	# Warm the sunlight near the horizon (dawn/dusk glow).
	var warm: float = clampf(1.0 - elev * 2.5, 0.0, 1.0) * clampf(daylight * 6.0, 0.0, 1.0)
	_sun.light_color = Color(1.0, 1.0, 1.0).lerp(Color(1.0, 0.6, 0.32), warm * 0.8)

	# Illuminated fraction is a cosine of the lunar phase (0 at new, 1 at full).
	var moon_illum: float = (1.0 - cos(_lunar_phase * TAU)) * 0.5
	var moonup: float = clampf(-elev, 0.0, 1.0)
	if _moon != null:
		_moon.rotation_degrees = Vector3(-(6.0 + moonup * 66.0), 133.0 + (_time_of_day - 0.5) * 90.0, 0.0)
		_moon.light_energy = MOON_ENERGY_FULL * moon_illum * moonup * storm

	# Sky colors lerp day<->night; horizon warms to dusk-orange around the transitions.
	var night: float = 1.0 - daylight
	if _sky_shader_mat != null:
		_sky_shader_mat.set_shader_parameter("sky_top_color", SKY_TOP_DAY.lerp(SKY_TOP_NIGHT, night))
		var horizon: Color = SKY_HORIZON_DAY.lerp(SKY_HORIZON_NIGHT, night)
		horizon = horizon.lerp(SKY_HORIZON_DUSK, warm * 0.7)
		_sky_shader_mat.set_shader_parameter("sky_horizon_color", horizon)
		# Darken the ground band at night too.
		_sky_shader_mat.set_shader_parameter("night", night)
		_sky_shader_mat.set_shader_parameter("moon_phase", _lunar_phase)
		_sky_shader_mat.set_shader_parameter("planet_up", _local_up())
		# Sun/moon directions drive the discs directly (basis.z of a DirectionalLight3D points back toward the light.
		_sky_shader_mat.set_shader_parameter("sun_dir", _sun.global_transform.basis.z)
		_sky_shader_mat.set_shader_parameter("sun_energy", _sun.light_energy)
		_sky_shader_mat.set_shader_parameter("sun_color", _sun.light_color)
		if _moon != null:
			_sky_shader_mat.set_shader_parameter("moon_dir", _moon.global_transform.basis.z)
	if _env != null:
		# Dark night floor, lifted softly on bright-moon nights so full moons are navigable.
		_env.ambient_light_energy = lerpf(AMBIENT_NIGHT, AMBIENT_DAY, daylight) * storm \
			+ moon_illum * night * MOON_AMBIENT * storm
		# Keep the distance fog matched to the current horizon colour.
		var fog_col: Color = SKY_HORIZON_DAY.lerp(SKY_HORIZON_NIGHT, night)
		fog_col = fog_col.lerp(SKY_HORIZON_DUSK, warm * 0.7)
		_env.fog_light_color = fog_col

	# Tint the water-particle renderer with the sky: white by day, dusk-orange near sunset, dark at night.
	var cloud_tint: Color = Color(1.0, 1.0, 1.0).lerp(Color(0.10, 0.12, 0.18), night)
	cloud_tint = cloud_tint.lerp(Color(1.0, 0.55, 0.30), warm * 0.6)
	if _water != null and _water.has_method("set_sky_tint"):
		_water.set_sky_tint(cloud_tint)
	# This owns the sky and the sun transform/energy only. The field reads the star's light itself.


## Altitude-aware atmosphere for planet mode.
func _apply_surface_atmosphere() -> void:
	if _env == null:
		return
	var t: float = clampf(_surface_blend(), 0.0, 1.0)   # 0 in space .. 1 hovering at the surface
	if _sky_shader_mat != null:
		_sky_shader_mat.set_shader_parameter("space_amount", 1.0 - t)
	_env.background_mode = Environment.BG_SKY
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = SPACE_AMBIENT_COLOR.lerp(SURFACE_FILL_COLOR, t)
	_env.ambient_light_energy = lerpf(SPACE_AMBIENT, SURFACE_AMBIENT, t)
	# Fog fades IN with descent (0 in space → full near the surface) so there's no fog pop either.
	_env.fog_enabled = _want_fog
	_env.fog_density = FOG_DENSITY_SURFACE * t if _want_fog else 0.0


## The bound camera's surface_blend(), 0 in space to 1 at the ground; 0 before one is bound. Read off the
## camera the render layer built, never off a viewport lookup: a photographed run draws through an
## off-screen SubViewport, and the window's viewport holds no camera at all.
func _surface_blend() -> float:
	if _camera == null or not is_instance_valid(_camera) or not _camera.has_method("surface_blend"):
		return 0.0
	return _camera.surface_blend()


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


## The local vertical at the eye: the sky's zenith, and the axis its air mass and its horizon are
## measured from. World +Y before a camera is bound, which is the pole and not the horizon anywhere else.
func _local_up() -> Vector3:
	if _camera == null or not is_instance_valid(_camera):
		return Vector3.UP
	var r: Vector3 = _camera.global_position - _planet_centre
	return r.normalized() if r.length() > 0.001 else Vector3.UP
