extends RefCounted
class_name LocalAgentsWorldGenerator

const WorldTileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldTileResource.gd")
const FlowMapResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowMapResource.gd")
const BaseTerrainStage = preload("res://addons/local_agents/simulation/worldgen/WorldgenBaseTerrain.gd")
const BiomeMaterialStage = preload("res://addons/local_agents/simulation/worldgen/WorldgenBiomeMaterials.gd")
const ResourceDistributionStage = preload("res://addons/local_agents/simulation/worldgen/WorldgenResourceDistribution.gd")
const HydroVolcanicStage = preload("res://addons/local_agents/simulation/worldgen/WorldgenHydroVolcanic.gd")

func generate(seed: int, config) -> Dictionary:
    var width = int(config.map_width)
    var height = int(config.map_height)
    var simulated_year = float(_config_value(config, "simulated_year", -8000.0))
    var tiles: Array = []
    var tile_index: Dictionary = {}
    var voxel_world_height = maxi(8, int(config.voxel_world_height))

    var surface_noise = BaseTerrainStage.build_noise(
        seed + 1601,
        float(config.voxel_noise_frequency),
        int(config.voxel_noise_octaves),
        float(_config_value(config, "voxel_noise_lacunarity", 2.0)),
        float(_config_value(config, "voxel_noise_gain", 0.5))
    )
    var cave_noise = BaseTerrainStage.build_noise(seed + 2113, float(config.cave_noise_frequency), 3)
    var ore_noise = BaseTerrainStage.build_noise(seed + 2963, float(config.ore_noise_frequency), 2)
    var biome_noise = BaseTerrainStage.build_noise(seed + 3323, float(config.moisture_frequency), maxi(1, int(config.moisture_octaves)))
    var temp_noise = BaseTerrainStage.build_noise(seed + 3467, float(config.temperature_frequency), maxi(1, int(config.temperature_octaves)))
    var tectonic_noise = BaseTerrainStage.build_noise(seed + 3889, float(_config_value(config, "elevation_frequency", 0.135)) * 0.72, maxi(1, int(_config_value(config, "elevation_octaves", 3))), 2.35, 0.46)
    var continental_noise = BaseTerrainStage.build_noise(seed + 3989, float(_config_value(config, "elevation_frequency", 0.135)) * 0.32, maxi(2, int(_config_value(config, "elevation_octaves", 3))), 2.0, 0.52)
    var volcanic_noise = BaseTerrainStage.build_noise(seed + 4153, float(_config_value(config, "volcanic_noise_frequency", 0.028)), 2, 2.2, 0.58)
    var geothermal_noise = BaseTerrainStage.build_noise(seed + 4339, float(_config_value(config, "geothermal_noise_frequency", 0.041)), 3, 2.0, 0.57)
    var aquifer_noise = BaseTerrainStage.build_noise(seed + 4483, float(_config_value(config, "aquifer_noise_frequency", 0.047)), 3, 2.1, 0.54)

    var volcanic_features: Array = HydroVolcanicStage.collect_volcanic_features(width, height, voxel_world_height, volcanic_noise, continental_noise, config)
    var volcanic_delta_by_tile: Dictionary = HydroVolcanicStage.build_volcanic_delta_index(width, height, volcanic_features)

    var voxel_columns: Array = []
    var block_rows: Array = []
    var block_type_counts: Dictionary = {}
    var height_map_index: Dictionary = {}
    var moisture_map_index: Dictionary = {}
    var elevation_map_index: Dictionary = {}

    for z in range(height):
        for x in range(width):
            var tile_id = "%d:%d" % [x, z]
            var surface_noise_value = BaseTerrainStage.sample_surface_noise(surface_noise, x, z, float(_config_value(config, "voxel_surface_smoothing", 0.35)))
            var normalized_surface = clampf((surface_noise_value + 1.0) * 0.5, 0.0, 1.0)
            var tectonic = clampf((tectonic_noise.get_noise_2d(float(x + 7), float(z - 9)) + 1.0) * 0.5, 0.0, 1.0)
            var continental = clampf((continental_noise.get_noise_2d(float(x - 17), float(z + 13)) + 1.0) * 0.5, 0.0, 1.0)
            var island_bias = BaseTerrainStage.island_bias(x, z, width, height, continental, tectonic)
            normalized_surface = clampf(normalized_surface * 0.46 + tectonic * 0.24 + island_bias * 0.52 - 0.18, 0.0, 1.0)

            var moisture = clampf((biome_noise.get_noise_2d(float(x + 31), float(z - 17)) + 1.0) * 0.5, 0.0, 1.0)
            var latitude = absf(((float(z) / float(maxi(1, height - 1))) * 2.0) - 1.0)
            var temperature_noise = clampf((temp_noise.get_noise_2d(float(x - 11), float(z + 23)) + 1.0) * 0.5, 0.0, 1.0)
            var surface_y = BaseTerrainStage.surface_height(normalized_surface, config, voxel_world_height)
            surface_y = clampi(surface_y + int(volcanic_delta_by_tile.get(tile_id, 0)), 1, voxel_world_height - 2)
            var elevation = clampf(float(surface_y) / float(maxi(1, voxel_world_height - 1)), 0.0, 1.0)

            var geothermal_activity = clampf((geothermal_noise.get_noise_2d(float(x + 47), float(z + 83)) + 1.0) * 0.5, 0.0, 1.0)
            geothermal_activity = clampf(geothermal_activity * 0.7 + HydroVolcanicStage.volcanic_influence(tile_id, volcanic_features) * 0.6, 0.0, 1.0)
            var aquifer_potential = clampf((aquifer_noise.get_noise_2d(float(x - 53), float(z + 29)) + 1.0) * 0.5, 0.0, 1.0)
            var temperature = clampf((1.0 - latitude) * 0.65 + temperature_noise * 0.35 - elevation * 0.25, 0.0, 1.0)
            moisture = clampf(moisture + float(_config_value(config, "progression_moisture_shift", 0.0)), 0.0, 1.0)
            temperature = clampf(temperature + float(_config_value(config, "progression_temperature_shift", 0.0)), 0.0, 1.0)
            temperature = clampf(temperature + geothermal_activity * 0.08, 0.0, 1.0)
            var slope = BaseTerrainStage.estimate_slope(surface_noise, x, z)

            var tile_resource = WorldTileResourceScript.new()
            tile_resource.tile_id = tile_id
            tile_resource.x = x
            tile_resource.y = z
            tile_resource.elevation = elevation
            tile_resource.moisture = moisture
            tile_resource.temperature = temperature
            tile_resource.slope = slope
            tile_resource.biome = BiomeMaterialStage.classify_biome(elevation, moisture, temperature)

            var densities = ResourceDistributionStage.resource_densities(tile_resource.biome, config)
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

            var column_result = BiomeMaterialStage.build_voxel_column(
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
                var block_type = String(block.get("type", BiomeMaterialStage.BLOCK_AIR))
                block_type_counts[block_type] = int(block_type_counts.get(block_type, 0)) + 1

    var flow_map_resource = FlowMapResourceScript.new()
    flow_map_resource.from_dict(HydroVolcanicStage.bake_flow_map(width, height, height_map_index, moisture_map_index, elevation_map_index))
    var hydrogeo = HydroVolcanicStage.build_hydrogeology(tiles, tile_index, flow_map_resource.to_dict(), config, voxel_world_height)
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
        packed_surface_albedo[idx] = BiomeMaterialStage.albedo_from_rgba(column.get("top_block_rgba", [0.5, 0.5, 0.5, 1.0]))

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

    return HydroVolcanicStage.bake_flow_map(width, height, height_map_index, moisture_map_index, elevation_map_index)

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
