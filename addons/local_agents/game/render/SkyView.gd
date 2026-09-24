@tool
class_name LASkyView
extends Node3D

## The sky the frame is drawn through: this body's own air, read off the field, scattering the star that is
## in the scene; the star's and the moon's discs seen through that air; and the sunlight it lets down to the
## ground under the eye. A world whose field holds no air there has a black sky and an unreddened sun.

const SHOOT_FLAG: String = "--shoot="
## The wavelength each colour channel stands for, nm, red to blue. A choice of the renderer, not the world.
const CHANNEL_WAVELENGTHS_NM: Vector3 = Vector3(680.0, 550.0, 440.0)

@export_group("Ground")
## Arc the eye may cross over the body, rad, before the solved surface under it is read again.
@export var ground_resolve_rad: float = 1.0e-5

var _field: LAMaterialField3D = null
var _body: LAPlanetBody = null
var _star: Node3D = null
var _moon: LAMoon = null
var _camera: Node3D = null
## Rayleigh cross-section of one molecule of the seeded air, m^2, per channel.
var _sigma: Vector3 = Vector3.ZERO
var _ground_dir: Vector3 = Vector3.ZERO
var _ground_r: float = NAN
## A photographed run publishes the air the sky was drawn through, each time it changes.
var _publish: bool = false
var _published: String = ""

@onready var _world_env: WorldEnvironment = $Environment
@onready var _sun: DirectionalLight3D = $Sun


## The world the sky stands over and the eye it is drawn for. `render_opts` switches the effects the
## settings own; the air, the star and the moon are read off the field and the bodies every frame.
func setup(field: LAMaterialField3D, body: LAPlanetBody, star: Node3D, moon: LAMoon, camera: Node3D,
		render_opts: Dictionary) -> void:
	_field = field
	_body = body
	_star = star
	_moon = moon
	_camera = camera
	var env: Environment = _world_env.environment
	env.ssao_enabled = bool(render_opts["ssao"])
	env.glow_enabled = bool(render_opts["glow"])
	env.fog_enabled = bool(render_opts["fog"])
	_sun.shadow_enabled = bool(render_opts["sun_shadows"])
	_sigma = seeded_air_cross_section_m2()
	if not _sigma.is_finite():
		push_error("LASkyView: a seeded gas carries no Rayleigh data, so the air scatters nothing here.")
		_sigma = Vector3.ZERO
	for arg in OS.get_cmdline_user_args():
		_publish = _publish or String(arg).begins_with(SHOOT_FLAG)


func sun() -> DirectionalLight3D:
	return _sun


func set_shadows(on: bool) -> void:
	_sun.shadow_enabled = on


func set_ssao(on: bool) -> void:
	_world_env.environment.ssao_enabled = on


## Local solar time at the eye on the conventional dial, 0.25 sunrise, 0.5 noon, 0.75 sunset: how far the
## body's spin has carried the eye's meridian past the star's. NAN before the eye and the star are bound.
func time_of_day() -> float:
	if _camera == null or _star == null or _body == null:
		return NAN
	var n: Vector3 = _body.spin_axis().normalized()
	var here: Vector3 = _camera.global_position - _body.center()
	var sun_at: Vector3 = _star.global_position - _body.center()
	var a: Vector3 = here - n * here.dot(n)
	var b: Vector3 = sun_at - n * sun_at.dot(n)
	if a.length() < 1.0e-6 or b.length() < 1.0e-6:
		return NAN
	return fposmod(0.5 - atan2(a.cross(b).dot(n), a.dot(b)) / TAU, 1.0)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or _camera == null or not is_instance_valid(_camera) or _body == null:
		return
	var centre: Vector3 = _body.center()
	var eye: Vector3 = _camera.global_position
	var up: Vector3 = (eye - centre).normalized()
	var to_star: Vector3 = (_star.global_position - centre).normalized()
	_sun.look_at_from_position(Vector3.ZERO, -to_star, Vector3.UP if absf(to_star.y) < 0.98 else Vector3.RIGHT)
	var r_ground: float = _ground_radius(eye - centre)
	var h_eye: float = (eye - centre).length() - r_ground
	var mu_sun: float = to_star.dot(up)
	var mat: ShaderMaterial = _world_env.environment.sky.sky_material as ShaderMaterial
	mat.set_shader_parameter("ground_radius_m", r_ground)
	mat.set_shader_parameter("eye_height_m", h_eye)
	mat.set_shader_parameter("planet_up", up)
	mat.set_shader_parameter("sun_dir", to_star)
	mat.set_shader_parameter("sun_cos_radius",
		_cos_angular_radius(_star.global_position, float(LABodySeeds.of("star").get("radius_m", -1.0)), eye))
	_apply_moon(mat, eye)
	# With no air the beam reaches the ground whole while the star is over its horizon, and nothing fogs.
	var t: Vector3 = Vector3.ONE if mu_sun > 0.0 else Vector3.ZERO
	var fog: float = 0.0
	var air: Dictionary = _air_over_ground(eye, up, r_ground)
	var beta: Vector3 = Vector3.ZERO
	if not air.is_empty():
		beta = air["beta_ground"]
		var scale_h: float = air["scale_height"]
		mat.set_shader_parameter("air_scale_height_m", scale_h)
		t = beam_transmission(beta, scale_h, r_ground, mu_sun)
		# The fog is the same air between the eye and what it looks at: its extinction where the eye stands.
		fog = beta.y * exp(-h_eye / scale_h)
	mat.set_shader_parameter("rayleigh_beta_ground", beta)
	_sun.light_color = Color(t.x, t.y, t.z).linear_to_srgb()
	_world_env.environment.fog_density = fog
	if _publish:
		_publish_air(air)


func _publish_air(air: Dictionary) -> void:
	var beta: Vector3 = air.get("beta_ground", Vector3.ZERO)
	var line: String = JSON.stringify({"air": not air.is_empty(),
		"beta_ground_per_m": [beta.x, beta.y, beta.z] if not air.is_empty() else [],
		"scale_height_m": air.get("scale_height", null)})
	if line != _published:
		_published = line
		print("SKY_AIR=", line)


## The solved surface of the body under the eye, read again once the eye has crossed `ground_resolve_rad`.
func _ground_radius(from_centre: Vector3) -> float:
	var dir: Vector3 = from_centre.normalized()
	if _ground_dir == Vector3.ZERO or _ground_dir.angle_to(dir) > ground_resolve_rad:
		_ground_dir = dir
		_ground_r = _body.surface_radius(dir)
		if not is_finite(_ground_r):
			push_error("LASkyView: the body solves no surface under the eye, so the sky has no ground to stand on.")
	return _ground_r


## The air over the ground under the eye, read at `_air_cell` and carried down the isothermal column the seed
## lays: its Rayleigh coefficient at that ground per channel, 1/m, and its scale height, m. Empty with no air.
func _air_over_ground(eye: Vector3, up: Vector3, r_ground: float) -> Dictionary:
	if _field == null or not is_finite(r_ground):
		return {}
	var c: int = _air_cell(eye, up)
	if c < 0:
		return {}
	var at: Vector3 = _field.field_to_point(_field._grid.cell_world_pos(c))
	var p_pa: float = _field._mirrors.at("pressure", c)
	var t_c: float = _field._mirrors.at("temp", c)
	var g: float = LABallistics.g_at(at).length()
	if not (p_pa > 0.0 and g > 0.0 and is_finite(t_c)):
		return {}
	var scale_h: float = LAFieldLithostaticSeed.seeded_air_rt_over_m(t_c) / g
	var per_m3: float = p_pa / (LAPhysical.BOLTZMANN_J_K * (t_c + LAPhysical.KELVIN_OFFSET))
	var above_ground: float = (at - _body.center()).length() - r_ground
	return {"beta_ground": _sigma * per_m3 * exp(above_ground / scale_h), "scale_height": scale_h}


## The cell of the field that holds the eye's air: the eye's own, or from above the box the first one under
## it; an eye in rock or water steps up out of it, one in an empty cell steps down toward the ground. -1
## where the column reaches no air.
func _air_cell(eye: Vector3, up: Vector3) -> int:
	var c: int = _field.world_to_cell(eye)
	if c < 0:
		c = _field.world_to_cell(_box_entry_below(eye, up))
	var down: bool = c >= 0 and not _rock_or_water(c)
	for _k in _field._grid.max_span():
		if c < 0:
			return -1
		if _rock_or_water(c):
			if down:
				return -1
			c = LAFieldGeometry.above(_field, c)
		elif _field._mirrors.at("pressure", c) > 0.0:
			return c
		elif down:
			c = LAFieldGeometry.below(_field, c)
		else:
			return -1
	return -1


func _rock_or_water(c: int) -> bool:
	return _field._solid[c] != 0 or _field._queries.liquid_at(c) >= LAMaterialField3D.MIN_MASS


## Where the line from the eye down to the body centre enters the field's box; the eye itself when it never
## does, which no cell holds.
func _box_entry_below(eye: Vector3, up: Vector3) -> Vector3:
	var grid: LAVoxelGrid = _field._grid
	var from: Vector3 = _field.point_to_field(eye)
	var down: Vector3 = _field.dir_to_field(-up)
	var box: AABB = AABB(grid.origin, Vector3(grid.nx, grid.ny, grid.nz) * grid.cell_size)
	var hit: Variant = box.intersects_ray(from, down)
	if hit == null:
		return eye
	return _field.field_to_point((hit as Vector3) + down * (0.5 * grid.cell_size * pow(0.5, grid.max_level)))


## The moon's disc: where it stands, how large it looks, which way the star lights it, and its rock's albedo.
## Absent when the system has no moon, or one that cannot say its size or what it reflects.
func _apply_moon(mat: ShaderMaterial, eye: Vector3) -> void:
	var albedo: float = _moon.albedo() if _moon != null and is_instance_valid(_moon) else -1.0
	var cos_r: float = _cos_angular_radius(_moon.global_position, _moon.radius(), eye) if albedo >= 0.0 else 1.0
	mat.set_shader_parameter("moon_cos_radius", cos_r)
	mat.set_shader_parameter("moon_albedo", maxf(albedo, 0.0))
	if cos_r >= 1.0:
		return
	mat.set_shader_parameter("moon_dir", (_moon.global_position - eye).normalized())
	mat.set_shader_parameter("moon_sun_dir", (_star.global_position - _moon.global_position).normalized())


## Cosine of the angle a body of radius `r` at `at` subtends at `eye`; 1.0, no disc, when its radius is
## unknown or the eye is inside it.
static func _cos_angular_radius(at: Vector3, r: float, eye: Vector3) -> float:
	var dist: float = eye.distance_to(at)
	if not (r > 0.0) or dist <= r:
		return 1.0
	return sqrt(1.0 - (r / dist) * (r / dist))


## The share of the star's light, per channel, that reaches the ground through an isothermal column of
## scale height `scale_h` whose Rayleigh coefficient at the ground (radius `r_ground`) is `beta`, the star at
## cosine `mu_sun` to the vertical there. Zero once the star is below that ground's horizon.
static func beam_transmission(beta: Vector3, scale_h: float, r_ground: float, mu_sun: float) -> Vector3:
	if not (mu_sun > 0.0):
		return Vector3.ZERO
	var x: float = r_ground / scale_h
	var tau: Vector3 = beta * scale_h * sqrt(0.5 * PI * x) * erfcx(sqrt(0.5 * x) * mu_sun)
	return Vector3(exp(-tau.x), exp(-tau.y), exp(-tau.z))


## exp(y^2) erfc(y) for y >= 0 (Press et al. 1992, Numerical Recipes 2nd ed. 6.2, fractional error < 1.2e-7).
static func erfcx(y: float) -> float:
	var t: float = 1.0 / (1.0 + 0.5 * y)
	return t * exp(-1.26551223 + t * (1.00002368 + t * (0.37409196 + t * (0.09678418 + t * (-0.18628806
		+ t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 + t * (-0.82215223 + t * 0.17087277)))))))))


## Rayleigh cross-section of one molecule of the seeded air, m^2, per channel: each gas's own, weighted by
## its mole fraction. NAN in every channel when one of the gases carries no optical data.
static func seeded_air_cross_section_m2() -> Vector3:
	var x: Dictionary = LAFieldLithostaticSeed.seeded_air_mole_fractions()
	var out: Vector3 = Vector3.ZERO
	for gas: String in x:
		for ch in 3:
			out[ch] += float(x[gas]) * rayleigh_cross_section_m2(gas, CHANNEL_WAVELENGTHS_NM[ch] * 1.0e-9)
	return out


## Rayleigh cross-section of one molecule of `gas` at wavelength `lambda_m`, m^2: the Lorentz-Lorenz form
## over the gas's measured refractive index and King factor, or its own measured law. NAN for a gas with no
## optical data.
static func rayleigh_cross_section_m2(gas: String, lambda_m: float) -> float:
	var um2: float = pow(lambda_m * 1.0e6, 2.0)
	var stp_per_m3: float = LAPhysical.STANDARD_PRESSURE_PA / (LAPhysical.BOLTZMANN_J_K * LAPhysical.KELVIN_OFFSET)
	match gas:
		"n2":
			var n2m1: float = 0.0
			for i in LAPhysical.N2_SELLMEIER_B.size():
				n2m1 += LAPhysical.N2_SELLMEIER_B[i] * um2 / (um2 - LAPhysical.N2_SELLMEIER_C_UM2[i])
			var ref_per_m3: float = LAPhysical.N2_REFRACTIVITY_REF_P_PA / (LAPhysical.BOLTZMANN_J_K * LAPhysical.KELVIN_OFFSET)
			return _lorentz_lorenz(n2m1, ref_per_m3, lambda_m) \
				* (LAPhysical.N2_KING_FACTOR + LAPhysical.N2_KING_FACTOR_UM2 / um2)
		"co2":
			var nm1: float = 0.0
			for i in LAPhysical.CO2_REFRACTIVITY_B.size():
				nm1 += LAPhysical.CO2_REFRACTIVITY_B[i] / (LAPhysical.CO2_REFRACTIVITY_C_PER_UM2[i] - 1.0 / um2)
			var wavenumber_per_cm: float = 1.0e-2 / lambda_m
			return _lorentz_lorenz(nm1 * (2.0 + nm1), stp_per_m3, lambda_m) \
				* (LAPhysical.CO2_KING_FACTOR + LAPhysical.CO2_KING_FACTOR_CM2 * wavenumber_per_cm * wavenumber_per_cm)
		"h2":
			var angstrom: float = lambda_m * 1.0e10
			var d: Array[float] = LAPhysical.H2_RAYLEIGH_D_CM2
			return 1.0e-4 * (d[0] / pow(angstrom, 4.0) + d[1] / pow(angstrom, 6.0) + d[2] / pow(angstrom, 8.0))
	return NAN


## 24 pi^3 / (lambda^4 N^2) ((n^2 - 1) / (n^2 + 2))^2 for n^2 - 1 taken at number density N, m^2.
static func _lorentz_lorenz(n2m1: float, per_m3: float, lambda_m: float) -> float:
	var ll: float = n2m1 / (n2m1 + 3.0)
	return 24.0 * pow(PI, 3.0) / (pow(lambda_m, 4.0) * per_m3 * per_m3) * ll * ll


func _get_configuration_warnings() -> PackedStringArray:
	var env: WorldEnvironment = get_node_or_null("Environment") as WorldEnvironment
	var ok: bool = env != null and env.environment != null and env.environment.sky != null \
		and env.environment.sky.sky_material is ShaderMaterial and get_node_or_null("Sun") is DirectionalLight3D
	if not ok:
		return PackedStringArray(["No air, sky material or sun: instance SkyView.tscn, which authors them."])
	return PackedStringArray()
