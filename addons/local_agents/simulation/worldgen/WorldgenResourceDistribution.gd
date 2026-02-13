extends RefCounted

static func resource_densities(biome: String, config = null) -> Dictionary:
    return _apply_progression_resource_multipliers(_base_resource_densities(biome), config)

static func _base_resource_densities(biome: String) -> Dictionary:
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

static func _apply_progression_resource_multipliers(base: Dictionary, config) -> Dictionary:
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

static func _config_value(config, key: String, default_value):
    if config == null:
        return default_value
    if config is Dictionary:
        return (config as Dictionary).get(key, default_value)
    var value = config.get(key)
    if value == null:
        return default_value
    return value
