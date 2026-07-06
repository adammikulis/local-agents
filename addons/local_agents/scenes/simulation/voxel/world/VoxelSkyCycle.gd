class_name LAVoxelSkyCycle
extends Node

# Day/night + sky + lighting subsystem for the voxel world, factored out of the root so VoxelWorld
# stays a thin composition/harness root. Owns ALL sky lighting (sun arc + energy, sky colors, ambient,
# environment tuning, moon + lunar phase) so the cycle and weather never fight over the same
# properties; weather only supplies a rain factor that dims on top. time_of_day: 0=midnight, .25=dawn,
# .5=noon, .75=dusk. Dependency-free of the LAVoxelWorld type (dynamic access, no cyclic class
# reference). (Explicit types only — project rule: no ':=' inferred typing.)

var _sun: DirectionalLight3D = null
var _moon: DirectionalLight3D = null         # cool moonlight; energy tracks the lunar phase
var _sky_shader_mat: ShaderMaterial = null   # VoxelSky.gdshader: stars + phase-shaded moon disc
var _env: Environment = null
var _time_of_day: float = 0.30              # start just after dawn (dawn = .25) so the sun is already
                                            # up and climbing — the world reads as a lit morning
# Lunar cycle: an independent clock (survives day wraps). Starts at a waxing crescent so the
# very first night already has some moonlight rather than a black new moon.
var _lunar_phase: float = 0.15              # 0=new, 0.25=first quarter, 0.5=full, 0.75=last quarter

# Scene refs read each frame by the cycle (weather rain dims the sky; the field's cloud cover
# overcasts; the cloud/fog sheets are tinted with the sky). Bound after those systems are created.
var _weather: Node = null
var _material: Node = null
var _clouds: Node = null
var _fog: Node = null

const DAY_LENGTH: float = 200.0             # seconds per full day
const LUNAR_DAYS: float = 8.0               # in-game days per full new->full->new cycle
const SUN_ENERGY_NOON: float = 1.45
const AMBIENT_DAY: float = 0.62
const AMBIENT_NIGHT: float = 0.09           # dark floor; the moon lifts brightness on lit nights
const MOON_ENERGY_FULL: float = 0.32        # directional moonlight at full moon (navigable)
const MOON_AMBIENT: float = 0.14            # extra ambient fill at a full-moon night
const MOON_COLOR: Color = Color(0.55, 0.66, 0.95)
const SKY_TOP_DAY: Color = Color(0.36, 0.56, 0.86)
const SKY_TOP_NIGHT: Color = Color(0.02, 0.03, 0.11)
# Pale, near-white horizon so the surround reads cloudlike; the ground band and haze are
# matched to this every frame (see _update_day_night) so there is no false horizon line.
const SKY_HORIZON_DAY: Color = Color(0.86, 0.90, 0.94)
const SKY_HORIZON_NIGHT: Color = Color(0.05, 0.06, 0.15)
const SKY_HORIZON_DUSK: Color = Color(0.92, 0.48, 0.24)
const GROUND_HORIZON_DAY: Color = Color(0.62, 0.66, 0.62)
const GROUND_HORIZON_NIGHT: Color = Color(0.04, 0.05, 0.10)
const GROUND_BOTTOM_DAY: Color = Color(0.30, 0.34, 0.30)
const GROUND_BOTTOM_NIGHT: Color = Color(0.02, 0.02, 0.05)


# Build the sky material, WorldEnvironment, sun (with PSSM cascade-blend shadows) and moon, parenting
# them onto the world. `time_of_day` / `lunar_phase` seed the clocks (command-line overrides).
func setup(world: Node3D, time_of_day: float, lunar_phase: float) -> void:
	_time_of_day = time_of_day
	_lunar_phase = lunar_phase

	# --- Sun + sky ---
	# Custom sky shader (stars + phase-shaded moon) replaces ProceduralSkyMaterial; the day
	# gradient is driven from the same uniforms each frame so daytime looks unchanged. The sun
	# and moon lights below become LIGHT0 / LIGHT1 in the shader, which draws their discs.
	var env: WorldEnvironment = WorldEnvironment.new()
	var e: Environment = Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky: Sky = Sky.new()
	var sky_mat: ShaderMaterial = ShaderMaterial.new()
	sky_mat.shader = load("res://addons/local_agents/scenes/simulation/voxel/shaders/VoxelSky.gdshader")
	sky_mat.set_shader_parameter("sky_top_color", SKY_TOP_DAY)
	sky_mat.set_shader_parameter("sky_horizon_color", SKY_HORIZON_DAY)
	sky_mat.set_shader_parameter("ground_horizon_color", Color(0.62, 0.66, 0.62))
	sky_mat.set_shader_parameter("ground_bottom_color", Color(0.30, 0.34, 0.30))
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
	# SSAO tuned for terrain scale: the default 1m radius is invisible on kilometre-wide
	# hills, so widen it to occlude at valley/gully scale for real depth in creases and
	# under actors, with a gentle power curve so it reads as soft contact shadow, not grime.
	e.ssao_enabled = true
	e.ssao_radius = 3.5
	e.ssao_intensity = 2.2
	e.ssao_power = 1.6
	e.ssao_detail = 0.4
	e.ssao_horizon = 0.09
	e.ssao_sharpness = 0.95

	# HDR glow/bloom: only genuinely bright (>1.0) pixels bloom — incandescent lava, the
	# sun's specular glint on water, sunlit snow — so the scene gains punch without a
	# washed-out haze over everything. High threshold keeps midtone grass/rock crisp.
	e.glow_enabled = not OS.has_environment("NOGLOW")
	e.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	e.glow_intensity = 0.85
	e.glow_strength = 1.0
	e.glow_bloom = 0.05
	e.glow_hdr_threshold = 1.05
	e.glow_hdr_scale = 2.0
	e.glow_hdr_luminance_cap = 12.0
	e.glow_normalized = false
	# Only the two mid-frequency levels are active: bloom passes are the cost driver at
	# this resolution, and these give a soft halo without paying for full-res or very-wide
	# blur taps. (Baseline: enabling all 5 levels cost ~40% fps for no extra visible gain.)
	e.set_glow_level(1, 0.0)
	e.set_glow_level(2, 0.0)
	e.set_glow_level(3, 1.0)
	e.set_glow_level(4, 0.8)
	e.set_glow_level(5, 0.0)

	# Subtle atmospheric fog: gives the vista depth, hides the terrain-LOD pop at the
	# horizon, and dissolves the ocean's hard edge into the skyline instead of ending in a
	# line. Cheap (non-volumetric). Aerial perspective tints distant geometry toward the
	# sky so far mountains recede; sky_affect stays low so the sky itself isn't washed out.
	# fog_light_color is re-tinted to the horizon color every frame in _update_day_night.
	e.fog_enabled = not OS.has_environment("NOFOG")
	e.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	e.fog_light_color = SKY_HORIZON_DAY
	e.fog_light_energy = 1.0
	e.fog_sun_scatter = 0.15
	e.fog_density = 0.0016
	e.fog_aerial_perspective = 0.55
	e.fog_sky_affect = 0.05
	e.fog_height = -40.0
	e.fog_height_density = 0.012

	env.environment = e
	world.add_child(env)
	_sky_shader_mat = sky_mat
	_env = e

	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -47.0, 0.0)
	sun.light_energy = SUN_ENERGY_NOON
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 400.0
	# Smoother, softer sun shadows: blend the PSSM cascades so their seams don't pop as the
	# camera pans, soften the edges, and pull the split boundaries closer so near geometry
	# gets the crisp cascade. Bias tuned to kill acne on the rolling terrain without peter-
	# panning the low-poly actors. (GPU-side; free given the CPU-bound headroom.)
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

	# Moon: added after the sun so it is LIGHT1 in the sky shader. Cool light, energy driven
	# per-frame from the lunar phase (0 at new moon), so bright nights are navigable. It does NOT cast
	# shadows — a second full shadow pass is expensive and a soft fill light's shadows are imperceptible.
	var moon: DirectionalLight3D = DirectionalLight3D.new()
	moon.light_color = MOON_COLOR
	moon.light_energy = 0.0
	moon.shadow_enabled = false
	world.add_child(moon)
	_moon = moon


# Bind the scene systems the cycle reads each frame. Called after weather/material/clouds/fog exist.
func bind_scene(weather: Node, material: Node, clouds: Node, fog: Node) -> void:
	_weather = weather
	_material = material
	_clouds = clouds
	_fog = fog


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


# Advance the clock + drive all sky lighting from it. VoxelWorld calls this each frame.
func update(delta: float) -> void:
	_update_day_night(delta)


# Advance the clock and drive all sky lighting from it, dimmed by weather rain.
# Emergent day arc: sun elevation is a sine of the time of day; everything (light
# energy, warm horizon at dawn/dusk, ambient floor at night) follows from that one value.
func _update_day_night(delta: float) -> void:
	if _sun == null:
		return
	_time_of_day = fposmod(_time_of_day + delta / DAY_LENGTH, 1.0)
	# Sun elevation: -1 (midnight) .. +1 (noon), zero at dawn (.25) and dusk (.75).
	var elev: float = sin((_time_of_day - 0.25) * TAU)
	var daylight: float = clampf(elev, 0.0, 1.0)
	# Storm factor from weather dims the sun/ambient on top of the day cycle.
	var rain: float = 0.0
	if _weather != null and _weather.has_method("rain"):
		rain = _weather.rain()
	var storm: float = 1.0 - rain * 0.68
	# Overcast skies (the field's own emergent cloud cover) dim the sun + ambient on top of rain.
	var cloud_cover: float = 0.0
	if _material != null and _material.has_method("avg_cloud_cover"):
		cloud_cover = _material.avg_cloud_cover()
	storm *= 1.0 - clampf(cloud_cover * 1.5, 0.0, 0.6)

	# Sun arc: steep overhead at noon, shallow at the horizon near dawn/dusk; sweeps E->W.
	_sun.rotation_degrees = Vector3(-(6.0 + daylight * 66.0), -47.0 + (_time_of_day - 0.5) * 90.0, 0.0)
	_sun.light_energy = SUN_ENERGY_NOON * daylight * storm
	# Warm the sunlight near the horizon (dawn/dusk glow).
	var warm: float = clampf(1.0 - elev * 2.5, 0.0, 1.0) * clampf(daylight * 6.0, 0.0, 1.0)
	_sun.light_color = Color(1.0, 1.0, 1.0).lerp(Color(1.0, 0.6, 0.32), warm * 0.8)

	# Lunar cycle: advance the phase on its own slow clock; illuminated fraction is a cosine
	# of the phase (0 at new, 1 at full). The moon arcs opposite the sun (up through the night).
	_lunar_phase = fposmod(_lunar_phase + delta / (DAY_LENGTH * LUNAR_DAYS), 1.0)
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
		# Darken the ground band at night too, else the static ground horizon reads as a bright
		# pale strip against the dark night sky.
		_sky_shader_mat.set_shader_parameter("ground_horizon_color", GROUND_HORIZON_DAY.lerp(GROUND_HORIZON_NIGHT, night))
		_sky_shader_mat.set_shader_parameter("ground_bottom_color", GROUND_BOTTOM_DAY.lerp(GROUND_BOTTOM_NIGHT, night))
		_sky_shader_mat.set_shader_parameter("night", night)
		_sky_shader_mat.set_shader_parameter("moon_phase", _lunar_phase)
		# Sun/moon directions drive the discs directly (basis.z of a DirectionalLight3D points
		# back toward the light, i.e. where it sits in the sky).
		_sky_shader_mat.set_shader_parameter("sun_dir", _sun.global_transform.basis.z)
		_sky_shader_mat.set_shader_parameter("sun_energy", _sun.light_energy)
		_sky_shader_mat.set_shader_parameter("sun_color", _sun.light_color)
		if _moon != null:
			_sky_shader_mat.set_shader_parameter("moon_dir", _moon.global_transform.basis.z)
	if _env != null:
		# Dark night floor, lifted softly on bright-moon nights so full moons are navigable.
		_env.ambient_light_energy = lerpf(AMBIENT_NIGHT, AMBIENT_DAY, daylight) * storm \
			+ moon_illum * night * MOON_AMBIENT * storm
		# Keep the distance fog matched to the current horizon so far terrain and the
		# ocean melt into the same color the sky shows there (warm at dusk, dark at night).
		var fog_col: Color = SKY_HORIZON_DAY.lerp(SKY_HORIZON_NIGHT, night)
		fog_col = fog_col.lerp(SKY_HORIZON_DUSK, warm * 0.7)
		_env.fog_light_color = fog_col

	# Tint the field's cloud/fog sheets with the sky: white by day, dusk-orange near sunset, dark at
	# night (unshaded sheets, so the tint is what makes them read against the time of day).
	var cloud_tint: Color = Color(1.0, 1.0, 1.0).lerp(Color(0.10, 0.12, 0.18), night)
	cloud_tint = cloud_tint.lerp(Color(1.0, 0.55, 0.30), warm * 0.6)
	if _clouds != null:
		_clouds.set_tint(cloud_tint)
	if _fog != null:
		_fog.set_tint(cloud_tint)
	# NOTE: the material field is NOT fed rain/daylight here — it reads the sun node directly and
	# derives its own heating/weather. This day/night code only owns the sky + sun transform/energy.
	# The ecology clock is fed from VoxelWorld._process via time_of_day() (kept decoupled here).
