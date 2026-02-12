extends RefCounted
class_name LocalAgentsSolarExposureSystem

var _configured: bool = false
var _seed: int = 0
var _width: int = 0
var _height: int = 0
var _surface_y: Dictionary = {}
var _shade_static: Dictionary = {}
var _daily_sun: Dictionary = {}
var _daily_uv: Dictionary = {}
var _cumulative_sun: Dictionary = {}
var _cumulative_uv: Dictionary = {}
var _last_snapshot: Dictionary = {}

func configure_environment(environment_snapshot: Dictionary, seed: int) -> Dictionary:
	_seed = seed
	_width = int(environment_snapshot.get("width", 0))
	_height = int(environment_snapshot.get("height", 0))
	_configured = _width > 0 and _height > 0
	if not _configured:
		return {"ok": false, "error": "invalid_dimensions"}
	_surface_y.clear()
	_shade_static.clear()
	_daily_sun.clear()
	_daily_uv.clear()
	_cumulative_sun.clear()
	_cumulative_uv.clear()
	_last_snapshot = {}

	var voxel_world: Dictionary = environment_snapshot.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	for col_variant in columns:
		if not (col_variant is Dictionary):
			continue
		var col = col_variant as Dictionary
		var tile_id = "%d:%d" % [int(col.get("x", 0)), int(col.get("z", 0))]
		_surface_y[tile_id] = int(col.get("surface_y", 0))
	var tile_index: Dictionary = environment_snapshot.get("tile_index", {})
	var ids = tile_index.keys()
	ids.sort_custom(func(a, b): return String(a) < String(b))
	for tile_id_variant in ids:
		var tile_id = String(tile_id_variant)
		_shade_static[tile_id] = _static_shade_for(tile_id)
		_daily_sun[tile_id] = 0.0
		_daily_uv[tile_id] = 0.0
		_cumulative_sun[tile_id] = 0.0
		_cumulative_uv[tile_id] = 0.0
	_last_snapshot = _build_snapshot(0, {}, {})
	return {"ok": true}

func step(tick: int, delta: float, environment_snapshot: Dictionary, weather_snapshot: Dictionary) -> Dictionary:
	if not _configured:
		return {}
	if tick > 0 and tick % 24 == 0:
		var reset_ids = _daily_sun.keys()
		for tile_id_variant in reset_ids:
			var tile_id = String(tile_id_variant)
			_daily_sun[tile_id] = 0.0
			_daily_uv[tile_id] = 0.0

	var tile_index: Dictionary = environment_snapshot.get("tile_index", {})
	if tile_index.is_empty():
		return _last_snapshot.duplicate(true)
	var weather_tiles: Dictionary = weather_snapshot.get("tile_index", {})
	var tod = fposmod(float(tick), 24.0) / 24.0
	var sun_alt = maxf(0.0, sin((tod - 0.25) * TAU))
	var sun_dir = Vector2(cos((tod - 0.25) * TAU), sin((tod - 0.25) * TAU))

	var solar_rows: Array = []
	var solar_index: Dictionary = {}
	var ids = tile_index.keys()
	ids.sort_custom(func(a, b): return String(a) < String(b))
	var sum_insolation = 0.0
	var sum_uv = 0.0
	var sum_heat = 0.0
	var sum_growth = 0.0

	for tile_id_variant in ids:
		var tile_id = String(tile_id_variant)
		var tile_row = tile_index.get(tile_id, {})
		if not (tile_row is Dictionary):
			continue
		var tile = tile_row as Dictionary
		var weather_row = weather_tiles.get(tile_id, {})
		var cloud = clampf(float((weather_row as Dictionary).get("cloud", weather_snapshot.get("avg_cloud_cover", 0.0)) if weather_row is Dictionary else weather_snapshot.get("avg_cloud_cover", 0.0)), 0.0, 1.0)
		var fog = clampf(float((weather_row as Dictionary).get("fog", weather_snapshot.get("avg_fog_intensity", 0.0)) if weather_row is Dictionary else weather_snapshot.get("avg_fog_intensity", 0.0)), 0.0, 1.0)
		var humidity = clampf(float((weather_row as Dictionary).get("humidity", weather_snapshot.get("avg_humidity", 0.0)) if weather_row is Dictionary else weather_snapshot.get("avg_humidity", 0.0)), 0.0, 1.0)
		var moisture = clampf(float(tile.get("moisture", 0.5)), 0.0, 1.0)
		var temperature = clampf(float(tile.get("temperature", 0.5)), 0.0, 1.0)
		var elevation = clampf(float(tile.get("elevation", 0.5)), 0.0, 1.0)
		var slope = clampf(float(tile.get("slope", 0.2)), 0.0, 1.0)
		var shade = clampf(float(_shade_static.get(tile_id, 0.0)), 0.0, 1.0)
		var aspect_factor = _aspect_factor(tile_id, sun_dir)
		var cloud_atten = (1.0 - cloud * 0.72)
		var fog_atten = (1.0 - fog * 0.45)
		var direct = sun_alt * cloud_atten * fog_atten * (1.0 - shade * 0.75) * aspect_factor
		var diffuse = (0.18 + cloud * 0.5) * (1.0 - fog * 0.35)
		var insolation = clampf(direct + diffuse * 0.5, 0.0, 1.0)
		var uv_index = clampf((direct * 1.1 + (1.0 - cloud) * 0.25) * (0.65 + elevation * 0.7) * (0.75 + sun_alt * 0.5), 0.0, 2.0)
		var heat_load = clampf(insolation * (0.6 + (1.0 - cloud) * 0.2) + uv_index * 0.15 - moisture * 0.08, 0.0, 1.5)
		var temp_optimal = 1.0 - clampf(absf(temperature - 0.56) * 1.2, 0.0, 1.0)
		var uv_stress = clampf(maxf(0.0, uv_index - 1.15) * 0.45, 0.0, 1.0)
		var plant_growth_factor = clampf(insolation * (0.35 + moisture * 0.65) * temp_optimal * (1.0 - uv_stress), 0.0, 1.0)

		var daily_sun = float(_daily_sun.get(tile_id, 0.0)) + insolation * delta
		var daily_uv = float(_daily_uv.get(tile_id, 0.0)) + uv_index * delta
		var total_sun = float(_cumulative_sun.get(tile_id, 0.0)) + insolation * delta
		var total_uv = float(_cumulative_uv.get(tile_id, 0.0)) + uv_index * delta
		_daily_sun[tile_id] = daily_sun
		_daily_uv[tile_id] = daily_uv
		_cumulative_sun[tile_id] = total_sun
		_cumulative_uv[tile_id] = total_uv

		tile["sunlight_direct"] = direct
		tile["sunlight_diffuse"] = diffuse
		tile["sunlight_total"] = insolation
		tile["uv_index"] = uv_index
		tile["uv_daily_dose"] = daily_uv
		tile["heat_load"] = heat_load
		tile["plant_growth_factor"] = plant_growth_factor
		tile["sunlight_cumulative"] = total_sun
		tile["solar_shade_factor"] = shade
		tile["solar_humidity_attenuation"] = humidity
		tile_index[tile_id] = tile

		var row = {
			"tile_id": tile_id,
			"sunlight_direct": direct,
			"sunlight_diffuse": diffuse,
			"sunlight_total": insolation,
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
		sum_insolation += insolation
		sum_uv += uv_index
		sum_heat += heat_load
		sum_growth += plant_growth_factor

	_sync_tiles(environment_snapshot, tile_index)
	_sync_voxel_columns(environment_snapshot, solar_index)

	var n = float(maxi(1, solar_rows.size()))
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
	return _last_snapshot.duplicate(true)

func current_snapshot(tick: int = 0) -> Dictionary:
	if _last_snapshot.is_empty():
		return _build_snapshot(tick, {}, {})
	return _last_snapshot.duplicate(true)

func import_snapshot(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	_last_snapshot = snapshot.duplicate(true)
	_daily_sun.clear()
	_daily_uv.clear()
	_cumulative_sun.clear()
	_cumulative_uv.clear()
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
	var parts = tile_id.split(":")
	if parts.size() != 2:
		return 0.0
	var x = int(parts[0])
	var y = int(parts[1])
	var center_h = float(_surface_y.get(tile_id, 0))
	var max_rise = 0.0
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			if ox == 0 and oy == 0:
				continue
			var nx = x + ox
			var ny = y + oy
			var nid = "%d:%d" % [nx, ny]
			if not _surface_y.has(nid):
				continue
			var rise = float(_surface_y.get(nid, center_h)) - center_h
			max_rise = maxf(max_rise, rise)
	return clampf(max_rise / 12.0, 0.0, 1.0)

func _aspect_factor(tile_id: String, sun_dir: Vector2) -> float:
	var parts = tile_id.split(":")
	if parts.size() != 2:
		return 1.0
	var x = int(parts[0])
	var y = int(parts[1])
	var c = float(_surface_y.get(tile_id, 0))
	var ex = float(_surface_y.get("%d:%d" % [x + 1, y], c))
	var wx = float(_surface_y.get("%d:%d" % [x - 1, y], c))
	var ny = float(_surface_y.get("%d:%d" % [x, y + 1], c))
	var sy = float(_surface_y.get("%d:%d" % [x, y - 1], c))
	var grad = Vector2(ex - wx, ny - sy)
	if grad.length_squared() < 0.0001:
		return 1.0
	var downhill = (-grad).normalized()
	var facing = clampf(downhill.dot(sun_dir.normalized()), -1.0, 1.0)
	return clampf(0.62 + 0.38 * (facing * 0.5 + 0.5), 0.3, 1.0)

func _sync_tiles(environment_snapshot: Dictionary, tile_index: Dictionary) -> void:
	var tiles: Array = environment_snapshot.get("tiles", [])
	for i in range(tiles.size()):
		if not (tiles[i] is Dictionary):
			continue
		var row = tiles[i] as Dictionary
		var tile_id = String(row.get("tile_id", "%d:%d" % [int(row.get("x", 0)), int(row.get("y", 0))]))
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
		var tile_id = "%d:%d" % [int(col.get("x", 0)), int(col.get("z", 0))]
		if not solar_index.has(tile_id):
			continue
		var row = solar_index[tile_id] as Dictionary
		col["sunlight_total"] = float(row.get("sunlight_total", 0.0))
		col["uv_index"] = float(row.get("uv_index", 0.0))
		col["heat_load"] = float(row.get("heat_load", 0.0))
		col["plant_growth_factor"] = float(row.get("plant_growth_factor", 0.0))
		cols[i] = col
		changed = true
	if changed:
		voxel_world["columns"] = cols
		environment_snapshot["voxel_world"] = voxel_world
