extends RefCounted
class_name LocalAgentsHydrologySystem

func build_network(world_data: Dictionary, config) -> Dictionary:
    var width = int(world_data.get("width", 0))
    var height = int(world_data.get("height", 0))
    var tiles: Array = world_data.get("tiles", [])

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
