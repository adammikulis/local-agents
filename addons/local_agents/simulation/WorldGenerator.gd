extends RefCounted
class_name LocalAgentsWorldGenerator

const WorldTileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldTileResource.gd")

func generate(seed: int, config) -> Dictionary:
    var width = int(config.map_width)
    var height = int(config.map_height)
    var tiles: Array = []
    var tile_index: Dictionary = {}

    for y in range(height):
        for x in range(width):
            var tile_id = "%d:%d" % [x, y]
            var elevation = _sample_octaves(seed + 101, x, y, config.elevation_frequency, config.elevation_octaves)
            var moisture = _sample_octaves(seed + 211, x, y, config.moisture_frequency, config.moisture_octaves)
            var latitude = absf(((float(y) / float(maxi(1, height - 1))) * 2.0) - 1.0)
            var temperature_noise = _sample_octaves(seed + 307, x, y, config.temperature_frequency, config.temperature_octaves)
            var temperature = clampf((1.0 - latitude) * 0.65 + temperature_noise * 0.35 - elevation * 0.25, 0.0, 1.0)
            var slope = _estimate_slope(seed + 101, x, y, config.elevation_frequency)

            var tile_resource = WorldTileResourceScript.new()
            tile_resource.tile_id = tile_id
            tile_resource.x = x
            tile_resource.y = y
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

    return {
        "schema_version": 1,
        "seed": seed,
        "width": width,
        "height": height,
        "tiles": tiles,
        "tile_index": tile_index,
    }

func _sample_octaves(seed: int, x: int, y: int, base_frequency: float, octaves: int) -> float:
    var value = 0.0
    var amplitude = 1.0
    var max_amplitude = 0.0
    var frequency = base_frequency
    for octave in range(maxi(1, octaves)):
        value += _sample_noise(seed + octave * 131, x, y, frequency) * amplitude
        max_amplitude += amplitude
        amplitude *= 0.5
        frequency *= 2.0
    if max_amplitude <= 0.0:
        return 0.0
    return clampf(value / max_amplitude, 0.0, 1.0)

func _sample_noise(seed: int, x: int, y: int, frequency: float) -> float:
    var xf = float(x)
    var yf = float(y)
    var sx = float(seed % 9973) * 0.000173
    var sy = float(seed % 8191) * 0.000211
    var wave = sin((xf + sx) * frequency * 8.0) + cos((yf - sy) * frequency * 7.25)
    var cross = sin((xf + yf + sx - sy) * frequency * 4.0)
    return clampf((wave * 0.32 + cross * 0.18) + 0.5, 0.0, 1.0)

func _estimate_slope(seed: int, x: int, y: int, frequency: float) -> float:
    var center = _sample_noise(seed, x, y, frequency)
    var east = _sample_noise(seed, x + 1, y, frequency)
    var south = _sample_noise(seed, x, y + 1, frequency)
    return clampf(absf(center - east) + absf(center - south), 0.0, 1.0)

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
