extends RefCounted

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

static func classify_biome(elevation: float, moisture: float, temperature: float) -> String:
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

static func build_voxel_column(
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
            "top_block_rgba": block_color_rgba(top_block),
            "subsoil_block": subsoil_block,
            "stone_layers": stone_layers,
            "water_layers": water_layers,
            "resource_counts": resource_counts,
        },
        "blocks": blocks,
    }

static func block_color_rgba(block_type: String) -> Array:
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

static func albedo_from_rgba(rgba_value) -> float:
    if rgba_value is Array and (rgba_value as Array).size() >= 3:
        var arr = rgba_value as Array
        var r = clampf(float(arr[0]), 0.0, 1.0)
        var g = clampf(float(arr[1]), 0.0, 1.0)
        var b = clampf(float(arr[2]), 0.0, 1.0)
        return clampf(r * 0.2126 + g * 0.7152 + b * 0.0722, 0.02, 0.95)
    return 0.35

static func _surface_block_for(biome: String, moisture: float, temperature: float, geothermal_activity: float = 0.0) -> String:
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

static func _subsoil_block_for(biome: String, moisture: float, geothermal_activity: float = 0.0) -> String:
    if geothermal_activity > 0.58:
        return BLOCK_BASALT
    if biome == "highland":
        return BLOCK_GRAVEL
    if moisture > 0.68:
        return BLOCK_CLAY
    if moisture < 0.22:
        return BLOCK_SAND
    return BLOCK_DIRT

static func _underground_block(x: int, y: int, z: int, ore_noise: FastNoiseLite, geothermal_activity: float, config) -> String:
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
