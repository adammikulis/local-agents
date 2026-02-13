extends RefCounted
class_name LocalAgentsSolarExposureSystem

const TileKeyUtilsScript = preload("res://addons/local_agents/simulation/TileKeyUtils.gd")
const SolarComputeBackendScript = preload("res://addons/local_agents/simulation/SolarComputeBackend.gd")
const CadencePolicyScript = preload("res://addons/local_agents/simulation/CadencePolicy.gd")
const NativeComputeBridgeScript = preload("res://addons/local_agents/simulation/controller/NativeComputeBridge.gd")
var _configured: bool = false
var _emit_rows: bool = true
var _seed: int = 0
var _width: int = 0
var _height: int = 0
var _surface_y: Dictionary = {}
var _surface_block: Dictionary = {}
var _surface_albedo: Dictionary = {}
var _shade_static: Dictionary = {}
var _daily_sun: Dictionary = {}
var _daily_uv: Dictionary = {}
var _cumulative_sun: Dictionary = {}
var _cumulative_uv: Dictionary = {}
var _last_snapshot: Dictionary = {}
var _ordered_tile_ids: Array[String] = []
var _ordered_flat_indices := PackedInt32Array()
var _aspect_gradient: Dictionary = {}
var _activity_buffer := PackedFloat32Array()
var _sunlight_buffer := PackedFloat32Array()
var _uv_buffer := PackedFloat32Array()
var _heat_buffer := PackedFloat32Array()
var _growth_buffer := PackedFloat32Array()
var _idle_cadence: int = 8
var _sync_stride: int = 1
var _compute_requested: bool = false
var _compute_active: bool = false
var _compute_backend = SolarComputeBackendScript.new()

func configure_environment(environment_snapshot: Dictionary, seed: int) -> Dictionary:
	_seed = seed
	_width = int(environment_snapshot.get("width", 0))
	_height = int(environment_snapshot.get("height", 0))
	_configured = _width > 0 and _height > 0
	if not _configured:
		return {"ok": false, "error": "invalid_dimensions"}
	_surface_y.clear()
	_surface_block.clear()
	_surface_albedo.clear()
	_shade_static.clear()
	_daily_sun.clear()
	_daily_uv.clear()
	_cumulative_sun.clear()
	_cumulative_uv.clear()
	_last_snapshot = {}
	_ordered_tile_ids.clear()
	_ordered_flat_indices = PackedInt32Array()
	_aspect_gradient.clear()

	var voxel_world: Dictionary = environment_snapshot.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	for col_variant in columns:
		if not (col_variant is Dictionary):
			continue
		var col = col_variant as Dictionary
		var tile_id = TileKeyUtilsScript.tile_id(int(col.get("x", 0)), int(col.get("z", 0)))
		_surface_y[tile_id] = int(col.get("surface_y", 0))
		var top_block = String(col.get("top_block", "grass"))
		_surface_block[tile_id] = top_block
		var rgba = col.get("top_block_rgba", [0.5, 0.5, 0.5, 1.0])
		_surface_albedo[tile_id] = _albedo_from_rgba(rgba)
	var tile_index: Dictionary = environment_snapshot.get("tile_index", {})
	var ids = tile_index.keys()
	ids.sort_custom(func(a, b): return String(a) < String(b))
	_ordered_flat_indices.resize(ids.size())
	_activity_buffer.resize(ids.size())
	_sunlight_buffer.resize(ids.size())
	_uv_buffer.resize(ids.size())
	_heat_buffer.resize(ids.size())
	_growth_buffer.resize(ids.size())
	for i in range(ids.size()):
		var tile_id_variant = ids[i]
		var tile_id = String(tile_id_variant)
		_ordered_tile_ids.append(tile_id)
		_shade_static[tile_id] = _static_shade_for(tile_id)
		_aspect_gradient[tile_id] = _build_aspect_gradient(tile_id)
		_daily_sun[tile_id] = 0.0
		_daily_uv[tile_id] = 0.0
		_cumulative_sun[tile_id] = 0.0
		_cumulative_uv[tile_id] = 0.0
		_activity_buffer[i] = 0.0
		_sunlight_buffer[i] = 0.0
		_uv_buffer[i] = 0.0
		_heat_buffer[i] = 0.0
		_growth_buffer[i] = 0.0
		var tile_row = tile_index.get(tile_id, {})
		if tile_row is Dictionary:
			var row = tile_row as Dictionary
			var x = int(row.get("x", 0))
			var y = int(row.get("y", 0))
			_ordered_flat_indices[i] = clampi(y, 0, maxi(0, _height - 1)) * _width + clampi(x, 0, maxi(0, _width - 1))
		else:
			_ordered_flat_indices[i] = 0
	_last_snapshot = _build_snapshot(0, [], {})
	_compute_active = false
	if _compute_requested:
		_compute_active = _configure_compute_backend(environment_snapshot)
	return {"ok": true}

func set_emit_rows(enabled: bool) -> void:
	_emit_rows = enabled

func set_sync_stride(stride: int) -> void:
	_sync_stride = maxi(1, stride)

func set_compute_enabled(enabled: bool) -> void:
	_compute_requested = enabled
	if not enabled:
		_compute_active = false
		return
	if not _configured:
		return
	_compute_active = _configure_compute_backend({})

func is_compute_active() -> bool:
	return _compute_active

func step(tick: int, delta: float, environment_snapshot: Dictionary, weather_snapshot: Dictionary, local_activity: Dictionary = {}) -> Dictionary:
	if not _configured:
		return {}
	if tick > 0 and tick % 24 == 0:
		for tile_id in _ordered_tile_ids:
			_daily_sun[tile_id] = 0.0
			_daily_uv[tile_id] = 0.0

	var tile_index: Dictionary = environment_snapshot.get("tile_index", {})
	if tile_index.is_empty():
		return _last_snapshot.duplicate(true)
	var weather_tiles: Dictionary = weather_snapshot.get("tile_index", {})
	var weather_buffers: Dictionary = weather_snapshot.get("buffers", {})
	var weather_cloud: PackedFloat32Array = weather_buffers.get("cloud", PackedFloat32Array())
	var weather_fog: PackedFloat32Array = weather_buffers.get("fog", PackedFloat32Array())
	var weather_humidity: PackedFloat32Array = weather_buffers.get("humidity", PackedFloat32Array())
	var weather_buffer_ok = weather_cloud.size() == _width * _height and weather_fog.size() == _width * _height and weather_humidity.size() == _width * _height
	var tod = fposmod(float(tick), 24.0) / 24.0
	var sun_alt = maxf(0.0, sin((tod - 0.25) * TAU))
	var sun_dir = Vector2(cos((tod - 0.25) * TAU), sin((tod - 0.25) * TAU))
	var use_compute = false
	var use_compute_backend = _compute_active and weather_buffer_ok
	_write_activity_buffer(local_activity)
	var solar_rows: Array = []
	var solar_index: Dictionary = {}
	var sync_spatial = _emit_rows or (tick % _sync_stride == 0)
	var sum_insolation = 0.0
	var sum_uv = 0.0
	var sum_heat = 0.0
	var sum_growth = 0.0
	var sample_count = 0
	var packed_sunlight := PackedFloat32Array()
	var packed_uv := PackedFloat32Array()
	var packed_heat := PackedFloat32Array()
	var packed_growth := PackedFloat32Array()
	if not _emit_rows:
		var count = _ordered_tile_ids.size()
		packed_sunlight.resize(count)
		packed_uv.resize(count)
		packed_heat.resize(count)
		packed_growth.resize(count)
	var native_payload := {
		"tick": tick, "delta": delta, "seed": _seed, "width": _width, "height": _height, "idle_cadence": _idle_cadence, "emit_rows": _emit_rows,
		"sun_altitude": sun_alt, "sun_dir": {"x": sun_dir.x, "y": sun_dir.y}, "ordered_flat_indices": _ordered_flat_indices, "local_activity": local_activity, "weather_snapshot": weather_snapshot,
		"buffers": {"activity": _activity_buffer, "weather_cloud": weather_cloud, "weather_fog": weather_fog, "weather_humidity": weather_humidity, "sunlight_total": _sunlight_buffer, "uv_index": _uv_buffer, "heat_load": _heat_buffer, "plant_growth_factor": _growth_buffer},
	}
	var native_dispatch = NativeComputeBridgeScript.dispatch_environment_stage("solar_exposure_step", native_payload)
	if bool(native_dispatch.get("dispatched", false)):
		var native_fields: Dictionary = native_dispatch.get("result_fields", {})
		var native_sun: PackedFloat32Array = native_fields.get("sunlight_total", PackedFloat32Array())
		var native_uv: PackedFloat32Array = native_fields.get("uv_index", PackedFloat32Array())
		var native_heat: PackedFloat32Array = native_fields.get("heat_load", PackedFloat32Array())
		var native_growth: PackedFloat32Array = native_fields.get("plant_growth_factor", PackedFloat32Array())
		if native_sun.size() == _ordered_tile_ids.size() and native_uv.size() == _ordered_tile_ids.size() and native_heat.size() == _ordered_tile_ids.size() and native_growth.size() == _ordered_tile_ids.size():
			packed_sunlight = native_sun
			packed_uv = native_uv
			packed_heat = native_heat
			packed_growth = native_growth
			use_compute = true
	if use_compute_backend and not use_compute:
		var gpu = _compute_backend.step(weather_cloud, weather_fog, weather_humidity, _activity_buffer, sun_dir, sun_alt, tick, _idle_cadence, _seed)
		if not gpu.is_empty():
			packed_sunlight = gpu.get("sunlight_total", packed_sunlight)
			packed_uv = gpu.get("uv_index", packed_uv)
			packed_heat = gpu.get("heat_load", packed_heat)
			packed_growth = gpu.get("plant_growth_factor", packed_growth)
			use_compute = true

	for i in range(_ordered_tile_ids.size()):
		var tile_id = _ordered_tile_ids[i]
		var tile_row = tile_index.get(tile_id, {})
		if not (tile_row is Dictionary):
			continue
		var tile = tile_row as Dictionary
		var cloud = 0.0
		var fog = 0.0
		var humidity = 0.0
		if weather_buffer_ok and i < _ordered_flat_indices.size():
			var flat = clampi(_ordered_flat_indices[i], 0, weather_cloud.size() - 1)
			cloud = clampf(float(weather_cloud[flat]), 0.0, 1.0)
			fog = clampf(float(weather_fog[flat]), 0.0, 1.0)
			humidity = clampf(float(weather_humidity[flat]), 0.0, 1.0)
		else:
			var weather_row = weather_tiles.get(tile_id, {})
			cloud = clampf(float((weather_row as Dictionary).get("cloud", weather_snapshot.get("avg_cloud_cover", 0.0)) if weather_row is Dictionary else weather_snapshot.get("avg_cloud_cover", 0.0)), 0.0, 1.0)
			fog = clampf(float((weather_row as Dictionary).get("fog", weather_snapshot.get("avg_fog_intensity", 0.0)) if weather_row is Dictionary else weather_snapshot.get("avg_fog_intensity", 0.0)), 0.0, 1.0)
			humidity = clampf(float((weather_row as Dictionary).get("humidity", weather_snapshot.get("avg_humidity", 0.0)) if weather_row is Dictionary else weather_snapshot.get("avg_humidity", 0.0)), 0.0, 1.0)
		var moisture = clampf(float(tile.get("moisture", 0.5)), 0.0, 1.0)
		var albedo = clampf(float(_surface_albedo.get(tile_id, 0.35)), 0.02, 0.9)
		var shade = clampf(float(_shade_static.get(tile_id, 0.0)), 0.0, 1.0)
		var direct = 0.0
		var diffuse = 0.0
		var insolation = 0.0
		var uv_index = 0.0
		var heat_load = 0.0
		var plant_growth_factor = 0.0
		var cadence = CadencePolicyScript.cadence_for_activity(float(_activity_buffer[i]) if i < _activity_buffer.size() else 0.0, _idle_cadence)
		var step_key = _ordered_tile_ids[i] if i >= 0 and i < _ordered_tile_ids.size() else str(i)
		var should_step = CadencePolicyScript.should_step_with_key(step_key, tick, cadence, _seed)
		var local_delta = delta * float(cadence) if should_step else 0.0
		if use_compute and i < packed_sunlight.size():
			insolation = clampf(float(packed_sunlight[i]), 0.0, 1.0)
			uv_index = clampf(float(packed_uv[i]), 0.0, 2.0)
			heat_load = clampf(float(packed_heat[i]), 0.0, 1.5)
			plant_growth_factor = clampf(float(packed_growth[i]), 0.0, 1.0)
			direct = clampf(insolation * maxf(0.25, 1.0 - cloud * 0.4), 0.0, 1.0)
			diffuse = clampf(insolation - direct, 0.0, 1.0)
		else:
			if not should_step and i < _sunlight_buffer.size():
				insolation = clampf(float(_sunlight_buffer[i]), 0.0, 1.0)
				uv_index = clampf(float(_uv_buffer[i]), 0.0, 2.0)
				heat_load = clampf(float(_heat_buffer[i]), 0.0, 1.5)
				plant_growth_factor = clampf(float(_growth_buffer[i]), 0.0, 1.0)
				direct = clampf(insolation * maxf(0.25, 1.0 - cloud * 0.4), 0.0, 1.0)
				diffuse = clampf(insolation - direct, 0.0, 1.0)
			else:
				var temperature = clampf(float(tile.get("temperature", 0.5)), 0.0, 1.0)
				var elevation = clampf(float(tile.get("elevation", 0.5)), 0.0, 1.0)
				var aspect_grad = _aspect_gradient.get(tile_id, Vector2.ZERO)
				var aspect_factor = 1.0
				if aspect_grad is Vector2:
					var grad = (aspect_grad as Vector2)
					if grad.length_squared() > 0.0001:
						var downhill = (-grad).normalized()
						var facing = clampf(downhill.dot(sun_dir.normalized()), -1.0, 1.0)
						aspect_factor = clampf(0.62 + 0.38 * (facing * 0.5 + 0.5), 0.3, 1.0)
				var cloud_atten = (1.0 - cloud * 0.72)
				var fog_atten = (1.0 - fog * 0.45)
				direct = sun_alt * cloud_atten * fog_atten * (1.0 - shade * 0.75) * aspect_factor
				diffuse = (0.18 + cloud * 0.5) * (1.0 - fog * 0.35)
				insolation = clampf(direct + diffuse * 0.5, 0.0, 1.0)
				uv_index = clampf((direct * 1.1 + (1.0 - cloud) * 0.25) * (0.65 + elevation * 0.7) * (0.75 + sun_alt * 0.5), 0.0, 2.0)
				var absorbed_cpu = insolation * (1.0 - albedo)
				heat_load = clampf(absorbed_cpu * (0.78 + (1.0 - cloud) * 0.26) + uv_index * 0.15 - moisture * 0.08, 0.0, 1.5)
				var temp_optimal = 1.0 - clampf(absf(temperature - 0.56) * 1.2, 0.0, 1.0)
				var uv_stress = clampf(maxf(0.0, uv_index - 1.15) * 0.45, 0.0, 1.0)
				plant_growth_factor = clampf((absorbed_cpu * 0.7 + insolation * 0.3) * (0.35 + moisture * 0.65) * temp_optimal * (1.0 - uv_stress), 0.0, 1.0)
		if i < _sunlight_buffer.size():
			_sunlight_buffer[i] = insolation
			_uv_buffer[i] = uv_index
			_heat_buffer[i] = heat_load
			_growth_buffer[i] = plant_growth_factor
		var reflected_solar = insolation * albedo
		var absorbed_solar = insolation * (1.0 - albedo)

		var daily_sun = float(_daily_sun.get(tile_id, 0.0)) + absorbed_solar * local_delta
		var daily_uv = float(_daily_uv.get(tile_id, 0.0)) + uv_index * local_delta
		var total_sun = float(_cumulative_sun.get(tile_id, 0.0)) + absorbed_solar * local_delta
		var total_uv = float(_cumulative_uv.get(tile_id, 0.0)) + uv_index * local_delta
		_daily_sun[tile_id] = daily_sun
		_daily_uv[tile_id] = daily_uv
		_cumulative_sun[tile_id] = total_sun
		_cumulative_uv[tile_id] = total_uv

		if sync_spatial:
			tile["sunlight_direct"] = direct
			tile["sunlight_diffuse"] = diffuse
			tile["sunlight_total"] = insolation
			tile["surface_albedo"] = albedo
			tile["sunlight_reflected"] = reflected_solar
			tile["sunlight_absorbed"] = absorbed_solar
			tile["uv_index"] = uv_index
			tile["uv_daily_dose"] = daily_uv
			tile["heat_load"] = heat_load
			tile["plant_growth_factor"] = plant_growth_factor
			tile["sunlight_cumulative"] = total_sun
			tile["solar_shade_factor"] = shade
			tile["solar_humidity_attenuation"] = humidity
			tile_index[tile_id] = tile

		if _emit_rows:
			var row = {
				"tile_id": tile_id,
				"sunlight_direct": direct,
				"sunlight_diffuse": diffuse,
				"sunlight_total": insolation,
				"surface_albedo": albedo,
				"sunlight_reflected": reflected_solar,
				"sunlight_absorbed": absorbed_solar,
				"uv_index": uv_index,
				"uv_daily_dose": daily_uv,
				"heat_load": heat_load,
				"plant_growth_factor": plant_growth_factor,
				"sunlight_cumulative": total_sun,
				"uv_cumulative": total_uv,
				"shade_factor": shade,
			}
			solar_rows.append(row)
			solar_index[tile_id] = row
		elif sync_spatial:
			solar_index[tile_id] = {
				"sunlight_total": insolation,
				"surface_albedo": albedo,
				"sunlight_absorbed": absorbed_solar,
				"sunlight_reflected": reflected_solar,
				"uv_index": uv_index,
				"heat_load": heat_load,
				"plant_growth_factor": plant_growth_factor,
			}
		if not _emit_rows and i < packed_sunlight.size():
			packed_sunlight[i] = insolation
			packed_uv[i] = uv_index
			packed_heat[i] = heat_load
			packed_growth[i] = plant_growth_factor
		sum_insolation += insolation
		sum_uv += uv_index
		sum_heat += heat_load
		sum_growth += plant_growth_factor
		sample_count += 1

	if sync_spatial:
		_sync_tiles(environment_snapshot, tile_index)
		_sync_voxel_columns(environment_snapshot, solar_index)

	var n = float(maxi(1, sample_count))
	_last_snapshot = {
		"schema_version": 1,
		"tick": tick,
		"sun_dir": {"x": sun_dir.x, "y": sun_dir.y},
		"sun_altitude": sun_alt,
		"avg_insolation": sum_insolation / n,
		"avg_uv_index": sum_uv / n,
		"avg_heat_load": sum_heat / n,
		"avg_growth_factor": sum_growth / n,
		"rows": solar_rows,
		"tile_index": solar_index,
	}
	if not _emit_rows:
		_last_snapshot["buffers"] = {
			"sunlight_total": packed_sunlight,
			"uv_index": packed_uv,
			"heat_load": packed_heat,
			"plant_growth_factor": packed_growth,
		}
	return _last_snapshot.duplicate(true)

func current_snapshot(tick: int = 0) -> Dictionary:
	if _last_snapshot.is_empty():
		return _build_snapshot(tick, [], {})
	return _last_snapshot.duplicate(true)

func import_snapshot(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	_last_snapshot = snapshot.duplicate(true)
	_daily_sun.clear()
	_daily_uv.clear()
	_cumulative_sun.clear()
	_cumulative_uv.clear()
	var buffers: Dictionary = snapshot.get("buffers", {})
	if not buffers.is_empty():
		var sun_buf: PackedFloat32Array = buffers.get("sunlight_total", PackedFloat32Array())
		var uv_buf: PackedFloat32Array = buffers.get("uv_index", PackedFloat32Array())
		if sun_buf.size() == _ordered_tile_ids.size() and uv_buf.size() == _ordered_tile_ids.size():
			for i in range(_ordered_tile_ids.size()):
				var tile_id = _ordered_tile_ids[i]
				var sun = float(sun_buf[i])
				var uv = float(uv_buf[i])
				_daily_sun[tile_id] = sun
				_daily_uv[tile_id] = uv
				_cumulative_sun[tile_id] = sun
				_cumulative_uv[tile_id] = uv
			return
	var rows: Array = snapshot.get("rows", [])
	for row_variant in rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var tile_id = String(row.get("tile_id", ""))
		if tile_id == "":
			continue
		_daily_sun[tile_id] = float(row.get("sunlight_total", 0.0))
		_daily_uv[tile_id] = float(row.get("uv_daily_dose", 0.0))
		_cumulative_sun[tile_id] = float(row.get("sunlight_cumulative", 0.0))
		_cumulative_uv[tile_id] = float(row.get("uv_cumulative", 0.0))

func _build_snapshot(tick: int, rows: Array, index: Dictionary) -> Dictionary:
	return {
		"schema_version": 1,
		"tick": tick,
		"sun_dir": {"x": 1.0, "y": 0.0},
		"sun_altitude": 0.0,
		"avg_insolation": 0.0,
		"avg_uv_index": 0.0,
		"avg_heat_load": 0.0,
		"avg_growth_factor": 0.0,
		"rows": rows,
		"tile_index": index,
	}

func _static_shade_for(tile_id: String) -> float:
	var coords = TileKeyUtilsScript.parse_tile_id(tile_id)
	if coords.x == 2147483647:
		return 0.0
	var x = coords.x
	var y = coords.y
	var center_h = float(_surface_y.get(tile_id, 0))
	var max_rise = 0.0
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			if ox == 0 and oy == 0:
				continue
			var nx = x + ox
			var ny = y + oy
			var nid = TileKeyUtilsScript.tile_id(nx, ny)
			if not _surface_y.has(nid):
				continue
				var rise = float(_surface_y.get(nid, center_h)) - center_h
				max_rise = maxf(max_rise, rise)
	return clampf(max_rise / 12.0, 0.0, 1.0)

func _build_aspect_gradient(tile_id: String) -> Vector2:
	var coords = TileKeyUtilsScript.parse_tile_id(tile_id)
	if coords.x == 2147483647:
		return Vector2.ZERO
	var x = coords.x
	var y = coords.y
	var c = float(_surface_y.get(tile_id, 0))
	var ex = float(_surface_y.get(TileKeyUtilsScript.tile_id(x + 1, y), c))
	var wx = float(_surface_y.get(TileKeyUtilsScript.tile_id(x - 1, y), c))
	var ny = float(_surface_y.get(TileKeyUtilsScript.tile_id(x, y + 1), c))
	var sy = float(_surface_y.get(TileKeyUtilsScript.tile_id(x, y - 1), c))
	return Vector2(ex - wx, ny - sy)

func _sync_tiles(environment_snapshot: Dictionary, tile_index: Dictionary) -> void:
	var tiles: Array = environment_snapshot.get("tiles", [])
	for i in range(tiles.size()):
		if not (tiles[i] is Dictionary):
			continue
		var row = tiles[i] as Dictionary
		var tile_id = String(row.get("tile_id", TileKeyUtilsScript.tile_id(int(row.get("x", 0)), int(row.get("y", 0)))))
		if tile_index.has(tile_id):
			tiles[i] = (tile_index[tile_id] as Dictionary).duplicate(true)
	environment_snapshot["tiles"] = tiles
	environment_snapshot["tile_index"] = tile_index

func _sync_voxel_columns(environment_snapshot: Dictionary, solar_index: Dictionary) -> void:
	var voxel_world: Dictionary = environment_snapshot.get("voxel_world", {})
	var cols: Array = voxel_world.get("columns", [])
	var changed = false
	for i in range(cols.size()):
		if not (cols[i] is Dictionary):
			continue
		var col = cols[i] as Dictionary
		var tile_id = TileKeyUtilsScript.tile_id(int(col.get("x", 0)), int(col.get("z", 0)))
		if not solar_index.has(tile_id):
			continue
		var row = solar_index[tile_id] as Dictionary
		col["sunlight_total"] = float(row.get("sunlight_total", 0.0))
		col["surface_albedo"] = float(row.get("surface_albedo", 0.35))
		col["sunlight_absorbed"] = float(row.get("sunlight_absorbed", 0.0))
		col["sunlight_reflected"] = float(row.get("sunlight_reflected", 0.0))
		col["uv_index"] = float(row.get("uv_index", 0.0))
		col["heat_load"] = float(row.get("heat_load", 0.0))
		col["plant_growth_factor"] = float(row.get("plant_growth_factor", 0.0))
		cols[i] = col
		changed = true
	if changed:
		voxel_world["columns"] = cols
		environment_snapshot["voxel_world"] = voxel_world

func _configure_compute_backend(_environment_snapshot: Dictionary) -> bool:
	var count = _ordered_tile_ids.size()
	if count <= 0:
		return false
	var elevation := PackedFloat32Array()
	var moisture := PackedFloat32Array()
	var temperature := PackedFloat32Array()
	var shade := PackedFloat32Array()
	var aspect_x := PackedFloat32Array()
	var aspect_y := PackedFloat32Array()
	var albedo := PackedFloat32Array()
	elevation.resize(count)
	moisture.resize(count)
	temperature.resize(count)
	shade.resize(count)
	aspect_x.resize(count)
	aspect_y.resize(count)
	albedo.resize(count)
	for i in range(count):
		var tile_id = _ordered_tile_ids[i]
		var tile_row = {}
		var tile_index: Dictionary = _environment_snapshot.get("tile_index", {}) if not _environment_snapshot.is_empty() else {}
		if tile_index.has(tile_id) and tile_index.get(tile_id, {}) is Dictionary:
			tile_row = tile_index.get(tile_id, {})
		var elev_n = 0.0
		if _height > 1:
			elev_n = clampf(float(_surface_y.get(tile_id, 0)) / float(maxi(1, _height - 1)), 0.0, 1.0)
		elevation[i] = elev_n
		moisture[i] = clampf(float((tile_row as Dictionary).get("moisture", 0.5)) if tile_row is Dictionary else 0.5, 0.0, 1.0)
		temperature[i] = clampf(float((tile_row as Dictionary).get("temperature", 0.5)) if tile_row is Dictionary else 0.5, 0.0, 1.0)
		shade[i] = clampf(float(_shade_static.get(tile_id, 0.0)), 0.0, 1.0)
		var grad = _aspect_gradient.get(tile_id, Vector2.ZERO)
		if grad is Vector2:
			var g = grad as Vector2
			aspect_x[i] = g.x
			aspect_y[i] = g.y
		else:
			aspect_x[i] = 0.0
			aspect_y[i] = 0.0
		albedo[i] = clampf(float(_surface_albedo.get(tile_id, 0.35)), 0.02, 0.9)
	return _compute_backend.configure(elevation, moisture, temperature, shade, aspect_x, aspect_y, albedo)

func benchmark_cpu_vs_compute(environment_snapshot: Dictionary, weather_snapshot: Dictionary, iterations: int = 16, delta: float = 0.5) -> Dictionary:
	if not _configured:
		return {"ok": false, "error": "not_configured"}
	var loops = maxi(1, iterations)
	var saved_compute_requested = _compute_requested
	var saved_compute_active = _compute_active
	var saved_emit_rows = _emit_rows
	var saved_sync_stride = _sync_stride
	var saved_daily_sun = _daily_sun.duplicate(true)
	var saved_daily_uv = _daily_uv.duplicate(true)
	var saved_cum_sun = _cumulative_sun.duplicate(true)
	var saved_cum_uv = _cumulative_uv.duplicate(true)
	_emit_rows = false
	_sync_stride = maxi(32, _sync_stride)
	_compute_requested = false
	_compute_active = false
	var cpu_start_us = Time.get_ticks_usec()
	for i in range(loops):
		step(i + 1, delta, environment_snapshot, weather_snapshot)
	var cpu_ms = float(Time.get_ticks_usec() - cpu_start_us) / 1000.0
	_daily_sun = saved_daily_sun.duplicate(true)
	_daily_uv = saved_daily_uv.duplicate(true)
	_cumulative_sun = saved_cum_sun.duplicate(true)
	_cumulative_uv = saved_cum_uv.duplicate(true)
	_compute_requested = true
	_compute_active = _configure_compute_backend(environment_snapshot)
	var gpu_ok = _compute_active
	var gpu_ms = -1.0
	if gpu_ok:
		var gpu_start_us = Time.get_ticks_usec()
		for i in range(loops):
			step(i + 1, delta, environment_snapshot, weather_snapshot)
		gpu_ms = float(Time.get_ticks_usec() - gpu_start_us) / 1000.0
	_daily_sun = saved_daily_sun.duplicate(true)
	_daily_uv = saved_daily_uv.duplicate(true)
	_cumulative_sun = saved_cum_sun.duplicate(true)
	_cumulative_uv = saved_cum_uv.duplicate(true)
	_emit_rows = saved_emit_rows
	_sync_stride = saved_sync_stride
	_compute_requested = saved_compute_requested
	_compute_active = saved_compute_active and _compute_backend.is_configured()
	return {
		"ok": true,
		"iterations": loops,
		"cpu_ms_total": cpu_ms,
		"cpu_ms_per_step": cpu_ms / float(loops),
		"gpu_ok": gpu_ok,
		"gpu_ms_total": gpu_ms,
		"gpu_ms_per_step": gpu_ms / float(loops) if gpu_ok and gpu_ms >= 0.0 else -1.0,
	}

func _albedo_from_rgba(rgba_variant: Variant) -> float:
	var rgba: Array = []
	if rgba_variant is Array:
		rgba = rgba_variant as Array
	var r = clampf(float(rgba[0]) if rgba.size() > 0 else 0.5, 0.0, 1.0)
	var g = clampf(float(rgba[1]) if rgba.size() > 1 else 0.5, 0.0, 1.0)
	var b = clampf(float(rgba[2]) if rgba.size() > 2 else 0.5, 0.0, 1.0)
	var a = clampf(float(rgba[3]) if rgba.size() > 3 else 1.0, 0.0, 1.0)
	# Linear luminance-based reflectance from RGBA source color.
	var luminance = clampf(r * 0.2126 + g * 0.7152 + b * 0.0722, 0.0, 1.0)
	var rough_alpha = clampf(0.35 + a * 0.65, 0.0, 1.0)
	return clampf(luminance * rough_alpha, 0.02, 0.9)

func _write_activity_buffer(local_activity: Dictionary) -> void:
	if _activity_buffer.size() != _ordered_tile_ids.size():
		_activity_buffer.resize(_ordered_tile_ids.size())
	_activity_buffer.fill(0.0)
	if local_activity.is_empty():
		return
	for i in range(_ordered_tile_ids.size()):
		var tile_id = _ordered_tile_ids[i]
		if local_activity.has(tile_id):
			_activity_buffer[i] = clampf(float(local_activity.get(tile_id, 0.0)), 0.0, 1.0)
