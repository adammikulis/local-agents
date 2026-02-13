extends RefCounted
class_name LocalAgentsHydrologySystemHelpers

const TileKeyUtilsScript = preload("res://addons/local_agents/simulation/TileKeyUtils.gd")

static func next_downhill_tile(tile_id: String, by_id: Dictionary, by_xy: Dictionary) -> String:
	if not by_id.has(tile_id):
		return ""
	var tile: Dictionary = by_id[tile_id]
	var x = int(tile.get("x", 0))
	var y = int(tile.get("y", 0))
	var current_elevation = float(tile.get("elevation", 0.0))

	var best_id = ""
	var best_elevation = current_elevation
	var neighbors = [
		"%d:%d" % [x + 1, y],
		"%d:%d" % [x - 1, y],
		"%d:%d" % [x, y + 1],
		"%d:%d" % [x, y - 1],
	]
	neighbors.sort()

	for xy_key in neighbors:
		if not by_xy.has(xy_key):
			continue
		var candidate: Dictionary = by_xy[xy_key]
		var candidate_elevation = float(candidate.get("elevation", 0.0))
		if candidate_elevation < best_elevation - 0.001:
			best_elevation = candidate_elevation
			best_id = String(candidate.get("tile_id", ""))

	return best_id

static func total_flow(flow_by_tile: Dictionary) -> float:
	var total = 0.0
	var keys = flow_by_tile.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	for key in keys:
		total += float(flow_by_tile.get(key, 0.0))
	return total

static func dedupe_sorted_strings(values: Array) -> Array:
	var normalized: Array = []
	for value_variant in values:
		var value = String(value_variant)
		if value == "":
			continue
		normalized.append(value)
	normalized.sort()
	var out: Array = []
	var last = ""
	for value_variant in normalized:
		var value = String(value_variant)
		if value == last:
			continue
		out.append(value)
		last = value
	return out

static func sync_tiles(environment_snapshot: Dictionary, tile_index: Dictionary) -> void:
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

static func coastal_activity_bonus(tile: Dictionary) -> float:
	var elevation = clampf(float(tile.get("elevation", 0.5)), 0.0, 1.0)
	var continentalness = clampf(float(tile.get("continentalness", 0.5)), 0.0, 1.0)
	var shore_band = clampf(1.0 - absf(elevation - 0.34) * 4.0, 0.0, 1.0)
	var ocean_bias = clampf((0.58 - continentalness) * 2.0, 0.0, 1.0)
	return clampf(shore_band * (0.25 + ocean_bias * 0.55), 0.0, 1.0)

static func cadence_for_activity(activity: float, idle_cadence: int) -> int:
	var max_cadence = maxi(1, idle_cadence)
	var a = clampf(activity, 0.0, 1.0)
	return clampi(int(round(lerpf(float(max_cadence), 1.0, a))), 1, max_cadence)

static func should_step_tile(tile_id: String, tick: int, cadence: int, seed: int) -> bool:
	if cadence <= 1:
		return true
	var phase = abs(int(hash("%s|%d" % [tile_id, seed]))) % cadence
	return (tick + phase) % cadence == 0

static func weather_at_tile(
	tile_id: String,
	weather_tiles: Dictionary,
	weather_snapshot: Dictionary,
	weather_rain: PackedFloat32Array,
	weather_wetness: PackedFloat32Array,
	weather_buffer_ok: bool,
	width: int
) -> Dictionary:
	if weather_buffer_ok and width > 0:
		var coords = TileKeyUtilsScript.parse_tile_id(tile_id)
		if coords.x != 2147483647 and coords.y != 2147483647:
			var idx = coords.y * width + coords.x
			if idx >= 0 and idx < weather_rain.size():
				return {
					"rain": clampf(float(weather_rain[idx]), 0.0, 1.0),
					"wetness": clampf(float(weather_wetness[idx]), 0.0, 1.0),
				}
	var weather_row = weather_tiles.get(tile_id, {})
	if weather_row is Dictionary:
		return {
			"rain": clampf(float((weather_row as Dictionary).get("rain", weather_snapshot.get("avg_rain_intensity", 0.0))), 0.0, 1.0),
			"wetness": clampf(float((weather_row as Dictionary).get("wetness", weather_snapshot.get("avg_rain_intensity", 0.0))), 0.0, 1.0),
		}
	var avg_rain = clampf(float(weather_snapshot.get("avg_rain_intensity", 0.0)), 0.0, 1.0)
	return {"rain": avg_rain, "wetness": avg_rain}
