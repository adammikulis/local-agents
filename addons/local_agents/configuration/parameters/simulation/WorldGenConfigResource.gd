extends Resource
class_name LocalAgentsWorldGenConfigResource

@export var schema_version: int = 1
@export var map_width: int = 24
@export var map_height: int = 24
@export var elevation_frequency: float = 0.135
@export var elevation_octaves: int = 3
@export var moisture_frequency: float = 0.09
@export var moisture_octaves: int = 2
@export var temperature_frequency: float = 0.07
@export var temperature_octaves: int = 2
@export var spring_elevation_threshold: float = 0.64
@export var spring_moisture_threshold: float = 0.58
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
        "map_width": map_width,
        "map_height": map_height,
        "elevation_frequency": elevation_frequency,
        "elevation_octaves": elevation_octaves,
        "moisture_frequency": moisture_frequency,
        "moisture_octaves": moisture_octaves,
        "temperature_frequency": temperature_frequency,
        "temperature_octaves": temperature_octaves,
        "spring_elevation_threshold": spring_elevation_threshold,
        "spring_moisture_threshold": spring_moisture_threshold,
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
    map_width = maxi(4, int(values.get("map_width", map_width)))
    map_height = maxi(4, int(values.get("map_height", map_height)))
    elevation_frequency = maxf(0.001, float(values.get("elevation_frequency", elevation_frequency)))
    elevation_octaves = maxi(1, int(values.get("elevation_octaves", elevation_octaves)))
    moisture_frequency = maxf(0.001, float(values.get("moisture_frequency", moisture_frequency)))
    moisture_octaves = maxi(1, int(values.get("moisture_octaves", moisture_octaves)))
    temperature_frequency = maxf(0.001, float(values.get("temperature_frequency", temperature_frequency)))
    temperature_octaves = maxi(1, int(values.get("temperature_octaves", temperature_octaves)))
    spring_elevation_threshold = clampf(float(values.get("spring_elevation_threshold", spring_elevation_threshold)), 0.0, 1.0)
    spring_moisture_threshold = clampf(float(values.get("spring_moisture_threshold", spring_moisture_threshold)), 0.0, 1.0)
    flow_merge_threshold = maxf(0.0, float(values.get("flow_merge_threshold", flow_merge_threshold)))
    floodplain_flow_threshold = maxf(0.0, float(values.get("floodplain_flow_threshold", floodplain_flow_threshold)))
    spawn_weight_water_reliability = maxf(0.0, float(values.get("spawn_weight_water_reliability", spawn_weight_water_reliability)))
    spawn_weight_flood_penalty = maxf(0.0, float(values.get("spawn_weight_flood_penalty", spawn_weight_flood_penalty)))
    spawn_weight_food_density = maxf(0.0, float(values.get("spawn_weight_food_density", spawn_weight_food_density)))
    spawn_weight_wood_density = maxf(0.0, float(values.get("spawn_weight_wood_density", spawn_weight_wood_density)))
    spawn_weight_stone_density = maxf(0.0, float(values.get("spawn_weight_stone_density", spawn_weight_stone_density)))
    spawn_weight_walkability = maxf(0.0, float(values.get("spawn_weight_walkability", spawn_weight_walkability)))
    spawn_top_candidate_count = maxi(1, int(values.get("spawn_top_candidate_count", spawn_top_candidate_count)))
