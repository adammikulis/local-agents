class_name LAWeatherSystem
extends Node3D

# Cosmetic surface-breeze vector + a relay of the field's emergent precipitation.
# The planet's real banded prevailing wind is per-cell in wind_step_sphere3d.glsl; this node does not drive it.

var rain_intensity: float = 0.0        # 0 clear .. 1 downpour — relayed from the field's precipitation()
var wind: Vector3 = Vector3(1.0, 0.0, 0.3)   # horizontal breeze (dir * strength, m/s)

var _target_wind: Vector3 = Vector3(1.0, 0.0, 0.3)
var _wind_timer: float = 0.0

var _field = null                      # LAMaterialField3D — source of precipitation()


func setup(_camera: Camera3D, _sun: DirectionalLight3D, _env: Environment) -> void:
	pass


## Wire the material field once it exists (created after setup in VoxelWorld).
func set_field(field) -> void:
	_field = field


func _physics_process(delta: float) -> void:
	_wind_timer -= delta
	if _wind_timer <= 0.0:
		# Seeded (LASimRng): the breeze feeds moisture transport -> charge -> emergent lightning, so its
		# randomness must reproduce from LA_SIM_SEED for a deterministic run.
		var rng: LASimRng = LASimRng.for_domain("planet")
		_wind_timer = rng.randf_range(18.0, 40.0)
		var ang: float = rng.randf() * TAU
		var strength: float = rng.randf_range(0.5, 1.5) + rain_intensity * 2.0
		_target_wind = Vector3(cos(ang), 0.0, sin(ang)) * strength
	wind = wind.lerp(_target_wind, clampf(delta * 0.3, 0.0, 1.0))

	# Relay the field's precipitation, smoothed so the sky visual does not jitter.
	var emergent_rain: float = 0.0
	if _field != null and _field.has_method("precipitation"):
		emergent_rain = float(_field.precipitation())
	rain_intensity = move_toward(rain_intensity, emergent_rain, delta * 0.5)


func rain() -> float:
	return rain_intensity


func wind_vector() -> Vector3:
	return wind
