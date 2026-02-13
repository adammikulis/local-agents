extends Resource
class_name LocalAgentsWorldGenConfigResource

@export var schema_version: int = 1
@export var simulated_year: float = -8000.0
@export var progression_profile_id: String = "default"
@export var progression_temperature_shift: float = 0.0
@export var progression_moisture_shift: float = 0.0
@export var progression_food_density_multiplier: float = 1.0
@export var progression_wood_density_multiplier: float = 1.0
@export var progression_stone_density_multiplier: float = 1.0
@export var map_width: int = 24
@export var map_height: int = 24
@export var voxel_world_height: int = 36
@export var voxel_sea_level: int = 11
@export var voxel_surface_height_base: int = 8
@export var voxel_surface_height_range: int = 10
@export var voxel_noise_frequency: float = 0.055
@export var voxel_noise_octaves: int = 4
@export var voxel_noise_lacunarity: float = 1.85
@export var voxel_noise_gain: float = 0.42
@export var voxel_surface_smoothing: float = 0.48
@export var cave_noise_frequency: float = 0.09
@export var cave_noise_threshold: float = 0.57
@export var ore_noise_frequency: float = 0.12
@export var coal_ore_threshold: float = 0.62
@export var copper_ore_threshold: float = 0.66
@export var iron_ore_threshold: float = 0.7
@export var elevation_frequency: float = 0.135
@export var elevation_octaves: int = 3
@export var moisture_frequency: float = 0.09
@export var moisture_octaves: int = 2
@export var temperature_frequency: float = 0.07
@export var temperature_octaves: int = 2
@export var spring_elevation_threshold: float = 0.64
@export var spring_moisture_threshold: float = 0.58
@export var volcanic_noise_frequency: float = 0.028
@export var volcanic_threshold: float = 0.76
@export var volcanic_radius_min: int = 2
@export var volcanic_radius_max: int = 5
@export var volcanic_cone_height: float = 6.0
@export var volcanic_crater_depth: float = 2.0
@export var geothermal_noise_frequency: float = 0.041
@export var aquifer_noise_frequency: float = 0.047
@export var water_table_base_depth: float = 8.0
@export var water_table_elevation_factor: float = 9.0
@export var water_table_moisture_factor: float = 6.5
@export var water_table_flow_factor: float = 4.0
@export var water_table_aquifer_factor: float = 3.0
@export var spring_pressure_threshold: float = 0.52
@export var spring_max_depth: float = 11.0
@export var hot_spring_geothermal_threshold: float = 0.62
@export var cold_spring_temperature_threshold: float = 0.56
@export var spring_discharge_base: float = 1.15
@export var flow_merge_threshold: float = 2.0
@export var floodplain_flow_threshold: float = 3.0
@export var spawn_weight_water_reliability: float = 6.0
@export var spawn_weight_flood_penalty: float = 3.0
@export var spawn_weight_food_density: float = 2.25
@export var spawn_weight_wood_density: float = 1.65
@export var spawn_weight_stone_density: float = 1.1
@export var spawn_weight_walkability: float = 1.4
@export var spawn_top_candidate_count: int = 8

func to_dict() -> Dictionary:
    return {
        "schema_version": schema_version,
        "simulated_year": simulated_year,
        "progression_profile_id": progression_profile_id,
        "progression_temperature_shift": progression_temperature_shift,
        "progression_moisture_shift": progression_moisture_shift,
        "progression_food_density_multiplier": progression_food_density_multiplier,
        "progression_wood_density_multiplier": progression_wood_density_multiplier,
        "progression_stone_density_multiplier": progression_stone_density_multiplier,
        "map_width": map_width,
        "map_height": map_height,
        "voxel_world_height": voxel_world_height,
        "voxel_sea_level": voxel_sea_level,
        "voxel_surface_height_base": voxel_surface_height_base,
        "voxel_surface_height_range": voxel_surface_height_range,
        "voxel_noise_frequency": voxel_noise_frequency,
        "voxel_noise_octaves": voxel_noise_octaves,
        "voxel_noise_lacunarity": voxel_noise_lacunarity,
        "voxel_noise_gain": voxel_noise_gain,
        "voxel_surface_smoothing": voxel_surface_smoothing,
        "cave_noise_frequency": cave_noise_frequency,
        "cave_noise_threshold": cave_noise_threshold,
        "ore_noise_frequency": ore_noise_frequency,
        "coal_ore_threshold": coal_ore_threshold,
        "copper_ore_threshold": copper_ore_threshold,
        "iron_ore_threshold": iron_ore_threshold,
        "elevation_frequency": elevation_frequency,
        "elevation_octaves": elevation_octaves,
        "moisture_frequency": moisture_frequency,
        "moisture_octaves": moisture_octaves,
        "temperature_frequency": temperature_frequency,
        "temperature_octaves": temperature_octaves,
        "spring_elevation_threshold": spring_elevation_threshold,
        "spring_moisture_threshold": spring_moisture_threshold,
        "volcanic_noise_frequency": volcanic_noise_frequency,
        "volcanic_threshold": volcanic_threshold,
        "volcanic_radius_min": volcanic_radius_min,
        "volcanic_radius_max": volcanic_radius_max,
        "volcanic_cone_height": volcanic_cone_height,
        "volcanic_crater_depth": volcanic_crater_depth,
        "geothermal_noise_frequency": geothermal_noise_frequency,
        "aquifer_noise_frequency": aquifer_noise_frequency,
        "water_table_base_depth": water_table_base_depth,
        "water_table_elevation_factor": water_table_elevation_factor,
        "water_table_moisture_factor": water_table_moisture_factor,
        "water_table_flow_factor": water_table_flow_factor,
        "water_table_aquifer_factor": water_table_aquifer_factor,
        "spring_pressure_threshold": spring_pressure_threshold,
        "spring_max_depth": spring_max_depth,
        "hot_spring_geothermal_threshold": hot_spring_geothermal_threshold,
        "cold_spring_temperature_threshold": cold_spring_temperature_threshold,
        "spring_discharge_base": spring_discharge_base,
        "flow_merge_threshold": flow_merge_threshold,
        "floodplain_flow_threshold": floodplain_flow_threshold,
        "spawn_weight_water_reliability": spawn_weight_water_reliability,
        "spawn_weight_flood_penalty": spawn_weight_flood_penalty,
        "spawn_weight_food_density": spawn_weight_food_density,
        "spawn_weight_wood_density": spawn_weight_wood_density,
        "spawn_weight_stone_density": spawn_weight_stone_density,
        "spawn_weight_walkability": spawn_weight_walkability,
        "spawn_top_candidate_count": spawn_top_candidate_count,
    }

func from_dict(values: Dictionary) -> void:
    schema_version = int(values.get("schema_version", schema_version))
    simulated_year = float(values.get("simulated_year", simulated_year))
    progression_profile_id = String(values.get("progression_profile_id", progression_profile_id)).strip_edges()
    if progression_profile_id == "":
        progression_profile_id = "default"
    progression_temperature_shift = clampf(float(values.get("progression_temperature_shift", progression_temperature_shift)), -0.5, 0.5)
    progression_moisture_shift = clampf(float(values.get("progression_moisture_shift", progression_moisture_shift)), -0.5, 0.5)
    progression_food_density_multiplier = clampf(float(values.get("progression_food_density_multiplier", progression_food_density_multiplier)), 0.1, 3.0)
    progression_wood_density_multiplier = clampf(float(values.get("progression_wood_density_multiplier", progression_wood_density_multiplier)), 0.1, 3.0)
    progression_stone_density_multiplier = clampf(float(values.get("progression_stone_density_multiplier", progression_stone_density_multiplier)), 0.1, 3.0)
    map_width = maxi(4, int(values.get("map_width", map_width)))
    map_height = maxi(4, int(values.get("map_height", map_height)))
    voxel_world_height = maxi(8, int(values.get("voxel_world_height", voxel_world_height)))
    voxel_sea_level = clampi(int(values.get("voxel_sea_level", voxel_sea_level)), 1, voxel_world_height - 2)
    voxel_surface_height_base = clampi(int(values.get("voxel_surface_height_base", voxel_surface_height_base)), 1, voxel_world_height - 2)
    voxel_surface_height_range = maxi(1, int(values.get("voxel_surface_height_range", voxel_surface_height_range)))
    voxel_noise_frequency = maxf(0.001, float(values.get("voxel_noise_frequency", voxel_noise_frequency)))
    voxel_noise_octaves = maxi(1, int(values.get("voxel_noise_octaves", voxel_noise_octaves)))
    voxel_noise_lacunarity = clampf(float(values.get("voxel_noise_lacunarity", voxel_noise_lacunarity)), 1.1, 4.0)
    voxel_noise_gain = clampf(float(values.get("voxel_noise_gain", voxel_noise_gain)), 0.05, 1.0)
    voxel_surface_smoothing = clampf(float(values.get("voxel_surface_smoothing", voxel_surface_smoothing)), 0.0, 1.0)
    cave_noise_frequency = maxf(0.001, float(values.get("cave_noise_frequency", cave_noise_frequency)))
    cave_noise_threshold = clampf(float(values.get("cave_noise_threshold", cave_noise_threshold)), -0.95, 0.95)
    ore_noise_frequency = maxf(0.001, float(values.get("ore_noise_frequency", ore_noise_frequency)))
    coal_ore_threshold = clampf(float(values.get("coal_ore_threshold", coal_ore_threshold)), -0.95, 0.95)
    copper_ore_threshold = clampf(float(values.get("copper_ore_threshold", copper_ore_threshold)), -0.95, 0.95)
    iron_ore_threshold = clampf(float(values.get("iron_ore_threshold", iron_ore_threshold)), -0.95, 0.95)
    elevation_frequency = maxf(0.001, float(values.get("elevation_frequency", elevation_frequency)))
    elevation_octaves = maxi(1, int(values.get("elevation_octaves", elevation_octaves)))
    moisture_frequency = maxf(0.001, float(values.get("moisture_frequency", moisture_frequency)))
    moisture_octaves = maxi(1, int(values.get("moisture_octaves", moisture_octaves)))
    temperature_frequency = maxf(0.001, float(values.get("temperature_frequency", temperature_frequency)))
    temperature_octaves = maxi(1, int(values.get("temperature_octaves", temperature_octaves)))
    spring_elevation_threshold = clampf(float(values.get("spring_elevation_threshold", spring_elevation_threshold)), 0.0, 1.0)
    spring_moisture_threshold = clampf(float(values.get("spring_moisture_threshold", spring_moisture_threshold)), 0.0, 1.0)
    volcanic_noise_frequency = maxf(0.001, float(values.get("volcanic_noise_frequency", volcanic_noise_frequency)))
    volcanic_threshold = clampf(float(values.get("volcanic_threshold", volcanic_threshold)), 0.0, 1.0)
    volcanic_radius_min = maxi(1, int(values.get("volcanic_radius_min", volcanic_radius_min)))
    volcanic_radius_max = maxi(volcanic_radius_min, int(values.get("volcanic_radius_max", volcanic_radius_max)))
    volcanic_cone_height = clampf(float(values.get("volcanic_cone_height", volcanic_cone_height)), 0.0, 48.0)
    volcanic_crater_depth = clampf(float(values.get("volcanic_crater_depth", volcanic_crater_depth)), 0.0, 24.0)
    geothermal_noise_frequency = maxf(0.001, float(values.get("geothermal_noise_frequency", geothermal_noise_frequency)))
    aquifer_noise_frequency = maxf(0.001, float(values.get("aquifer_noise_frequency", aquifer_noise_frequency)))
    water_table_base_depth = clampf(float(values.get("water_table_base_depth", water_table_base_depth)), 0.0, 64.0)
    water_table_elevation_factor = clampf(float(values.get("water_table_elevation_factor", water_table_elevation_factor)), 0.0, 64.0)
    water_table_moisture_factor = clampf(float(values.get("water_table_moisture_factor", water_table_moisture_factor)), 0.0, 64.0)
    water_table_flow_factor = clampf(float(values.get("water_table_flow_factor", water_table_flow_factor)), 0.0, 64.0)
    water_table_aquifer_factor = clampf(float(values.get("water_table_aquifer_factor", water_table_aquifer_factor)), 0.0, 64.0)
    spring_pressure_threshold = clampf(float(values.get("spring_pressure_threshold", spring_pressure_threshold)), 0.0, 1.0)
    spring_max_depth = clampf(float(values.get("spring_max_depth", spring_max_depth)), 0.0, 64.0)
    hot_spring_geothermal_threshold = clampf(float(values.get("hot_spring_geothermal_threshold", hot_spring_geothermal_threshold)), 0.0, 1.0)
    cold_spring_temperature_threshold = clampf(float(values.get("cold_spring_temperature_threshold", cold_spring_temperature_threshold)), 0.0, 1.0)
    spring_discharge_base = clampf(float(values.get("spring_discharge_base", spring_discharge_base)), 0.01, 16.0)
    flow_merge_threshold = maxf(0.0, float(values.get("flow_merge_threshold", flow_merge_threshold)))
    floodplain_flow_threshold = maxf(0.0, float(values.get("floodplain_flow_threshold", floodplain_flow_threshold)))
    spawn_weight_water_reliability = maxf(0.0, float(values.get("spawn_weight_water_reliability", spawn_weight_water_reliability)))
    spawn_weight_flood_penalty = maxf(0.0, float(values.get("spawn_weight_flood_penalty", spawn_weight_flood_penalty)))
    spawn_weight_food_density = maxf(0.0, float(values.get("spawn_weight_food_density", spawn_weight_food_density)))
    spawn_weight_wood_density = maxf(0.0, float(values.get("spawn_weight_wood_density", spawn_weight_wood_density)))
    spawn_weight_stone_density = maxf(0.0, float(values.get("spawn_weight_stone_density", spawn_weight_stone_density)))
    spawn_weight_walkability = maxf(0.0, float(values.get("spawn_weight_walkability", spawn_weight_walkability)))
    spawn_top_candidate_count = maxi(1, int(values.get("spawn_top_candidate_count", spawn_top_candidate_count)))
