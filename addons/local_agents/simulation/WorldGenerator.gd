extends RefCounted
class_name LocalAgentsWorldGenerator

const WorldTileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldTileResource.gd")
const FlowMapResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowMapResource.gd")
const BLOCK_AIR := "air"
const BLOCK_GRASS := "grass"
const BLOCK_DIRT := "dirt"
const BLOCK_CLAY := "clay"
const BLOCK_SAND := "sand"
const BLOCK_SNOW := "snow"
const BLOCK_STONE := "stone"
const BLOCK_GRAVEL := "gravel"
const BLOCK_BASALT := "basalt"
const BLOCK_OBSIDIAN := "obsidian"
const BLOCK_COAL_ORE := "coal_ore"
const BLOCK_COPPER_ORE := "copper_ore"
const BLOCK_IRON_ORE := "iron_ore"
const BLOCK_WATER := "water"

func generate(seed: int, config) -> Dictionary:
    var width = int(config.map_width)
    var height = int(config.map_height)
    var simulated_year = float(_config_value(config, "simulated_year", -8000.0))
    var tiles: Array = []
    var tile_index: Dictionary = {}
    var voxel_world_height = maxi(8, int(config.voxel_world_height))
    var surface_noise = _build_noise(
        seed + 1601,
        float(config.voxel_noise_frequency),
        int(config.voxel_noise_octaves),
        float(_config_value(config, "voxel_noise_lacunarity", 2.0)),
        float(_config_value(config, "voxel_noise_gain", 0.5))
    )
    var cave_noise = _build_noise(seed + 2113, float(config.cave_noise_frequency), 3)
    var ore_noise = _build_noise(seed + 2963, float(config.ore_noise_frequency), 2)
    var biome_noise = _build_noise(seed + 3323, float(config.moisture_frequency), maxi(1, int(config.moisture_octaves)))
    var temp_noise = _build_noise(seed + 3467, float(config.temperature_frequency), maxi(1, int(config.temperature_octaves)))
    var tectonic_noise = _build_noise(seed + 3889, float(_config_value(config, "elevation_frequency", 0.135)) * 0.72, maxi(1, int(_config_value(config, "elevation_octaves", 3))), 2.35, 0.46)
    var continental_noise = _build_noise(seed + 3989, float(_config_value(config, "elevation_frequency", 0.135)) * 0.32, maxi(2, int(_config_value(config, "elevation_octaves", 3))), 2.0, 0.52)
    var volcanic_noise = _build_noise(seed + 4153, float(_config_value(config, "volcanic_noise_frequency", 0.028)), 2, 2.2, 0.58)
    var geothermal_noise = _build_noise(seed + 4339, float(_config_value(config, "geothermal_noise_frequency", 0.041)), 3, 2.0, 0.57)
    var aquifer_noise = _build_noise(seed + 4483, float(_config_value(config, "aquifer_noise_frequency", 0.047)), 3, 2.1, 0.54)
    var volcanic_features: Array = _collect_volcanic_features(width, height, voxel_world_height, volcanic_noise, continental_noise, config)
    var volcanic_delta_by_tile: Dictionary = _build_volcanic_delta_index(width, height, volcanic_features, config)

    var voxel_columns: Array = []
    var block_rows: Array = []
    var block_type_counts: Dictionary = {}
    var height_map_index: Dictionary = {}
    var moisture_map_index: Dictionary = {}
    var elevation_map_index: Dictionary = {}

    for z in range(height):
        for x in range(width):
            var tile_id = "%d:%d" % [x, z]
            var surface_noise_value = _sample_surface_noise(surface_noise, x, z, float(_config_value(config, "voxel_surface_smoothing", 0.35)))
            var normalized_surface = clampf((surface_noise_value + 1.0) * 0.5, 0.0, 1.0)
            var tectonic = clampf((tectonic_noise.get_noise_2d(float(x + 7), float(z - 9)) + 1.0) * 0.5, 0.0, 1.0)
            var continental = clampf((continental_noise.get_noise_2d(float(x - 17), float(z + 13)) + 1.0) * 0.5, 0.0, 1.0)
            var island_bias = _island_bias(x, z, width, height, continental, tectonic)
            normalized_surface = clampf(normalized_surface * 0.46 + tectonic * 0.24 + island_bias * 0.52 - 0.18, 0.0, 1.0)
            var moisture = clampf((biome_noise.get_noise_2d(float(x + 31), float(z - 17)) + 1.0) * 0.5, 0.0, 1.0)
            var latitude = absf(((float(z) / float(maxi(1, height - 1))) * 2.0) - 1.0)
            var temperature_noise = clampf((temp_noise.get_noise_2d(float(x - 11), float(z + 23)) + 1.0) * 0.5, 0.0, 1.0)
            var surface_y = _surface_height(normalized_surface, config, voxel_world_height)
            surface_y = clampi(surface_y + int(volcanic_delta_by_tile.get(tile_id, 0)), 1, voxel_world_height - 2)
            var elevation = clampf(float(surface_y) / float(maxi(1, voxel_world_height - 1)), 0.0, 1.0)
            var geothermal_activity = clampf((geothermal_noise.get_noise_2d(float(x + 47), float(z + 83)) + 1.0) * 0.5, 0.0, 1.0)
            geothermal_activity = clampf(geothermal_activity * 0.7 + _volcanic_influence(tile_id, volcanic_features) * 0.6, 0.0, 1.0)
            var aquifer_potential = clampf((aquifer_noise.get_noise_2d(float(x - 53), float(z + 29)) + 1.0) * 0.5, 0.0, 1.0)
            var temperature = clampf((1.0 - latitude) * 0.65 + temperature_noise * 0.35 - elevation * 0.25, 0.0, 1.0)
            moisture = clampf(moisture + float(_config_value(config, "progression_moisture_shift", 0.0)), 0.0, 1.0)
            temperature = clampf(temperature + float(_config_value(config, "progression_temperature_shift", 0.0)), 0.0, 1.0)
            temperature = clampf(temperature + geothermal_activity * 0.08, 0.0, 1.0)
            var slope = _estimate_slope(surface_noise, x, z)

            var tile_resource = WorldTileResourceScript.new()
            tile_resource.tile_id = tile_id
            tile_resource.x = x
            tile_resource.y = z
            tile_resource.elevation = elevation
            tile_resource.moisture = moisture
            tile_resource.temperature = temperature
            tile_resource.slope = slope
            tile_resource.biome = _classify_biome(elevation, moisture, temperature)

            var densities = _resource_densities(tile_resource.biome, config)
            tile_resource.food_density = float(densities.get("food_density", 0.3))
            tile_resource.wood_density = float(densities.get("wood_density", 0.3))
            tile_resource.stone_density = float(densities.get("stone_density", 0.3))

            var row = tile_resource.to_dict()
            row["tectonic_uplift"] = tectonic
            row["continentalness"] = continental
            row["islandness"] = island_bias
            row["geothermal_activity"] = geothermal_activity
            row["aquifer_potential"] = aquifer_potential
            tiles.append(row)
            tile_index[tile_id] = row
            height_map_index[tile_id] = surface_y
            moisture_map_index[tile_id] = moisture
            elevation_map_index[tile_id] = elevation
            var column_result = _build_voxel_column(
                x,
                z,
                surface_y,
                tile_resource.biome,
                moisture,
                temperature,
                geothermal_activity,
                voxel_world_height,
                config,
                cave_noise,
                ore_noise
            )
            voxel_columns.append(column_result.get("column", {}))
            var row_blocks: Array = column_result.get("blocks", [])
            for block_variant in row_blocks:
                block_rows.append(block_variant)
                var block: Dictionary = block_variant
                var block_type = String(block.get("type", BLOCK_AIR))
                block_type_counts[block_type] = int(block_type_counts.get(block_type, 0)) + 1

    var flow_map_resource = FlowMapResourceScript.new()
    flow_map_resource.from_dict(_bake_flow_map(width, height, height_map_index, moisture_map_index, elevation_map_index))
    var hydrogeo = _build_hydrogeology(tiles, tile_index, flow_map_resource.to_dict(), config, voxel_world_height)
    var springs: Dictionary = hydrogeo.get("springs", {})
    var water_table: Dictionary = hydrogeo.get("water_table", {})
    var water_table_rows: Array = hydrogeo.get("water_table_rows", [])

    var column_index_by_tile: Dictionary = {}
    for i in range(voxel_columns.size()):
        var column_variant = voxel_columns[i]
        if not (column_variant is Dictionary):
            continue
        var column = column_variant as Dictionary
        column_index_by_tile["%d:%d" % [int(column.get("x", 0)), int(column.get("z", 0))]] = i
    var chunk_row_index = _build_chunk_row_index(block_rows, 12)
    var packed_surface_y := PackedInt32Array()
    var packed_surface_albedo := PackedFloat32Array()
    packed_surface_y.resize(width * height)
    packed_surface_albedo.resize(width * height)
    for column_variant in voxel_columns:
        if not (column_variant is Dictionary):
            continue
        var column = column_variant as Dictionary
        var x = int(column.get("x", 0))
        var z = int(column.get("z", 0))
        var idx = z * width + x
        if idx < 0 or idx >= packed_surface_y.size():
            continue
        packed_surface_y[idx] = int(column.get("surface_y", 0))
        packed_surface_albedo[idx] = _albedo_from_rgba(column.get("top_block_rgba", [0.5, 0.5, 0.5, 1.0]))

    return {
        "schema_version": 1,
        "seed": seed,
        "simulated_year": simulated_year,
        "width": width,
        "height": height,
        "tiles": tiles,
        "tile_index": tile_index,
        "flow_map": flow_map_resource.to_dict(),
        "geology": {
            "schema_version": 1,
            "volcanic_features": volcanic_features,
            "plate_uplift_seed": seed + 3889,
            "continental_seed": seed + 3989,
        },
        "springs": springs,
        "water_table": {
            "schema_version": 1,
            "rows": water_table_rows,
            "row_index": water_table,
        },
        "voxel_world": {
            "schema_version": 1,
            "width": width,
            "depth": height,
            "height": voxel_world_height,
            "sea_level": int(config.voxel_sea_level),
            "columns": voxel_columns,
            "column_index_by_tile": column_index_by_tile,
            "block_rows": block_rows,
            "block_rows_by_chunk": chunk_row_index,
            "block_rows_chunk_size": 12,
            "block_type_counts": block_type_counts,
            "surface_y_buffer": packed_surface_y,
            "surface_albedo_buffer": packed_surface_albedo,
        }
    }

func rebake_flow_map(world: Dictionary) -> Dictionary:
    if world.is_empty():
        return {}
    var width = int(world.get("width", 0))
    var height = int(world.get("height", 0))
    if width <= 0 or height <= 0:
        return {}
    var tiles: Array = world.get("tiles", [])
    var columns: Array = (world.get("voxel_world", {}) as Dictionary).get("columns", [])
    var surface_by_tile: Dictionary = {}
    for column_variant in columns:
        if not (column_variant is Dictionary):
            continue
        var column = column_variant as Dictionary
        var tile_id = "%d:%d" % [int(column.get("x", 0)), int(column.get("z", 0))]
        surface_by_tile[tile_id] = int(column.get("surface_y", 0))
    var height_map_index: Dictionary = {}
    var moisture_map_index: Dictionary = {}
    var elevation_map_index: Dictionary = {}
    var world_height = maxi(1, int((world.get("voxel_world", {}) as Dictionary).get("height", 1)))
    for tile_variant in tiles:
        if not (tile_variant is Dictionary):
            continue
        var tile = tile_variant as Dictionary
        var tile_id = String(tile.get("tile_id", ""))
        if tile_id == "":
            continue
        var elev = clampf(float(tile.get("elevation", 0.0)), 0.0, 1.0)
        var moisture = clampf(float(tile.get("moisture", 0.0)), 0.0, 1.0)
        var surface_y = int(round(elev * float(maxi(1, world_height - 1))))
        if surface_by_tile.has(tile_id):
            surface_y = int(surface_by_tile[tile_id])
        height_map_index[tile_id] = surface_y
        moisture_map_index[tile_id] = moisture
        elevation_map_index[tile_id] = elev
    return _bake_flow_map(width, height, height_map_index, moisture_map_index, elevation_map_index)

func _build_noise(seed: int, frequency: float, octaves: int, lacunarity: float = 2.0, gain: float = 0.5) -> FastNoiseLite:
    var noise = FastNoiseLite.new()
    noise.seed = seed
    noise.frequency = maxf(0.001, frequency)
    noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    noise.fractal_type = FastNoiseLite.FRACTAL_FBM
    noise.fractal_octaves = maxi(1, octaves)
    noise.fractal_lacunarity = clampf(lacunarity, 1.1, 4.0)
    noise.fractal_gain = clampf(gain, 0.05, 1.0)
    return noise

func _sample_surface_noise(surface_noise: FastNoiseLite, x: int, z: int, smoothing: float) -> float:
    var smooth = clampf(smoothing, 0.0, 1.0)
    var center = surface_noise.get_noise_2d(float(x), float(z))
    if smooth <= 0.001:
        return center
    var east = surface_noise.get_noise_2d(float(x + 1), float(z))
    var west = surface_noise.get_noise_2d(float(x - 1), float(z))
    var north = surface_noise.get_noise_2d(float(x), float(z + 1))
    var south = surface_noise.get_noise_2d(float(x), float(z - 1))
    var average = (center + east + west + north + south) / 5.0
    return lerpf(center, average, smooth)

func _surface_height(surface_value: float, config, voxel_world_height: int) -> int:
    var base_height = clampi(int(config.voxel_surface_height_base), 1, voxel_world_height - 2)
    var height_range = maxi(1, int(config.voxel_surface_height_range))
    var max_surface = voxel_world_height - 2
    var surface = base_height + int(round(surface_value * float(height_range)))
    return clampi(surface, 1, max_surface)

func _estimate_slope(surface_noise: FastNoiseLite, x: int, z: int) -> float:
    var center = surface_noise.get_noise_2d(float(x), float(z))
    var east = surface_noise.get_noise_2d(float(x + 1), float(z))
    var south = surface_noise.get_noise_2d(float(x), float(z + 1))
    return clampf(absf(center - east) + absf(center - south), 0.0, 1.0)

func _build_voxel_column(
    x: int,
    z: int,
    surface_y: int,
    biome: String,
    moisture: float,
    temperature: float,
    geothermal_activity: float,
    voxel_world_height: int,
    config,
    cave_noise: FastNoiseLite,
    ore_noise: FastNoiseLite
) -> Dictionary:
    var blocks: Array = []
    var top_block = _surface_block_for(biome, moisture, temperature, geothermal_activity)
    var subsoil_block = _subsoil_block_for(biome, moisture, geothermal_activity)
    var stone_layers = 0
    var water_layers = 0
    var resource_counts = {
        "coal_ore": 0,
        "copper_ore": 0,
        "iron_ore": 0,
    }

    for y in range(surface_y + 1):
        var cave_value = cave_noise.get_noise_3d(float(x), float(y), float(z))
        var can_carve_cave = y > 1 and y < surface_y - 1
        if can_carve_cave and cave_value > float(config.cave_noise_threshold):
            continue
        var block_type = BLOCK_STONE
        if y == surface_y:
            block_type = top_block
        elif y >= surface_y - 2:
            block_type = subsoil_block
        else:
            block_type = _underground_block(x, y, z, ore_noise, geothermal_activity, config)
            if block_type == BLOCK_STONE or block_type == BLOCK_GRAVEL:
                stone_layers += 1
            elif block_type == BLOCK_COAL_ORE:
                resource_counts["coal_ore"] = int(resource_counts.get("coal_ore", 0)) + 1
            elif block_type == BLOCK_COPPER_ORE:
                resource_counts["copper_ore"] = int(resource_counts.get("copper_ore", 0)) + 1
            elif block_type == BLOCK_IRON_ORE:
                resource_counts["iron_ore"] = int(resource_counts.get("iron_ore", 0)) + 1
        blocks.append({"x": x, "y": y, "z": z, "type": block_type})

    var sea_level = clampi(int(config.voxel_sea_level), 1, voxel_world_height - 1)
    if surface_y < sea_level:
        for y in range(surface_y + 1, sea_level + 1):
            blocks.append({"x": x, "y": y, "z": z, "type": BLOCK_WATER})
            water_layers += 1

    return {
        "column": {
            "x": x,
            "z": z,
            "surface_y": surface_y,
            "top_block": top_block,
            "top_block_rgba": _block_color_rgba(top_block),
            "subsoil_block": subsoil_block,
            "stone_layers": stone_layers,
            "water_layers": water_layers,
            "resource_counts": resource_counts,
        },
        "blocks": blocks,
    }

func _surface_block_for(biome: String, moisture: float, temperature: float, geothermal_activity: float = 0.0) -> String:
    if geothermal_activity > 0.74 and moisture < 0.55:
        return BLOCK_OBSIDIAN
    if geothermal_activity > 0.62:
        return BLOCK_BASALT
    if biome == "highland" and temperature < 0.3:
        return BLOCK_SNOW
    if moisture < 0.24:
        return BLOCK_SAND
    if moisture > 0.7:
        return BLOCK_CLAY
    return BLOCK_GRASS

func _subsoil_block_for(biome: String, moisture: float, geothermal_activity: float = 0.0) -> String:
    if geothermal_activity > 0.58:
        return BLOCK_BASALT
    if biome == "highland":
        return BLOCK_GRAVEL
    if moisture > 0.68:
        return BLOCK_CLAY
    if moisture < 0.22:
        return BLOCK_SAND
    return BLOCK_DIRT

func _underground_block(x: int, y: int, z: int, ore_noise: FastNoiseLite, geothermal_activity: float, config) -> String:
    var ore_value = ore_noise.get_noise_3d(float(x), float(y), float(z))
    if geothermal_activity > 0.66 and y > 4 and y < 24 and ore_value > 0.48:
        return BLOCK_BASALT
    if y <= 8 and ore_value > float(config.iron_ore_threshold):
        return BLOCK_IRON_ORE
    if y <= 14 and ore_value > float(config.copper_ore_threshold):
        return BLOCK_COPPER_ORE
    if y <= 20 and ore_value > float(config.coal_ore_threshold):
        return BLOCK_COAL_ORE
    if y <= 4:
        return BLOCK_GRAVEL
    return BLOCK_STONE

func _block_color_rgba(block_type: String) -> Array:
    match block_type:
        BLOCK_GRASS:
            return [0.28, 0.63, 0.2, 1.0]
        BLOCK_DIRT:
            return [0.46, 0.31, 0.2, 1.0]
        BLOCK_CLAY:
            return [0.58, 0.48, 0.42, 1.0]
        BLOCK_SAND:
            return [0.8, 0.74, 0.51, 1.0]
        BLOCK_SNOW:
            return [0.9, 0.94, 0.98, 1.0]
        BLOCK_STONE:
            return [0.45, 0.45, 0.47, 1.0]
        BLOCK_GRAVEL:
            return [0.52, 0.5, 0.48, 1.0]
        BLOCK_BASALT:
            return [0.2, 0.2, 0.22, 1.0]
        BLOCK_OBSIDIAN:
            return [0.1, 0.08, 0.14, 1.0]
        BLOCK_COAL_ORE:
            return [0.22, 0.22, 0.22, 1.0]
        BLOCK_COPPER_ORE:
            return [0.66, 0.43, 0.25, 1.0]
        BLOCK_IRON_ORE:
            return [0.58, 0.47, 0.35, 1.0]
        BLOCK_WATER:
            return [0.18, 0.35, 0.76, 0.62]
        _:
            return [0.5, 0.5, 0.5, 1.0]

func _albedo_from_rgba(rgba_value) -> float:
    if rgba_value is Array and (rgba_value as Array).size() >= 3:
        var arr = rgba_value as Array
        var r = clampf(float(arr[0]), 0.0, 1.0)
        var g = clampf(float(arr[1]), 0.0, 1.0)
        var b = clampf(float(arr[2]), 0.0, 1.0)
        return clampf(r * 0.2126 + g * 0.7152 + b * 0.0722, 0.02, 0.95)
    return 0.35

func _bake_flow_map(
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

func _next_downhill_tile_id(tile_id: String, width: int, height: int, height_map: Dictionary) -> String:
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

func _classify_biome(elevation: float, moisture: float, temperature: float) -> String:
    if elevation > 0.78:
        return "highland"
    if moisture < 0.2 and temperature > 0.6:
        return "dry_steppe"
    if moisture > 0.65 and temperature > 0.45:
        return "wetland"
    if temperature < 0.3:
        return "cold_plain"
    if moisture > 0.52:
        return "woodland"
    return "plains"

func _resource_densities(biome: String, config = null) -> Dictionary:
    return _apply_progression_resource_multipliers(_base_resource_densities(biome), config)

func _base_resource_densities(biome: String) -> Dictionary:
    match biome:
        "highland":
            return {"food_density": 0.25, "wood_density": 0.22, "stone_density": 0.84}
        "dry_steppe":
            return {"food_density": 0.33, "wood_density": 0.18, "stone_density": 0.42}
        "wetland":
            return {"food_density": 0.8, "wood_density": 0.58, "stone_density": 0.24}
        "cold_plain":
            return {"food_density": 0.36, "wood_density": 0.4, "stone_density": 0.38}
        "woodland":
            return {"food_density": 0.62, "wood_density": 0.88, "stone_density": 0.32}
        _:
            return {"food_density": 0.52, "wood_density": 0.49, "stone_density": 0.36}

func _apply_progression_resource_multipliers(base: Dictionary, config) -> Dictionary:
    var food_mult = 1.0
    var wood_mult = 1.0
    var stone_mult = 1.0
    if config != null:
        food_mult = clampf(float(_config_value(config, "progression_food_density_multiplier", 1.0)), 0.1, 3.0)
        wood_mult = clampf(float(_config_value(config, "progression_wood_density_multiplier", 1.0)), 0.1, 3.0)
        stone_mult = clampf(float(_config_value(config, "progression_stone_density_multiplier", 1.0)), 0.1, 3.0)
    return {
        "food_density": clampf(float(base.get("food_density", 0.5)) * food_mult, 0.0, 1.0),
        "wood_density": clampf(float(base.get("wood_density", 0.5)) * wood_mult, 0.0, 1.0),
        "stone_density": clampf(float(base.get("stone_density", 0.5)) * stone_mult, 0.0, 1.0),
    }

func _config_value(config, key: String, default_value):
    if config == null:
        return default_value
    if config is Dictionary:
        return (config as Dictionary).get(key, default_value)
    var value = config.get(key)
    if value == null:
        return default_value
    return value

func _build_chunk_row_index(block_rows: Array, chunk_size: int) -> Dictionary:
    var size = maxi(4, chunk_size)
    var by_chunk: Dictionary = {}
    for row_variant in block_rows:
        if not (row_variant is Dictionary):
            continue
        var row = row_variant as Dictionary
        var x = int(row.get("x", 0))
        var z = int(row.get("z", 0))
        var cx = int(floor(float(x) / float(size)))
        var cz = int(floor(float(z) / float(size)))
        var key = "%d:%d" % [cx, cz]
        var rows: Array = by_chunk.get(key, [])
        rows.append(row)
        by_chunk[key] = rows
    return by_chunk

func _island_bias(x: int, z: int, width: int, height: int, continental: float, tectonic: float) -> float:
    var nx = 0.0
    var nz = 0.0
    if width > 1:
        nx = (float(x) / float(width - 1)) * 2.0 - 1.0
    if height > 1:
        nz = (float(z) / float(height - 1)) * 2.0 - 1.0
    var radial = clampf(1.0 - sqrt(nx * nx + nz * nz), 0.0, 1.0)
    var continental_lift = clampf((continental - 0.42) * 1.8, 0.0, 1.0)
    var hotspot_islands = clampf((tectonic - 0.62) * 2.4, 0.0, 1.0) * clampf((0.46 - continental) * 2.2, 0.0, 1.0)
    return clampf(radial * 0.58 + continental_lift * 0.32 + hotspot_islands * 0.58, 0.0, 1.0)

func _collect_volcanic_features(
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

func _build_volcanic_delta_index(width: int, height: int, features: Array, config) -> Dictionary:
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

func _volcanic_influence(tile_id: String, features: Array) -> float:
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

func _build_hydrogeology(tiles: Array, tile_index: Dictionary, flow_map: Dictionary, config, voxel_world_height: int) -> Dictionary:
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
