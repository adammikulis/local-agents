extends RefCounted
class_name LocalAgentsWeatherSystem

const TileKeyUtilsScript = preload("res://addons/local_agents/simulation/TileKeyUtils.gd")
const WeatherComputeBackendScript = preload("res://addons/local_agents/simulation/WeatherComputeBackend.gd")
const CadencePolicyScript = preload("res://addons/local_agents/simulation/CadencePolicy.gd")
const NativeComputeBridgeScript = preload("res://addons/local_agents/simulation/controller/NativeComputeBridge.gd")

var _width: int = 0
var _height: int = 0
var _seed: int = 0
var _configured: bool = false
var _emit_rows: bool = true
var _wind_angle: float = 0.0
var _wind_speed: float = 0.4
var _time_accum: float = 0.0
var _compute_requested: bool = false
var _compute_active: bool = false
var _compute_backend = WeatherComputeBackendScript.new()

var _base_moisture := PackedFloat32Array()
var _base_temperature := PackedFloat32Array()
var _water_reliability := PackedFloat32Array()
var _elevation := PackedFloat32Array()
var _slope := PackedFloat32Array()

var _cloud := PackedFloat32Array()
var _humidity := PackedFloat32Array()
var _rain := PackedFloat32Array()
var _wetness := PackedFloat32Array()
var _fog := PackedFloat32Array()
var _orographic := PackedFloat32Array()
var _rain_shadow := PackedFloat32Array()
var _activity := PackedFloat32Array()
var _idle_cadence: int = 8

func configure_environment(environment_snapshot: Dictionary, water_snapshot: Dictionary, seed: int) -> Dictionary:
	_seed = seed
	_width = int(environment_snapshot.get("width", 0))
	_height = int(environment_snapshot.get("height", 0))
	_configured = _width > 0 and _height > 0
	if not _configured:
		return {"ok": false, "error": "invalid_dimensions"}

	var n = _width * _height
	_base_moisture.resize(n)
	_base_temperature.resize(n)
	_water_reliability.resize(n)
	_elevation.resize(n)
	_slope.resize(n)
	_cloud.resize(n)
	_humidity.resize(n)
	_rain.resize(n)
	_wetness.resize(n)
	_fog.resize(n)
	_orographic.resize(n)
	_rain_shadow.resize(n)
	_activity.resize(n)

	var tile_index: Dictionary = environment_snapshot.get("tile_index", {})
	var water_tiles: Dictionary = water_snapshot.get("water_tiles", {})
	for y in range(_height):
		for x in range(_width):
			var tile_id = TileKeyUtilsScript.tile_id(x, y)
			var idx = _i(x, y)
			var row: Dictionary = tile_index.get(tile_id, {})
			var water: Dictionary = water_tiles.get(tile_id, {})
			var moisture = clampf(float(row.get("moisture", 0.45)), 0.0, 1.0)
			var temperature = clampf(float(row.get("temperature", 0.5)), 0.0, 1.0)
			var elevation = clampf(float(row.get("elevation", 0.5)), 0.0, 1.0)
			var slope = clampf(float(row.get("slope", 0.15)), 0.0, 1.0)
			var reliability = clampf(float(water.get("water_reliability", 0.0)), 0.0, 1.0)
			_base_moisture[idx] = moisture
			_base_temperature[idx] = temperature
			_elevation[idx] = elevation
			_slope[idx] = slope
			_water_reliability[idx] = reliability
			var noise = _hash01(x, y, seed)
			_humidity[idx] = clampf(0.22 + moisture * 0.58 + reliability * 0.25 + noise * 0.18, 0.0, 1.0)
			_cloud[idx] = clampf(0.16 + moisture * 0.35 + noise * 0.36, 0.0, 1.0)
			_rain[idx] = 0.0
			_wetness[idx] = reliability * 0.22
			_fog[idx] = clampf(_humidity[idx] * 0.3 + _wetness[idx] * 0.2, 0.0, 1.0)
			_orographic[idx] = 0.0
			_rain_shadow[idx] = 0.0
			_activity[idx] = 0.0

	_wind_angle = _hash01(17, 31, seed) * TAU
	_wind_speed = 0.35 + _hash01(41, 53, seed) * 0.45
	_time_accum = 0.0
	_compute_active = false
	if _compute_requested:
		_compute_active = _compute_backend.configure(
			_base_moisture,
			_base_temperature,
			_water_reliability,
			_elevation,
			_slope,
			_cloud,
			_humidity,
			_rain,
			_wetness,
			_fog,
			_orographic,
			_rain_shadow
		)
	return {"ok": true}

func set_emit_rows(enabled: bool) -> void:
	_emit_rows = enabled

func set_compute_enabled(enabled: bool) -> void:
	_compute_requested = enabled
	if not enabled:
		_compute_active = false
		return
	if not _configured:
		return
	_compute_active = _compute_backend.configure(
		_base_moisture,
		_base_temperature,
		_water_reliability,
		_elevation,
		_slope,
		_cloud,
		_humidity,
		_rain,
		_wetness,
		_fog,
		_orographic,
		_rain_shadow
	)

func is_compute_active() -> bool:
	return _compute_active

func benchmark_cpu_vs_compute(iterations: int = 16, delta: float = 0.5) -> Dictionary:
	if not _configured:
		return {"ok": false, "error": "not_configured"}
	var loops = maxi(1, iterations)
	var saved_compute_requested = _compute_requested
	var saved_compute_active = _compute_active
	var saved_emit_rows = _emit_rows
	var saved_wind_angle = _wind_angle
	var saved_wind_speed = _wind_speed
	var saved_time_accum = _time_accum
	var saved_cloud = _cloud.duplicate()
	var saved_humidity = _humidity.duplicate()
	var saved_rain = _rain.duplicate()
	var saved_wetness = _wetness.duplicate()
	var saved_fog = _fog.duplicate()
	var saved_orographic = _orographic.duplicate()
	var saved_shadow = _rain_shadow.duplicate()
	_emit_rows = false
	_compute_requested = false
	_compute_active = false
	var cpu_start_us = Time.get_ticks_usec()
	for i in range(loops):
		step(i + 1, delta)
	var cpu_ms = float(Time.get_ticks_usec() - cpu_start_us) / 1000.0
	_cloud = saved_cloud.duplicate()
	_humidity = saved_humidity.duplicate()
	_rain = saved_rain.duplicate()
	_wetness = saved_wetness.duplicate()
	_fog = saved_fog.duplicate()
	_orographic = saved_orographic.duplicate()
	_rain_shadow = saved_shadow.duplicate()
	_wind_angle = saved_wind_angle
	_wind_speed = saved_wind_speed
	_time_accum = saved_time_accum
	var gpu_ms = -1.0
	var gpu_ok = false
	_compute_requested = true
	_compute_active = _compute_backend.configure(
		_base_moisture,
		_base_temperature,
		_water_reliability,
		_elevation,
		_slope,
		_cloud,
		_humidity,
		_rain,
		_wetness,
		_fog,
		_orographic,
		_rain_shadow
	)
	if _compute_active:
		gpu_ok = true
		var gpu_start_us = Time.get_ticks_usec()
		for i in range(loops):
			step(i + 1, delta)
		gpu_ms = float(Time.get_ticks_usec() - gpu_start_us) / 1000.0
	_cloud = saved_cloud.duplicate()
	_humidity = saved_humidity.duplicate()
	_rain = saved_rain.duplicate()
	_wetness = saved_wetness.duplicate()
	_fog = saved_fog.duplicate()
	_orographic = saved_orographic.duplicate()
	_rain_shadow = saved_shadow.duplicate()
	_wind_angle = saved_wind_angle
	_wind_speed = saved_wind_speed
	_time_accum = saved_time_accum
	_emit_rows = saved_emit_rows
	_compute_requested = saved_compute_requested
	_compute_active = saved_compute_active and _compute_backend.is_configured()
	if _compute_active:
		_compute_backend.upload_dynamic(_cloud, _humidity, _rain, _wetness, _fog, _orographic, _rain_shadow)
	return {
		"ok": true,
		"iterations": loops,
		"cpu_ms_total": cpu_ms,
		"cpu_ms_per_step": cpu_ms / float(loops),
		"gpu_ok": gpu_ok,
		"gpu_ms_total": gpu_ms,
		"gpu_ms_per_step": gpu_ms / float(loops) if gpu_ok and gpu_ms >= 0.0 else -1.0,
	}

func step(tick: int, delta: float, local_activity: Dictionary = {}) -> Dictionary:
	if not _configured:
		return {}
	var n = _width * _height
	var next_time_accum = _time_accum + maxf(0.0, delta)
	var wind_state = _predict_wind(tick, delta, next_time_accum, _wind_angle, _wind_speed)
	var next_wind_angle = float(wind_state.get("angle", _wind_angle))
	var next_wind_speed = clampf(float(wind_state.get("speed", _wind_speed)), 0.05, 2.0)
	var wind = Vector2(cos(next_wind_angle), sin(next_wind_angle))
	var activity_buffer = _build_activity_buffer(local_activity)
	var native_dispatch = NativeComputeBridgeScript.dispatch_environment_stage(
		"weather_step",
		{
			"tick": tick,
			"delta": delta,
			"seed": _seed,
			"width": _width,
			"height": _height,
			"idle_cadence": _idle_cadence,
			"time_accum": next_time_accum,
			"wind_angle": next_wind_angle,
			"wind_speed": next_wind_speed,
			"wind_dir": {"x": wind.x, "y": wind.y},
			"emit_rows": _emit_rows,
			"local_activity": local_activity, "physics_contacts": local_activity.get("physics_contacts", []),
			"buffers": {
				"base_moisture": _base_moisture,
				"base_temperature": _base_temperature,
				"water_reliability": _water_reliability,
				"elevation": _elevation,
				"slope": _slope,
				"cloud": _cloud,
				"humidity": _humidity,
				"rain": _rain,
				"wetness": _wetness,
				"fog": _fog,
				"orographic": _orographic,
				"rain_shadow": _rain_shadow,
				"activity": activity_buffer,
			},
		}
	)
	var native_dispatched = NativeComputeBridgeScript.is_environment_stage_dispatched(native_dispatch)
	if native_dispatched:
		var native_fields: Dictionary = NativeComputeBridgeScript.environment_stage_result(native_dispatch)
		var native_cloud: PackedFloat32Array = native_fields.get("cloud", PackedFloat32Array())
		var native_humidity: PackedFloat32Array = native_fields.get("humidity", PackedFloat32Array())
		var native_rain: PackedFloat32Array = native_fields.get("rain", PackedFloat32Array())
		var native_wetness: PackedFloat32Array = native_fields.get("wetness", PackedFloat32Array())
		var native_fog: PackedFloat32Array = native_fields.get("fog", PackedFloat32Array())
		var native_orographic: PackedFloat32Array = native_fields.get("orographic", PackedFloat32Array())
		var native_shadow: PackedFloat32Array = native_fields.get("rain_shadow", PackedFloat32Array())
		if native_cloud.size() != n or native_humidity.size() != n or native_rain.size() != n or native_wetness.size() != n or native_fog.size() != n or native_orographic.size() != n or native_shadow.size() != n:
			return _fail_fast_weather_snapshot(tick, "native_weather_result_invalid", "native weather stage returned invalid buffer sizes")
		_cloud = native_cloud
		_humidity = native_humidity
		_rain = native_rain
		_wetness = native_wetness
		_fog = native_fog
		_orographic = native_orographic
		_rain_shadow = native_shadow
		var native_wind = native_fields.get("wind_dir", {})
		if native_wind is Dictionary:
			var wx = float((native_wind as Dictionary).get("x", wind.x))
			var wy = float((native_wind as Dictionary).get("y", wind.y))
			if absf(wx) > 0.0001 or absf(wy) > 0.0001:
				wind = Vector2(wx, wy).normalized()
				next_wind_angle = wind.angle()
		next_wind_speed = clampf(float(native_fields.get("wind_speed", next_wind_speed)), 0.05, 2.0)
		_activity = activity_buffer
		_time_accum = next_time_accum
		_wind_angle = next_wind_angle
		_wind_speed = next_wind_speed
		return current_snapshot(tick)
	if _compute_active:
		var gpu_result = _compute_backend.step(delta, next_wind_speed, activity_buffer, tick, _idle_cadence, _hash01(tick, _seed & 1023, _seed))
		if not gpu_result.is_empty():
			var gpu_cloud: PackedFloat32Array = gpu_result.get("cloud", PackedFloat32Array())
			var gpu_humidity: PackedFloat32Array = gpu_result.get("humidity", PackedFloat32Array())
			var gpu_rain: PackedFloat32Array = gpu_result.get("rain", PackedFloat32Array())
			var gpu_wetness: PackedFloat32Array = gpu_result.get("wetness", PackedFloat32Array())
			var gpu_fog: PackedFloat32Array = gpu_result.get("fog", PackedFloat32Array())
			var gpu_orographic: PackedFloat32Array = gpu_result.get("orographic", PackedFloat32Array())
			var gpu_shadow: PackedFloat32Array = gpu_result.get("rain_shadow", PackedFloat32Array())
			if gpu_cloud.size() != n or gpu_humidity.size() != n or gpu_rain.size() != n or gpu_wetness.size() != n or gpu_fog.size() != n or gpu_orographic.size() != n or gpu_shadow.size() != n:
				return _fail_fast_weather_snapshot(tick, "weather_gpu_result_invalid", "weather GPU step returned invalid buffer sizes")
			_cloud = gpu_cloud
			_humidity = gpu_humidity
			_rain = gpu_rain
			_wetness = gpu_wetness
			_fog = gpu_fog
			_orographic = gpu_orographic
			_rain_shadow = gpu_shadow
			_activity = activity_buffer
			_time_accum = next_time_accum
			_wind_angle = next_wind_angle
			_wind_speed = next_wind_speed
			var sum_cloud_gpu = 0.0
			var sum_humidity_gpu = 0.0
			var sum_rain_gpu = 0.0
			var sum_fog_gpu = 0.0
			for i in range(n):
				sum_cloud_gpu += float(_cloud[i])
				sum_humidity_gpu += float(_humidity[i])
				sum_rain_gpu += float(_rain[i])
				sum_fog_gpu += float(_fog[i])
			var inv_gpu = 1.0 / float(maxi(1, n))
			return _snapshot_dict(
				tick,
				wind,
				{
					"cloud": sum_cloud_gpu * inv_gpu,
					"humidity": sum_humidity_gpu * inv_gpu,
					"rain": sum_rain_gpu * inv_gpu,
					"fog": sum_fog_gpu * inv_gpu,
				}
			)
		return _fail_fast_weather_snapshot(tick, "weather_gpu_step_failed", "weather GPU step unavailable or returned empty result")
	var native_error = String(native_dispatch.get("error", "")).strip_edges()
	if native_error == "":
		var native_result_variant = native_dispatch.get("result", {})
		if native_result_variant is Dictionary:
			native_error = String((native_result_variant as Dictionary).get("error", "")).strip_edges()
	var native_details = "native weather dispatch unavailable and GPU compute inactive"
	if native_error != "":
		native_details = "%s (%s)" % [native_details, native_error]
	return _fail_fast_weather_snapshot(tick, "weather_native_and_gpu_unavailable", native_details)

func current_snapshot(tick: int = 0) -> Dictionary:
	if not _configured:
		return {}
	var wind = Vector2(cos(_wind_angle), sin(_wind_angle))
	var n = _width * _height
	var sum_cloud = 0.0
	var sum_humidity = 0.0
	var sum_rain = 0.0
	var sum_fog = 0.0
	for i in range(n):
		sum_cloud += float(_cloud[i])
		sum_humidity += float(_humidity[i])
		sum_rain += float(_rain[i])
		sum_fog += float(_fog[i])
	var inv_n = 1.0 / float(maxi(1, n))
	return _snapshot_dict(
		tick,
		wind,
		{
			"cloud": sum_cloud * inv_n,
			"humidity": sum_humidity * inv_n,
			"rain": sum_rain * inv_n,
			"fog": sum_fog * inv_n,
		}
	)

func import_snapshot(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	var buffers: Dictionary = snapshot.get("buffers", {})
	if not buffers.is_empty():
		var expected = _width * _height
		var buf_cloud: PackedFloat32Array = buffers.get("cloud", PackedFloat32Array())
		var buf_humidity: PackedFloat32Array = buffers.get("humidity", PackedFloat32Array())
		var buf_rain: PackedFloat32Array = buffers.get("rain", PackedFloat32Array())
		var buf_wetness: PackedFloat32Array = buffers.get("wetness", PackedFloat32Array())
		var buf_fog: PackedFloat32Array = buffers.get("fog", PackedFloat32Array())
		var buf_orographic: PackedFloat32Array = buffers.get("orographic", PackedFloat32Array())
		var buf_shadow: PackedFloat32Array = buffers.get("rain_shadow", PackedFloat32Array())
		if buf_cloud.size() == expected and buf_humidity.size() == expected and buf_rain.size() == expected and buf_wetness.size() == expected and buf_fog.size() == expected:
			_cloud = buf_cloud
			_humidity = buf_humidity
			_rain = buf_rain
			_wetness = buf_wetness
			_fog = buf_fog
			if buf_orographic.size() == expected:
				_orographic = buf_orographic
			if buf_shadow.size() == expected:
				_rain_shadow = buf_shadow
			var wind_dir_fast: Dictionary = snapshot.get("wind_dir", {})
			var wx_fast = float(wind_dir_fast.get("x", cos(_wind_angle)))
			var wy_fast = float(wind_dir_fast.get("y", sin(_wind_angle)))
			if absf(wx_fast) > 0.0001 or absf(wy_fast) > 0.0001:
				_wind_angle = Vector2(wx_fast, wy_fast).angle()
			_wind_speed = clampf(float(snapshot.get("wind_speed", _wind_speed)), 0.05, 2.0)
			if _compute_active:
				_compute_backend.upload_dynamic(_cloud, _humidity, _rain, _wetness, _fog, _orographic, _rain_shadow)
			return
	var rows: Array = snapshot.get("rows", [])
	if rows.is_empty():
		return
	for row_variant in rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var x = int(row.get("x", 0))
		var y = int(row.get("y", 0))
		if x < 0 or x >= _width or y < 0 or y >= _height:
			continue
		var idx = _i(x, y)
		_cloud[idx] = clampf(float(row.get("cloud", _cloud[idx])), 0.0, 1.0)
		_humidity[idx] = clampf(float(row.get("humidity", _humidity[idx])), 0.0, 1.0)
		_rain[idx] = clampf(float(row.get("rain", _rain[idx])), 0.0, 1.0)
		_wetness[idx] = clampf(float(row.get("wetness", _wetness[idx])), 0.0, 1.0)
		_fog[idx] = clampf(float(row.get("fog", _fog[idx])), 0.0, 1.0)
		_orographic[idx] = clampf(float(row.get("orographic", _orographic[idx])), 0.0, 1.0)
		_rain_shadow[idx] = clampf(float(row.get("rain_shadow", _rain_shadow[idx])), 0.0, 1.0)
	var wind_dir: Dictionary = snapshot.get("wind_dir", {})
	var wx = float(wind_dir.get("x", cos(_wind_angle)))
	var wy = float(wind_dir.get("y", sin(_wind_angle)))
	if absf(wx) > 0.0001 or absf(wy) > 0.0001:
		_wind_angle = Vector2(wx, wy).angle()
	_wind_speed = clampf(float(snapshot.get("wind_speed", _wind_speed)), 0.05, 2.0)
	if _compute_active:
		_compute_backend.upload_dynamic(_cloud, _humidity, _rain, _wetness, _fog, _orographic, _rain_shadow)

func _snapshot_dict(tick: int, wind: Vector2, averages: Dictionary) -> Dictionary:
	var rows: Array = []
	var tile_index: Dictionary = {}
	if _emit_rows:
		for y in range(_height):
			for x in range(_width):
				var idx = _i(x, y)
				var tile_id = TileKeyUtilsScript.tile_id(x, y)
				var row = {
					"tile_id": tile_id,
					"x": x,
					"y": y,
					"cloud": float(_cloud[idx]),
					"humidity": float(_humidity[idx]),
					"rain": float(_rain[idx]),
					"wetness": float(_wetness[idx]),
					"fog": float(_fog[idx]),
					"orographic": float(_orographic[idx]),
					"rain_shadow": float(_rain_shadow[idx]),
				}
				rows.append(row)
				tile_index[tile_id] = row
	var out = {
		"schema_version": 1,
		"tick": tick,
		"width": _width,
		"height": _height,
		"wind_dir": {"x": wind.x, "y": wind.y},
		"wind_speed": _wind_speed,
		"avg_cloud_cover": float(averages.get("cloud", 0.0)),
		"avg_humidity": float(averages.get("humidity", 0.0)),
		"avg_rain_intensity": float(averages.get("rain", 0.0)),
		"avg_fog_intensity": float(averages.get("fog", 0.0)),
		"rows": rows,
		"tile_index": tile_index,
	}
	if not _emit_rows:
		out["buffers"] = {
			"cloud": _cloud,
			"humidity": _humidity,
			"rain": _rain,
			"wetness": _wetness,
			"fog": _fog,
			"orographic": _orographic,
			"rain_shadow": _rain_shadow,
		}
	return out

func _predict_wind(tick: int, delta: float, time_accum: float, start_angle: float, start_speed: float) -> Dictionary:
	var t = float(tick) * 0.041 + time_accum * 0.09 + float(_seed % 997) * 0.001
	var drift = sin(t * 0.83) * 0.018 + cos(t * 0.57) * 0.014
	var next_angle = fposmod(start_angle + drift * maxf(0.2, delta), TAU)
	var next_speed = clampf(0.25 + 0.4 * (0.5 + 0.5 * sin(t * 0.61)), 0.12, 1.2)
	return {"angle": next_angle, "speed": clampf(next_speed, 0.05, 2.0), "previous_speed": start_speed}

func _sample_bilinear(values: PackedFloat32Array, x: float, y: float) -> float:
	var x0 = int(floor(x))
	var y0 = int(floor(y))
	var x1 = x0 + 1
	var y1 = y0 + 1
	var fx = x - float(x0)
	var fy = y - float(y0)
	var v00 = values[_i_clamped(x0, y0)]
	var v10 = values[_i_clamped(x1, y0)]
	var v01 = values[_i_clamped(x0, y1)]
	var v11 = values[_i_clamped(x1, y1)]
	var a = lerpf(v00, v10, fx)
	var b = lerpf(v01, v11, fx)
	return lerpf(a, b, fy)

func _i(x: int, y: int) -> int:
	return y * _width + x

func _i_clamped(x: int, y: int) -> int:
	var cx = clampi(x, 0, _width - 1)
	var cy = clampi(y, 0, _height - 1)
	return _i(cx, cy)

func _hash01(x: int, y: int, seed: int) -> float:
	var h = hash("%d|%d|%d" % [x, y, seed])
	var n = abs(int(h) % 1000000)
	return float(n) / 1000000.0

func _write_activity_buffer(local_activity: Dictionary) -> void:
	_activity = _build_activity_buffer(local_activity)

func _build_activity_buffer(local_activity: Dictionary) -> PackedFloat32Array:
	var activity := PackedFloat32Array()
	activity.resize(_width * _height)
	activity.fill(0.0)
	if local_activity.is_empty():
		return activity
	for tile_id_variant in local_activity.keys():
		var tile_id = String(tile_id_variant)
		var coords = TileKeyUtilsScript.parse_tile_id(tile_id)
		if coords.x == 2147483647:
			continue
		var x = coords.x
		var y = coords.y
		if x < 0 or x >= _width or y < 0 or y >= _height:
			continue
		activity[_i(x, y)] = clampf(float(local_activity.get(tile_id, 0.0)), 0.0, 1.0)
	return activity

func _fail_fast_weather_snapshot(tick: int, error_code: String, details: String = "") -> Dictionary:
	var snapshot = current_snapshot(tick)
	snapshot["status"] = "error"
	snapshot["error"] = error_code
	if details != "":
		snapshot["details"] = details
	return snapshot
