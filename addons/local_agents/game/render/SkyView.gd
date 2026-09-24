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
## Rayleigh cross-section of one molecule, m^2, per channel, and molar mass, kg/mol, of each substance whose
## row states its refractivity.
var _sigma: Dictionary = {}
var _molar: Dictionary = {}
## Each channel that holds gas: its substance, and the derived share of it that is gas, "" when it all is.
var _gas_channels: Array[Dictionary] = []
## The gases already named as scattering by no stated law.
var _unscattered: Dictionary = {}
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
	var table: Dictionary = LASubstances.table()
	for id in table:
		var row: Dictionary = table[id]
		if row.has("refractivity_ref_p_pa"):
			_sigma[id] = rayleigh_cross_sections_m2(row, CHANNEL_WAVELENGTHS_NM)
			_molar[id] = float(row["molar_mass"])
	_gas_channels = gas_channels()
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


## What the sky was drawn through, read again off the cell: its pressure, temperature, solved gravity, height
## over the ground and gases, beside the coefficient and scale height the sky took from them.
func _publish_air(air: Dictionary) -> void:
	var line: Dictionary = {"air": not air.is_empty()}
	if not air.is_empty():
		var c: int = int(air["cell"])
		var at: Vector3 = _field.field_to_point(_field._grid.cell_world_pos(c))
		var beta: Vector3 = air["beta_ground"]
		line["cell"] = c
		line["p_pa"] = _field._mirrors.at("pressure", c)
		line["t_c"] = _field._mirrors.at("temp", c)
		line["g_m_s2"] = LABallistics.g_at(at).length()
		line["height_m"] = (at - _body.center()).length() - _ground_r
		line["gas_mol_m3"] = _gas_at(c)
		line["beta_ground_per_m"] = [beta.x, beta.y, beta.z]
		line["scale_height_m"] = air["scale_height"]
	var text: String = JSON.stringify(line)
	if text != _published:
		_published = text
		print("SKY_AIR=", text)


## The solved surface of the body under the eye, read again once the eye has crossed `ground_resolve_rad`.
func _ground_radius(from_centre: Vector3) -> float:
	var dir: Vector3 = from_centre.normalized()
	if _ground_dir == Vector3.ZERO or _ground_dir.angle_to(dir) > ground_resolve_rad:
		_ground_dir = dir
		_ground_r = _body.surface_radius(dir)
		if not is_finite(_ground_r):
			push_error("LASkyView: the body solves no surface under the eye, so the sky has no ground to stand on.")
	return _ground_r


## The air over the ground under the eye, read at `_air_cell` and carried down an isothermal column of its
## own composition: its Rayleigh coefficient at that ground per channel, 1/m, its scale height R T / (M g), m,
## and the cell. Empty with no air, or with a gas whose row states no refractivity.
func _air_over_ground(eye: Vector3, up: Vector3, r_ground: float) -> Dictionary:
	if _field == null or not is_finite(r_ground):
		return {}
	var c: int = _air_cell(eye, up)
	if c < 0:
		return {}
	var gas: Dictionary = _gas_at(c)
	var total: float = 0.0
	for id in gas:
		total += float(gas[id])
	var at: Vector3 = _field.field_to_point(_field._grid.cell_world_pos(c))
	var p_pa: float = _field._mirrors.at("pressure", c)
	var t_k: float = _field._mirrors.at("temp", c) + LAPhysical.KELVIN_OFFSET
	var g: float = LABallistics.g_at(at).length()
	if not (total > 0.0 and p_pa > 0.0 and t_k > 0.0 and g > 0.0):
		return {}
	var sigma: Vector3 = Vector3.ZERO
	var molar: float = 0.0
	for id in gas:
		if not _sigma.has(id):
			if not _unscattered.has(id):
				_unscattered[id] = true
				push_error("LASkyView: the air holds %s, whose row states no refractivity, so the sky is not drawn." % id)
			return {}
		var x: float = float(gas[id]) / total
		sigma += (_sigma[id] as Vector3) * x
		molar += float(_molar[id]) * x
	var scale_h: float = LAPhysical.GAS_CONSTANT_J_MOL_K * t_k / (molar * g)
	var per_m3: float = p_pa / (LAPhysical.BOLTZMANN_J_K * t_k)
	var above_ground: float = (at - _body.center()).length() - r_ground
	return {"beta_ground": sigma * per_m3 * exp(above_ground / scale_h), "scale_height": scale_h, "cell": c}


## The cell of the field that holds the eye's air: the eye's own, or from above the box the first one under
## it. From a cell of rock or water the column is walked up to the first that holds gas, from an empty one
## down to it; -1 where the walk leaves the matter it started in before it meets any.
func _air_cell(eye: Vector3, up: Vector3) -> int:
	var c: int = _field.world_to_cell(eye)
	if c < 0:
		c = _field.world_to_cell(_box_entry_below(eye, up))
	var upward: bool = c >= 0 and _field._mirrors.at("rho_bulk", c) > 0.0
	for _k in _field._grid.max_span():
		if c < 0:
			return -1
		if not _gas_at(c).is_empty():
			return c
		if (_field._mirrors.at("rho_bulk", c) > 0.0) != upward:
			return -1
		c = LAFieldGeometry.above(_field, c) if upward else LAFieldGeometry.below(_field, c)
	return -1


## The gas cell `c` holds, mol per m^3 of cell, by substance.
func _gas_at(c: int) -> Dictionary:
	var out: Dictionary = {}
	for ch in _gas_channels:
		var amount: float = _field._mirrors.at(ch["channel"], c)
		if String(ch["share"]) != "":
			amount *= _field._mirrors.at(ch["share"], c)
		if amount > 0.0:
			out[ch["substance"]] = float(out.get(ch["substance"], 0.0)) + amount
	return out


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


## Every channel that holds an amount of gas: a gas channel whole, and a channel whose phase is derived by the
## share of it its `_vapour` buffer says is gas.
static func gas_channels() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var rows: Dictionary = LAChannels.rows()
	var derived: PackedStringArray = LAChannels.derived_buffers()
	for name in rows:
		var row: Dictionary = rows[name]
		if String(row["unit"]) != "mol_m3":
			continue
		if String(row["phase"]) == "gas":
			out.push_back({"channel": String(name), "substance": String(row["substance"]), "share": ""})
		elif String(row["phase"]) == "" and derived.has(String(name) + "_vapour"):
			out.push_back({"channel": String(name), "substance": String(row["substance"]),
				"share": String(name) + "_vapour"})
	return out


## Rayleigh cross-section of one molecule of the substance `row` describes, m^2, at each of `nm`.
static func rayleigh_cross_sections_m2(row: Dictionary, nm: Vector3) -> Vector3:
	return Vector3(rayleigh_cross_section_m2(row, nm.x * 1.0e-9), rayleigh_cross_section_m2(row, nm.y * 1.0e-9),
		rayleigh_cross_section_m2(row, nm.z * 1.0e-9))


## 24 pi^3 / (lambda^4 N^2) ((n^2 - 1) / (n^2 + 2))^2 F_K, m^2: the row's refractivity at its reference number
## density N and its King factor F_K, both read at `lambda_m`.
static func rayleigh_cross_section_m2(row: Dictionary, lambda_m: float) -> float:
	var s2: float = pow(1.0e-6 / lambda_m, 2.0)
	var b: Array = row["refractivity_b"]
	var c: Array = row["refractivity_c"]
	var d: Array = row["refractivity_d_um2"]
	var poly: Array = row["refractivity_poly"]
	var king_poly: Array = row["king_factor"]
	var y: float = 0.0
	for i in b.size():
		y += float(b[i]) / (float(c[i]) - float(d[i]) * s2)
	for j in poly.size():
		y += float(poly[j]) * pow(s2, float(j))
	var n2m1: float = y if bool(row["refractivity_squared"]) else y * (2.0 + y)
	var king: float = 0.0
	for j in king_poly.size():
		king += float(king_poly[j]) * pow(s2, float(j))
	var per_m3: float = float(row["refractivity_ref_p_pa"]) \
		/ (LAPhysical.BOLTZMANN_J_K * (float(row["refractivity_ref_t_c"]) + LAPhysical.KELVIN_OFFSET))
	var ll: float = n2m1 / (n2m1 + 3.0)
	return 24.0 * pow(PI, 3.0) / (pow(lambda_m, 4.0) * per_m3 * per_m3) * ll * ll * king


func _get_configuration_warnings() -> PackedStringArray:
	var env: WorldEnvironment = get_node_or_null("Environment") as WorldEnvironment
	var ok: bool = env != null and env.environment != null and env.environment.sky != null \
		and env.environment.sky.sky_material is ShaderMaterial and get_node_or_null("Sun") is DirectionalLight3D
	if not ok:
		return PackedStringArray(["No air, sky material or sun: instance SkyView.tscn, which authors them."])
	return PackedStringArray()
