class_name LAWeatherSystem
extends Node3D

# Continuous weather that drifts over time: cloudiness/rain/wetness. Drives rain
# visuals + sun/ambient dimming, and exposes rain/wetness so other systems react —
# notably the ScentField, where RAIN WASHES AWAY SCENT (predators lose trails in the
# wet). No heavy fluid sim; weather is a shared state, not a solver.
# (Explicit types only — project rule: no ':=' inferred typing.)

signal weather_changed(rain_intensity: float, wetness: float)

var rain_intensity: float = 0.0        # 0 clear .. 1 downpour
var wetness: float = 0.0               # ground wetness; rises with rain, dries slowly
var wind: Vector3 = Vector3(1.0, 0.0, 0.3)   # horizontal wind (dir * strength, m/s-ish)

var _target_rain: float = 0.0
var _target_wind: Vector3 = Vector3(1.0, 0.0, 0.3)
var _phase_timer: float = 0.0
var _wind_timer: float = 0.0

var _camera: Camera3D = null
var _rain: GPUParticles3D = null
var _sun: DirectionalLight3D = null
var _env: Environment = null
var _sun_energy_clear: float = 1.35


func setup(camera: Camera3D, sun: DirectionalLight3D, env: Environment) -> void:
	_camera = camera
	_sun = sun
	_env = env
	if _sun != null:
		_sun_energy_clear = _sun.light_energy
	_build_rain()


func _build_rain() -> void:
	_rain = GPUParticles3D.new()
	_rain.amount = 1200
	_rain.lifetime = 1.3
	_rain.emitting = false
	_rain.local_coords = false
	var mesh: QuadMesh = QuadMesh.new()
	mesh.size = Vector2(0.03, 0.6)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.72, 0.8, 0.92, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mesh.material = mat
	_rain.draw_pass_1 = mesh
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(45.0, 1.0, 45.0)
	pm.direction = Vector3(0.12, -1.0, 0.05)
	pm.spread = 3.0
	pm.initial_velocity_min = 42.0
	pm.initial_velocity_max = 58.0
	pm.gravity = Vector3(0.0, -30.0, 0.0)
	_rain.process_material = pm
	add_child(_rain)


func _process(delta: float) -> void:
	_phase_timer -= delta
	if _phase_timer <= 0.0:
		_phase_timer = randf_range(20.0, 45.0)
		var roll: float = randf()
		if roll < 0.45:
			_target_rain = 0.0                       # clear spell
		elif roll < 0.8:
			_target_rain = randf_range(0.2, 0.5)     # light rain
		else:
			_target_rain = randf_range(0.6, 1.0)     # storm
	# Wind drifts on its own cycle; storms bring stronger gusts.
	_wind_timer -= delta
	if _wind_timer <= 0.0:
		_wind_timer = randf_range(12.0, 30.0)
		var ang: float = randf() * TAU
		var strength: float = randf_range(1.0, 3.0) + rain_intensity * 5.0
		_target_wind = Vector3(cos(ang), 0.0, sin(ang)) * strength
	wind = wind.lerp(_target_wind, clampf(delta * 0.3, 0.0, 1.0))
	rain_intensity = move_toward(rain_intensity, _target_rain, delta * 0.16)
	if rain_intensity > wetness:
		wetness = move_toward(wetness, rain_intensity, delta * 0.4)
	else:
		wetness = move_toward(wetness, rain_intensity * 0.5, delta * 0.04)   # dries slowly
	_apply_visuals()
	weather_changed.emit(rain_intensity, wetness)


func _apply_visuals() -> void:
	if _rain != null:
		_rain.emitting = rain_intensity > 0.02
		_rain.amount_ratio = clampf(rain_intensity, 0.05, 1.0)
		if _camera != null:
			_rain.global_position = _camera.global_position + Vector3(0.0, 24.0, 0.0)
		var pm: ParticleProcessMaterial = _rain.process_material as ParticleProcessMaterial
		if pm != null:
			var lean: Vector3 = Vector3(wind.x * 0.06, -1.0, wind.z * 0.06).normalized()
			pm.direction = lean
	# NOTE: sun energy + ambient are owned by VoxelWorld's day/night cycle (which folds in
	# a rain-dimming factor of its own), so weather no longer writes them — avoids two
	# systems fighting over the same lighting each frame.


func rain() -> float:
	return rain_intensity


func wet() -> float:
	return wetness


func wind_vector() -> Vector3:
	return wind


func describe() -> String:
	if rain_intensity < 0.05:
		return "clear"
	elif rain_intensity < 0.55:
		return "rain"
	return "storm"
