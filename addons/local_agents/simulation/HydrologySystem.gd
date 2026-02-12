extends RefCounted
class_name LocalAgentsHydrologySystem

func build_network(world_data: Dictionary, config) -> Dictionary:
    var width = int(world_data.get("width", 0))
    var height = int(world_data.get("height", 0))
    var tiles: Array = world_data.get("tiles", [])
    var flow_map: Dictionary = world_data.get("flow_map", {})
    if not flow_map.is_empty():
        return _build_network_from_flow_map(flow_map, tiles, config)

    var by_xy: Dictionary = {}
    var by_id: Dictionary = {}
    for row_variant in tiles:
        if not (row_variant is Dictionary):
            continue
        var row: Dictionary = row_variant
        var x = int(row.get("x", 0))
        var y = int(row.get("y", 0))
        var tile_id = String(row.get("tile_id", "%d:%d" % [x, y]))
        by_xy["%d:%d" % [x, y]] = row
        by_id[tile_id] = row

    var sources: Array = []
    for row_variant in tiles:
        var row: Dictionary = row_variant
        if float(row.get("elevation", 0.0)) >= float(config.spring_elevation_threshold) and float(row.get("moisture", 0.0)) >= float(config.spring_moisture_threshold):
            sources.append(String(row.get("tile_id", "")))
    sources.sort()

    var flow_by_tile: Dictionary = {}
    var segments: Array = []
    var max_steps = maxi(4, width + height)

    for source_id in sources:
        var current_id = source_id
        var visited: Dictionary = {}
        for step in range(max_steps):
            if visited.has(current_id):
                break
            visited[current_id] = true
            flow_by_tile[current_id] = float(flow_by_tile.get(current_id, 0.0)) + 1.0
            var next_id = _next_downhill_tile(current_id, by_id, by_xy)
            if next_id == "":
                break
            segments.append({"from": current_id, "to": next_id})
            current_id = next_id

    var water_tiles: Dictionary = {}
    for row_variant in tiles:
        var row: Dictionary = row_variant
        var tile_id = String(row.get("tile_id", ""))
        var flow = float(flow_by_tile.get(tile_id, 0.0))
        var moisture = float(row.get("moisture", 0.0))
        var perennial = clampf((flow / 5.0) * 0.7 + moisture * 0.3, 0.0, 1.0)
        var flood_risk = clampf((flow - float(config.floodplain_flow_threshold) + 1.0) / 4.0, 0.0, 1.0)
        water_tiles[tile_id] = {
            "flow": flow,
            "water_reliability": perennial,
            "flood_risk": flood_risk,
        }

    segments.sort_custom(func(a, b):
        var a_key = "%s>%s" % [String(a.get("from", "")), String(a.get("to", ""))]
        var b_key = "%s>%s" % [String(b.get("from", "")), String(b.get("to", ""))]
        return a_key < b_key
    )

    return {
        "schema_version": 1,
        "source_tiles": sources,
        "segments": segments,
        "water_tiles": water_tiles,
        "total_flow_index": _total_flow(flow_by_tile),
    }

func _build_network_from_flow_map(flow_map: Dictionary, tiles: Array, config) -> Dictionary:
    var by_tile: Dictionary = {}
    for row_variant in tiles:
        if not (row_variant is Dictionary):
            continue
        var row = row_variant as Dictionary
        var tile_id = String(row.get("tile_id", ""))
        if tile_id != "":
            by_tile[tile_id] = row

    var rows: Array = flow_map.get("rows", [])
    var max_flow = maxf(0.001, float(flow_map.get("max_flow", 1.0)))
    var segments: Array = []
    var sources: Array = []
    var water_tiles: Dictionary = {}
    var total_flow = 0.0

    for row_variant in rows:
        if not (row_variant is Dictionary):
            continue
        var row = row_variant as Dictionary
        var tile_id = String(row.get("tile_id", ""))
        if tile_id == "":
            continue
        var downstream = String(row.get("to_tile_id", ""))
        if downstream != "":
            segments.append({"from": tile_id, "to": downstream})
        var accumulation = maxf(0.0, float(row.get("flow_accumulation", 0.0)))
        total_flow += accumulation
        var flow_norm = clampf(accumulation / max_flow, 0.0, 1.0)
        var moisture = clampf(float(row.get("moisture", 0.0)), 0.0, 1.0)
        var reliability = clampf(flow_norm * 0.78 + moisture * 0.22, 0.0, 1.0)
        var flood_risk = clampf((flow_norm - 0.55) * 2.1, 0.0, 1.0)
        water_tiles[tile_id] = {
            "flow": accumulation,
            "water_reliability": reliability,
            "flood_risk": flood_risk,
        }

        var tile = by_tile.get(tile_id, {})
        var tile_elevation = 0.0
        if tile is Dictionary:
            tile_elevation = float((tile as Dictionary).get("elevation", 0.0))
        var elevation = clampf(float(row.get("elevation", tile_elevation)), 0.0, 1.0)
        if elevation >= float(config.spring_elevation_threshold) and moisture >= float(config.spring_moisture_threshold):
            sources.append(tile_id)

    if sources.is_empty():
        var ranked: Array = rows.duplicate(true)
        ranked.sort_custom(func(a, b):
            var af = float((a as Dictionary).get("flow_accumulation", 0.0))
            var bf = float((b as Dictionary).get("flow_accumulation", 0.0))
            if is_equal_approx(af, bf):
                return String((a as Dictionary).get("tile_id", "")) < String((b as Dictionary).get("tile_id", ""))
            return af > bf
        )
        for i in range(mini(8, ranked.size())):
            var row = ranked[i] as Dictionary
            var tile_id = String(row.get("tile_id", ""))
            if tile_id != "":
                sources.append(tile_id)
    sources.sort()

    segments.sort_custom(func(a, b):
        var a_key = "%s>%s" % [String(a.get("from", "")), String(a.get("to", ""))]
        var b_key = "%s>%s" % [String(b.get("from", "")), String(b.get("to", ""))]
        return a_key < b_key
    )

    return {
        "schema_version": 1,
        "source_tiles": sources,
        "segments": segments,
        "water_tiles": water_tiles,
        "total_flow_index": total_flow,
        "flow_map_schema_version": int(flow_map.get("schema_version", 1)),
    }

func _next_downhill_tile(tile_id: String, by_id: Dictionary, by_xy: Dictionary) -> String:
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

func _total_flow(flow_by_tile: Dictionary) -> float:
    var total = 0.0
    var keys = flow_by_tile.keys()
    keys.sort_custom(func(a, b): return String(a) < String(b))
    for key in keys:
        total += float(flow_by_tile.get(key, 0.0))
    return total
