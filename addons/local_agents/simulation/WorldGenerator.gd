extends RefCounted
class_name LocalAgentsWorldGenerator

const WorldTileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldTileResource.gd")
const BLOCK_AIR := "air"
const BLOCK_GRASS := "grass"
const BLOCK_DIRT := "dirt"
const BLOCK_CLAY := "clay"
const BLOCK_SAND := "sand"
const BLOCK_SNOW := "snow"
const BLOCK_STONE := "stone"
const BLOCK_GRAVEL := "gravel"
const BLOCK_COAL_ORE := "coal_ore"
const BLOCK_COPPER_ORE := "copper_ore"
const BLOCK_IRON_ORE := "iron_ore"
const BLOCK_WATER := "water"

func generate(seed: int, config) -> Dictionary:
    var width = int(config.map_width)
    var height = int(config.map_height)
    var tiles: Array = []
    var tile_index: Dictionary = {}
    var voxel_world_height = maxi(8, int(config.voxel_world_height))
    var surface_noise = _build_noise(seed + 1601, float(config.voxel_noise_frequency), int(config.voxel_noise_octaves))
    var cave_noise = _build_noise(seed + 2113, float(config.cave_noise_frequency), 3)
    var ore_noise = _build_noise(seed + 2963, float(config.ore_noise_frequency), 2)
    var biome_noise = _build_noise(seed + 3323, float(config.moisture_frequency), maxi(1, int(config.moisture_octaves)))
    var temp_noise = _build_noise(seed + 3467, float(config.temperature_frequency), maxi(1, int(config.temperature_octaves)))

    var voxel_columns: Array = []
    var block_rows: Array = []
    var block_type_counts: Dictionary = {}

    for z in range(height):
        for x in range(width):
            var tile_id = "%d:%d" % [x, z]
            var surface_noise_value = surface_noise.get_noise_2d(float(x), float(z))
            var normalized_surface = clampf((surface_noise_value + 1.0) * 0.5, 0.0, 1.0)
            var moisture = clampf((biome_noise.get_noise_2d(float(x + 31), float(z - 17)) + 1.0) * 0.5, 0.0, 1.0)
            var latitude = absf(((float(z) / float(maxi(1, height - 1))) * 2.0) - 1.0)
            var temperature_noise = clampf((temp_noise.get_noise_2d(float(x - 11), float(z + 23)) + 1.0) * 0.5, 0.0, 1.0)
            var surface_y = _surface_height(normalized_surface, config, voxel_world_height)
            var elevation = clampf(float(surface_y) / float(maxi(1, voxel_world_height - 1)), 0.0, 1.0)
            var temperature = clampf((1.0 - latitude) * 0.65 + temperature_noise * 0.35 - elevation * 0.25, 0.0, 1.0)
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

            var densities = _resource_densities(tile_resource.biome)
            tile_resource.food_density = float(densities.get("food_density", 0.3))
            tile_resource.wood_density = float(densities.get("wood_density", 0.3))
            tile_resource.stone_density = float(densities.get("stone_density", 0.3))

            var row = tile_resource.to_dict()
            tiles.append(row)
            tile_index[tile_id] = row
            var column_result = _build_voxel_column(
                x,
                z,
                surface_y,
                tile_resource.biome,
                moisture,
                temperature,
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

    return {
        "schema_version": 1,
        "seed": seed,
        "width": width,
        "height": height,
        "tiles": tiles,
        "tile_index": tile_index,
        "voxel_world": {
            "schema_version": 1,
            "width": width,
            "depth": height,
            "height": voxel_world_height,
            "sea_level": int(config.voxel_sea_level),
            "columns": voxel_columns,
            "block_rows": block_rows,
            "block_type_counts": block_type_counts,
        }
    }

func _build_noise(seed: int, frequency: float, octaves: int) -> FastNoiseLite:
    var noise = FastNoiseLite.new()
    noise.seed = seed
    noise.frequency = maxf(0.001, frequency)
    noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    noise.fractal_type = FastNoiseLite.FRACTAL_FBM
    noise.fractal_octaves = maxi(1, octaves)
    noise.fractal_lacunarity = 2.0
    noise.fractal_gain = 0.5
    return noise

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
    voxel_world_height: int,
    config,
    cave_noise: FastNoiseLite,
    ore_noise: FastNoiseLite
) -> Dictionary:
    var blocks: Array = []
    var top_block = _surface_block_for(biome, moisture, temperature)
    var subsoil_block = _subsoil_block_for(biome, moisture)
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
            block_type = _underground_block(x, y, z, ore_noise, config)
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
            "subsoil_block": subsoil_block,
            "stone_layers": stone_layers,
            "water_layers": water_layers,
            "resource_counts": resource_counts,
        },
        "blocks": blocks,
    }

func _surface_block_for(biome: String, moisture: float, temperature: float) -> String:
    if biome == "highland" and temperature < 0.3:
        return BLOCK_SNOW
    if moisture < 0.24:
        return BLOCK_SAND
    if moisture > 0.7:
        return BLOCK_CLAY
    return BLOCK_GRASS

func _subsoil_block_for(biome: String, moisture: float) -> String:
    if biome == "highland":
        return BLOCK_GRAVEL
    if moisture > 0.68:
        return BLOCK_CLAY
    if moisture < 0.22:
        return BLOCK_SAND
    return BLOCK_DIRT

func _underground_block(x: int, y: int, z: int, ore_noise: FastNoiseLite, config) -> String:
    var ore_value = ore_noise.get_noise_3d(float(x), float(y), float(z))
    if y <= 8 and ore_value > float(config.iron_ore_threshold):
        return BLOCK_IRON_ORE
    if y <= 14 and ore_value > float(config.copper_ore_threshold):
        return BLOCK_COPPER_ORE
    if y <= 20 and ore_value > float(config.coal_ore_threshold):
        return BLOCK_COAL_ORE
    if y <= 4:
        return BLOCK_GRAVEL
    return BLOCK_STONE

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

func _resource_densities(biome: String) -> Dictionary:
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
