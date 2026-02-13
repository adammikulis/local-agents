extends RefCounted

static func collect_volcanic_features(
    width: int,
    height: int,
    voxel_world_height: int,
    volcanic_noise: FastNoiseLite,
    continental_noise: FastNoiseLite,
    config
) -> Array:
    var features: Array = []
    var threshold = clampf(float(_config_value(config, "volcanic_threshold", 0.76)), 0.0, 1.0)
    var min_radius = maxi(1, int(_config_value(config, "volcanic_radius_min", 2)))
    var max_radius = maxi(min_radius, int(_config_value(config, "volcanic_radius_max", 5)))
    var cone_height = clampf(float(_config_value(config, "volcanic_cone_height", 6.0)), 0.0, 24.0)
    var crater_depth = clampf(float(_config_value(config, "volcanic_crater_depth", 2.0)), 0.0, 12.0)
    var claimed: Dictionary = {}
    for z in range(height):
        for x in range(width):
            var n = clampf((volcanic_noise.get_noise_2d(float(x), float(z)) + 1.0) * 0.5, 0.0, 1.0)
            if n < threshold:
                continue
            var continental = clampf((continental_noise.get_noise_2d(float(x - 13), float(z + 17)) + 1.0) * 0.5, 0.0, 1.0)
            var radius = clampi(min_radius + int(round((1.0 - threshold) * 6.0 + (n - threshold) * 11.0)), min_radius, max_radius)
            var id = "%d:%d" % [x, z]
            if claimed.has(id):
                continue
            var activity = clampf((n - threshold) / maxf(0.001, 1.0 - threshold), 0.0, 1.0)
            var oceanic = clampf((0.54 - continental) * 2.0, 0.0, 1.0)
            features.append({
                "id": "volcano:%d:%d" % [x, z],
                "tile_id": id,
                "x": x,
                "y": z,
                "radius": radius,
                "cone_height": cone_height * (0.45 + activity * 0.75 + oceanic * 0.25),
                "crater_depth": crater_depth * (0.55 + activity * 0.85),
                "activity": activity,
                "oceanic": oceanic,
            })
            for dz in range(-radius, radius + 1):
                for dx in range(-radius, radius + 1):
                    var nx = x + dx
                    var nz = z + dz
                    if nx < 0 or nx >= width or nz < 0 or nz >= height:
                        continue
                    if dx * dx + dz * dz <= radius * radius:
                        claimed["%d:%d" % [nx, nz]] = true
    return features

static func build_volcanic_delta_index(width: int, height: int, features: Array) -> Dictionary:
    var index: Dictionary = {}
    for z in range(height):
        for x in range(width):
            var tile_id = "%d:%d" % [x, z]
            var delta = 0.0
            for feature_variant in features:
                if not (feature_variant is Dictionary):
                    continue
                var feature = feature_variant as Dictionary
                var fx = int(feature.get("x", x))
                var fz = int(feature.get("y", z))
                var radius = maxf(1.0, float(feature.get("radius", 2)))
                var cone = maxf(0.0, float(feature.get("cone_height", 0.0)))
                var crater = maxf(0.0, float(feature.get("crater_depth", 0.0)))
                var dx = float(x - fx)
                var dz = float(z - fz)
                var dist = sqrt(dx * dx + dz * dz)
                if dist > radius:
                    continue
                var ring = 1.0 - (dist / radius)
                delta += ring * cone
                if dist < radius * 0.38:
                    var crater_t = 1.0 - (dist / maxf(0.001, radius * 0.38))
                    delta -= crater_t * crater
            index[tile_id] = int(round(delta))
    return index

static func volcanic_influence(tile_id: String, features: Array) -> float:
    var parts = tile_id.split(":")
    if parts.size() != 2:
        return 0.0
    var x = int(parts[0])
    var z = int(parts[1])
    var influence = 0.0
    for feature_variant in features:
        if not (feature_variant is Dictionary):
            continue
        var feature = feature_variant as Dictionary
        var fx = int(feature.get("x", x))
        var fz = int(feature.get("y", z))
        var radius = maxf(1.0, float(feature.get("radius", 2)))
        var dx = float(x - fx)
        var dz = float(z - fz)
        var dist = sqrt(dx * dx + dz * dz)
        if dist > radius * 1.6:
            continue
        var t = 1.0 - clampf(dist / (radius * 1.6), 0.0, 1.0)
        influence = maxf(influence, t * clampf(float(feature.get("activity", 0.0)) * 0.7 + 0.3, 0.0, 1.0))
    return clampf(influence, 0.0, 1.0)

static func bake_flow_map(
    width: int,
    height: int,
    height_map: Dictionary,
    moisture_map: Dictionary,
    elevation_map: Dictionary
) -> Dictionary:
    var next_by_tile: Dictionary = {}
    var incoming_count: Dictionary = {}
    var contributors: Dictionary = {}
    var base_precipitation: Dictionary = {}
    var flow_accumulation: Dictionary = {}
    var all_ids: Array = []

    for z in range(height):
        for x in range(width):
            var tile_id = "%d:%d" % [x, z]
            all_ids.append(tile_id)
            incoming_count[tile_id] = 0
            contributors[tile_id] = []
            var moisture = clampf(float(moisture_map.get(tile_id, 0.0)), 0.0, 1.0)
            var precipitation = 0.15 + moisture * 0.85
            base_precipitation[tile_id] = precipitation
            flow_accumulation[tile_id] = precipitation

    for tile_id_variant in all_ids:
        var tile_id = String(tile_id_variant)
        var down = _next_downhill_tile_id(tile_id, width, height, height_map)
        if down == "":
            continue
        next_by_tile[tile_id] = down
        incoming_count[down] = int(incoming_count.get(down, 0)) + 1
        var incoming: Array = contributors.get(down, [])
        incoming.append(tile_id)
        contributors[down] = incoming

    var queue: Array = []
    for tile_id_variant in all_ids:
        var tile_id = String(tile_id_variant)
        if int(incoming_count.get(tile_id, 0)) == 0:
            queue.append(tile_id)
    queue.sort()

    var idx = 0
    while idx < queue.size():
        var current = String(queue[idx])
        idx += 1
        var downstream = String(next_by_tile.get(current, ""))
        if downstream == "":
            continue
        flow_accumulation[downstream] = float(flow_accumulation.get(downstream, 0.0)) + float(flow_accumulation.get(current, 0.0))
        var next_incoming = int(incoming_count.get(downstream, 0)) - 1
        incoming_count[downstream] = next_incoming
        if next_incoming == 0:
            queue.append(downstream)

    var max_flow = 0.0
    for tile_id_variant in all_ids:
        var tile_id = String(tile_id_variant)
        max_flow = maxf(max_flow, float(flow_accumulation.get(tile_id, 0.0)))

    var rows: Array = []
    var row_index: Dictionary = {}
    var flow_dir_x := PackedFloat32Array()
    var flow_dir_y := PackedFloat32Array()
    var flow_strength := PackedFloat32Array()
    flow_dir_x.resize(width * height)
    flow_dir_y.resize(width * height)
    flow_strength.resize(width * height)
    for tile_id_variant in all_ids:
        var tile_id = String(tile_id_variant)
        var parts = tile_id.split(":")
        var x = int(parts[0]) if parts.size() > 0 else 0
        var z = int(parts[1]) if parts.size() > 1 else 0
        var to_id = String(next_by_tile.get(tile_id, ""))
        var dir_x = 0
        var dir_y = 0
        if to_id != "":
            var next_parts = to_id.split(":")
            var nx = int(next_parts[0]) if next_parts.size() > 0 else x
            var nz = int(next_parts[1]) if next_parts.size() > 1 else z
            dir_x = nx - x
            dir_y = nz - z
        var row = {
            "tile_id": tile_id,
            "x": x,
            "y": z,
            "to_tile_id": to_id,
            "dir_x": dir_x,
            "dir_y": dir_y,
            "is_sink": to_id == "",
            "elevation": clampf(float(elevation_map.get(tile_id, 0.0)), 0.0, 1.0),
            "moisture": clampf(float(moisture_map.get(tile_id, 0.0)), 0.0, 1.0),
            "base_precipitation": float(base_precipitation.get(tile_id, 0.0)),
            "flow_accumulation": float(flow_accumulation.get(tile_id, 0.0)),
            "channel_strength": clampf(float(flow_accumulation.get(tile_id, 0.0)) / maxf(0.001, max_flow * 0.6), 0.0, 1.0),
        }
        rows.append(row)
        row_index[tile_id] = row
        var flat = z * width + x
        if flat >= 0 and flat < flow_strength.size():
            flow_dir_x[flat] = float(dir_x)
            flow_dir_y[flat] = float(dir_y)
            flow_strength[flat] = float(row.get("channel_strength", 0.0))

    return {
        "schema_version": 1,
        "width": width,
        "height": height,
        "max_flow": max_flow,
        "rows": rows,
        "row_index": row_index,
        "flow_dir_x_buffer": flow_dir_x,
        "flow_dir_y_buffer": flow_dir_y,
        "flow_strength_buffer": flow_strength,
    }

static func build_hydrogeology(tiles: Array, tile_index: Dictionary, flow_map: Dictionary, config, voxel_world_height: int) -> Dictionary:
    var rows: Array = flow_map.get("rows", [])
    var flow_by_tile: Dictionary = {}
    for row_variant in rows:
        if not (row_variant is Dictionary):
            continue
        var row = row_variant as Dictionary
        var tile_id = String(row.get("tile_id", ""))
        if tile_id == "":
            continue
        flow_by_tile[tile_id] = clampf(float(row.get("channel_strength", 0.0)), 0.0, 1.0)

    var water_table_rows: Array = []
    var water_table_index: Dictionary = {}
    var hot_springs: Array = []
    var cold_springs: Array = []
    var all_springs: Array = []

    var base_depth = clampf(float(_config_value(config, "water_table_base_depth", 8.0)), 0.0, 96.0)
    var elev_factor = clampf(float(_config_value(config, "water_table_elevation_factor", 9.0)), 0.0, 96.0)
    var moisture_factor = clampf(float(_config_value(config, "water_table_moisture_factor", 6.5)), 0.0, 96.0)
    var flow_factor = clampf(float(_config_value(config, "water_table_flow_factor", 4.0)), 0.0, 96.0)
    var aquifer_factor = clampf(float(_config_value(config, "water_table_aquifer_factor", 3.0)), 0.0, 96.0)
    var spring_max_depth = clampf(float(_config_value(config, "spring_max_depth", 11.0)), 0.0, float(voxel_world_height))
    var spring_pressure_threshold = clampf(float(_config_value(config, "spring_pressure_threshold", 0.52)), 0.0, 1.0)
    var hot_geothermal_threshold = clampf(float(_config_value(config, "hot_spring_geothermal_threshold", 0.62)), 0.0, 1.0)
    var cold_temperature_threshold = clampf(float(_config_value(config, "cold_spring_temperature_threshold", 0.56)), 0.0, 1.0)
    var spring_discharge_base = maxf(0.01, float(_config_value(config, "spring_discharge_base", 1.15)))

    for tile_variant in tiles:
        if not (tile_variant is Dictionary):
            continue
        var tile = tile_variant as Dictionary
        var tile_id = String(tile.get("tile_id", ""))
        if tile_id == "":
            continue
        var elevation = clampf(float(tile.get("elevation", 0.0)), 0.0, 1.0)
        var moisture = clampf(float(tile.get("moisture", 0.0)), 0.0, 1.0)
        var temperature = clampf(float(tile.get("temperature", 0.0)), 0.0, 1.0)
        var geothermal = clampf(float(tile.get("geothermal_activity", 0.0)), 0.0, 1.0)
        var aquifer = clampf(float(tile.get("aquifer_potential", 0.0)), 0.0, 1.0)
        var flow = clampf(float(flow_by_tile.get(tile_id, 0.0)), 0.0, 1.0)
        var depth = base_depth + elevation * elev_factor - moisture * moisture_factor - flow * flow_factor - aquifer * aquifer_factor - geothermal * 1.6
        depth = clampf(depth, 0.0, float(maxi(1, voxel_world_height - 1)))
        var pressure = clampf((spring_max_depth - depth) / maxf(0.001, spring_max_depth), 0.0, 1.0)
        pressure = clampf(pressure * 0.62 + moisture * 0.16 + flow * 0.14 + aquifer * 0.14, 0.0, 1.0)
        var recharge = clampf(moisture * 0.5 + flow * 0.3 + aquifer * 0.2, 0.0, 1.0)

        tile["water_table_depth"] = depth
        tile["hydraulic_pressure"] = pressure
        tile["groundwater_recharge"] = recharge

        var wt_row = {
            "tile_id": tile_id,
            "depth": depth,
            "pressure": pressure,
            "recharge": recharge,
            "aquifer_potential": aquifer,
            "geothermal_activity": geothermal,
        }
        water_table_rows.append(wt_row)
        water_table_index[tile_id] = wt_row
        tile_index[tile_id] = tile

        if pressure < spring_pressure_threshold or depth > spring_max_depth:
            tile["spring_type"] = ""
            tile["spring_discharge"] = 0.0
            continue

        var spring_type = ""
        if geothermal >= hot_geothermal_threshold:
            spring_type = "hot"
        elif temperature <= cold_temperature_threshold:
            spring_type = "cold"
        if spring_type == "":
            tile["spring_type"] = ""
            tile["spring_discharge"] = 0.0
            continue

        var discharge = spring_discharge_base * (0.42 + pressure * 0.74 + flow * 0.55 + recharge * 0.35 + (0.24 if spring_type == "hot" else 0.08))
        var spring_row = {
            "tile_id": tile_id,
            "x": int(tile.get("x", 0)),
            "y": int(tile.get("y", 0)),
            "type": spring_type,
            "discharge": discharge,
            "pressure": pressure,
            "depth": depth,
            "geothermal_activity": geothermal,
        }
        all_springs.append(spring_row)
        if spring_type == "hot":
            hot_springs.append(spring_row)
        else:
            cold_springs.append(spring_row)
        tile["spring_type"] = spring_type
        tile["spring_discharge"] = discharge
        tile_index[tile_id] = tile

    all_springs.sort_custom(func(a, b):
        var ad = float((a as Dictionary).get("discharge", 0.0))
        var bd = float((b as Dictionary).get("discharge", 0.0))
        if is_equal_approx(ad, bd):
            return String((a as Dictionary).get("tile_id", "")) < String((b as Dictionary).get("tile_id", ""))
        return ad > bd
    )

    return {
        "water_table": water_table_index,
        "water_table_rows": water_table_rows,
        "springs": {
            "all": all_springs,
            "hot": hot_springs,
            "cold": cold_springs,
        },
    }

static func _next_downhill_tile_id(tile_id: String, width: int, height: int, height_map: Dictionary) -> String:
    var parts = tile_id.split(":")
    if parts.size() != 2:
        return ""
    var x = int(parts[0])
    var z = int(parts[1])
    var current_height = int(height_map.get(tile_id, 0))
    var best_id = ""
    var best_height = current_height
    var candidates = [
        Vector2i(x + 1, z),
        Vector2i(x - 1, z),
        Vector2i(x, z + 1),
        Vector2i(x, z - 1),
    ]
    for point in candidates:
        if point.x < 0 or point.x >= width or point.y < 0 or point.y >= height:
            continue
        var neighbor_id = "%d:%d" % [point.x, point.y]
        var neighbor_height = int(height_map.get(neighbor_id, current_height))
        if neighbor_height < best_height:
            best_height = neighbor_height
            best_id = neighbor_id
    return best_id

static func _config_value(config, key: String, default_value):
    if config == null:
        return default_value
    if config is Dictionary:
        return (config as Dictionary).get(key, default_value)
    var value = config.get(key)
    if value == null:
        return default_value
    return value
