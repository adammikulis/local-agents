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
	_time_accum += maxf(0.0, delta)
	var n = _width * _height
	var next_cloud := PackedFloat32Array()
	var next_humidity := PackedFloat32Array()
	var next_rain := PackedFloat32Array()
	var next_wetness := PackedFloat32Array()
	var next_fog := PackedFloat32Array()
	var next_orographic := PackedFloat32Array()
	var next_shadow := PackedFloat32Array()
	next_cloud.resize(n)
	next_humidity.resize(n)
	next_rain.resize(n)
	next_wetness.resize(n)
	next_fog.resize(n)
	next_orographic.resize(n)
	next_shadow.resize(n)

	_update_wind(tick, delta)
	var wind = Vector2(cos(_wind_angle), sin(_wind_angle))
	_write_activity_buffer(local_activity)
	var native_dispatch = NativeComputeBridgeScript.dispatch_environment_stage(
		"weather_step",
		{
			"tick": tick,
			"delta": delta,
			"seed": _seed,
			"width": _width,
			"height": _height,
			"idle_cadence": _idle_cadence,
			"time_accum": _time_accum,
			"wind_angle": _wind_angle,
			"wind_speed": _wind_speed,
			"wind_dir": {"x": wind.x, "y": wind.y},
			"emit_rows": _emit_rows,
			"local_activity": local_activity,
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
				"activity": _activity,
			},
		}
	)
	if bool(native_dispatch.get("dispatched", false)):
		var native_fields: Dictionary = native_dispatch.get("result_fields", {})
		var native_cloud: PackedFloat32Array = native_fields.get("cloud", PackedFloat32Array())
		var native_humidity: PackedFloat32Array = native_fields.get("humidity", PackedFloat32Array())
		var native_rain: PackedFloat32Array = native_fields.get("rain", PackedFloat32Array())
		var native_wetness: PackedFloat32Array = native_fields.get("wetness", PackedFloat32Array())
		var native_fog: PackedFloat32Array = native_fields.get("fog", PackedFloat32Array())
		var native_orographic: PackedFloat32Array = native_fields.get("orographic", PackedFloat32Array())
		var native_shadow: PackedFloat32Array = native_fields.get("rain_shadow", PackedFloat32Array())
		if native_cloud.size() == n and native_humidity.size() == n and native_rain.size() == n and native_wetness.size() == n and native_fog.size() == n and native_orographic.size() == n and native_shadow.size() == n:
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
					_wind_angle = wind.angle()
			_wind_speed = clampf(float(native_fields.get("wind_speed", _wind_speed)), 0.05, 2.0)
			return current_snapshot(tick)
	if _compute_active:
		var gpu_result = _compute_backend.step(delta, _wind_speed, _activity, tick, _idle_cadence, _hash01(tick, _seed & 1023, _seed))
		if not gpu_result.is_empty():
			_cloud = gpu_result.get("cloud", _cloud)
			_humidity = gpu_result.get("humidity", _humidity)
			_rain = gpu_result.get("rain", _rain)
			_wetness = gpu_result.get("wetness", _wetness)
			_fog = gpu_result.get("fog", _fog)
			_orographic = gpu_result.get("orographic", _orographic)
			_rain_shadow = gpu_result.get("rain_shadow", _rain_shadow)
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
	var advection = _wind_speed * 0.85

	var sum_cloud = 0.0
	var sum_humidity = 0.0
	var sum_rain = 0.0
	var sum_fog = 0.0

	for y in range(_height):
		for x in range(_width):
			var idx = _i(x, y)
			var cadence = CadencePolicyScript.cadence_for_activity(float(_activity[idx]), _idle_cadence)
			if cadence > 1 and not CadencePolicyScript.should_step_with_key(str(idx), tick, cadence, _seed):
				next_cloud[idx] = _cloud[idx]
				next_humidity[idx] = _humidity[idx]
				next_rain[idx] = _rain[idx]
				next_wetness[idx] = _wetness[idx]
				next_fog[idx] = _fog[idx]
				next_orographic[idx] = _orographic[idx]
				next_shadow[idx] = _rain_shadow[idx]
				sum_cloud += float(next_cloud[idx])
				sum_humidity += float(next_humidity[idx])
				sum_rain += float(next_rain[idx])
				sum_fog += float(next_fog[idx])
				continue
			var local_step_scale = maxf(1.0, float(cadence))
			var sx = float(x) - wind.x * advection
			var sy = float(y) - wind.y * advection
			var adv_cloud = _sample_bilinear(_cloud, sx, sy)
			var adv_humidity = _sample_bilinear(_humidity, sx, sy)
			var adv_wetness = _sample_bilinear(_wetness, sx, sy)

			var upx = int(round(float(x) - wind.x))
			var upy = int(round(float(y) - wind.y))
			var up_idx = _i_clamped(upx, upy)
			var elev_here = float(_elevation[idx])
			var elev_upwind = float(_elevation[up_idx])
			var elev_delta = elev_here - elev_upwind
			var uplift = maxf(0.0, elev_delta * 2.8 + float(_slope[idx]) * 0.35)
			var lee = maxf(0.0, -elev_delta * 2.2)
			var shadow = clampf(lee * (0.45 + _wind_speed * 0.35), 0.0, 1.0)

			var base_temp = float(_base_temperature[idx])
			var cool_air = maxf(0.0, 0.55 - base_temp)
			var moisture_source = 0.012 + float(_base_moisture[idx]) * 0.028 + float(_water_reliability[idx]) * 0.04
			var evaporation = clampf((0.008 + base_temp * 0.025 + (1.0 - adv_wetness) * 0.02) * local_step_scale, 0.003, 0.12)
			var condensation_threshold = 0.44 - cool_air * 0.18 - uplift * 0.08
			var condensation = maxf(0.0, adv_cloud * adv_humidity * (0.68 + uplift * 0.95) - condensation_threshold) * local_step_scale
			var rain = clampf(condensation * (1.05 + cool_air * 0.25), 0.0, 1.0)
			rain *= (1.0 - shadow * 0.72)
			var humidity = clampf(adv_humidity + moisture_source + evaporation - rain * 0.19, 0.0, 1.0)
			var cloud = clampf(adv_cloud + humidity * 0.06 + uplift * 0.04 - rain * 0.16 - (0.01 + _wind_speed * 0.015), 0.0, 1.0)
			var wetness = clampf(adv_wetness * 0.95 + rain * 0.52, 0.0, 1.0)
			var fog = clampf(humidity * 0.52 + wetness * 0.38 + cool_air * 0.22 - _wind_speed * 0.24, 0.0, 1.0)

			next_cloud[idx] = cloud
			next_humidity[idx] = humidity
			next_rain[idx] = rain
			next_wetness[idx] = wetness
			next_fog[idx] = fog
			next_orographic[idx] = clampf(uplift, 0.0, 1.0)
			next_shadow[idx] = shadow

			sum_cloud += cloud
			sum_humidity += humidity
			sum_rain += rain
			sum_fog += fog

	_cloud = next_cloud
	_humidity = next_humidity
	_rain = next_rain
	_wetness = next_wetness
	_fog = next_fog
	_orographic = next_orographic
	_rain_shadow = next_shadow

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

func _update_wind(tick: int, delta: float) -> void:
	var t = float(tick) * 0.041 + _time_accum * 0.09 + float(_seed % 997) * 0.001
	var drift = sin(t * 0.83) * 0.018 + cos(t * 0.57) * 0.014
	_wind_angle = fposmod(_wind_angle + drift * maxf(0.2, delta), TAU)
	_wind_speed = clampf(0.25 + 0.4 * (0.5 + 0.5 * sin(t * 0.61)), 0.12, 1.2)

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
	if _activity.size() != _width * _height:
		_activity.resize(_width * _height)
	_activity.fill(0.0)
	if local_activity.is_empty():
		return
	for tile_id_variant in local_activity.keys():
		var tile_id = String(tile_id_variant)
		var coords = TileKeyUtilsScript.parse_tile_id(tile_id)
		if coords.x == 2147483647:
			continue
		var x = coords.x
		var y = coords.y
		if x < 0 or x >= _width or y < 0 or y >= _height:
			continue
		_activity[_i(x, y)] = clampf(float(local_activity.get(tile_id, 0.0)), 0.0, 1.0)
