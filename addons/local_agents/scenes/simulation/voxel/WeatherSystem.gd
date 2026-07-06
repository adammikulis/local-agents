class_name LAWeatherSystem
extends Node3D

# Prevailing WIND generator + emergent-rain relay. Weather no longer invents rain: the dense 3D
# MaterialField owns the real water cycle (evaporation -> cloud -> rain), and the RainLayer is the sole
# rain VISUAL (driven by local cloud density). This node keeps two jobs:
#   1) it drifts a slowly-changing prevailing WIND vector that VoxelWorld feeds into the atmosphere +
#      scent field (the wind that pushes clouds/vapor/scent around);
#   2) it RELAYS the field's emergent rain intensity as `rain()` and integrates a ground `wetness` from
#      it, so the ScentField's rain-washes-away-scent behaviour keeps working off the real, physical
#      precipitation rather than an invented shared-state number.
# No rain particles here (RainLayer owns the visual); no sun/ambient writes (day/night owns lighting).
# (Explicit types only — project rule: no ':=' inferred typing.)

signal weather_changed(rain_intensity: float, wetness: float)

var rain_intensity: float = 0.0        # 0 clear .. 1 downpour — RELAYED from the field's precipitation()
var wetness: float = 0.0               # ground wetness; rises with rain, dries slowly (scent wash reads it)
var wind: Vector3 = Vector3(1.0, 0.0, 0.3)   # horizontal prevailing wind (dir * strength, m/s-ish)

var _target_wind: Vector3 = Vector3(1.0, 0.0, 0.3)
var _wind_timer: float = 0.0

var _camera: Camera3D = null
var _field = null                      # LAMaterialField3D — the emergent water cycle (precipitation())


func setup(camera: Camera3D, _sun: DirectionalLight3D, _env: Environment) -> void:
	_camera = camera


## Wire the material field once it exists (created after setup in VoxelWorld). Rain is relayed from it.
func set_field(field) -> void:
	_field = field


func _process(delta: float) -> void:
	# Wind drifts on its own slow cycle; a storm's own rain feeds back a little extra gust.
	_wind_timer -= delta
	if _wind_timer <= 0.0:
		_wind_timer = randf_range(12.0, 30.0)
		var ang: float = randf() * TAU
		var strength: float = randf_range(1.0, 3.0) + rain_intensity * 5.0
		_target_wind = Vector3(cos(ang), 0.0, sin(ang)) * strength
	wind = wind.lerp(_target_wind, clampf(delta * 0.3, 0.0, 1.0))

	# Rain is now EMERGENT: relay the field's real precipitation (smoothed so wetness/scent don't jitter).
	var emergent_rain: float = 0.0
	if _field != null and _field.has_method("precipitation"):
		emergent_rain = float(_field.precipitation())
	rain_intensity = move_toward(rain_intensity, emergent_rain, delta * 0.5)

	# Wetness integrator: rises quickly under rain, dries slowly afterwards (scent wash reads this).
	if rain_intensity > wetness:
		wetness = move_toward(wetness, rain_intensity, delta * 0.4)
	else:
		wetness = move_toward(wetness, rain_intensity * 0.5, delta * 0.04)
	weather_changed.emit(rain_intensity, wetness)


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
