extends Resource
class_name LocalAgentsFlowTraversalProfileResource

@export var schema_version: int = 1
@export var base_speed_multiplier: float = 0.72
@export var path_strength_speed_bonus: float = 0.95
@export var roughness_speed_penalty: float = 0.22
@export var brush_speed_penalty: float = 0.42
@export var slope_speed_penalty: float = 0.48
@export var shallow_water_speed_penalty: float = 0.33
@export var floodplain_speed_penalty: float = 0.25
@export var min_speed_multiplier: float = 0.25
@export var max_speed_multiplier: float = 1.85
@export var base_delivery_efficiency: float = 0.52
@export var path_efficiency_bonus: float = 0.34
@export var roughness_efficiency_penalty: float = 0.12
@export var terrain_efficiency_penalty: float = 0.22
@export var min_delivery_efficiency: float = 0.15
@export var max_delivery_efficiency: float = 0.99
@export var eta_divisor: float = 1.8

func to_dict() -> Dictionary:
    return {
        "schema_version": schema_version,
        "base_speed_multiplier": base_speed_multiplier,
        "path_strength_speed_bonus": path_strength_speed_bonus,
        "roughness_speed_penalty": roughness_speed_penalty,
        "brush_speed_penalty": brush_speed_penalty,
        "slope_speed_penalty": slope_speed_penalty,
        "shallow_water_speed_penalty": shallow_water_speed_penalty,
        "floodplain_speed_penalty": floodplain_speed_penalty,
        "min_speed_multiplier": min_speed_multiplier,
        "max_speed_multiplier": max_speed_multiplier,
        "base_delivery_efficiency": base_delivery_efficiency,
        "path_efficiency_bonus": path_efficiency_bonus,
        "roughness_efficiency_penalty": roughness_efficiency_penalty,
        "terrain_efficiency_penalty": terrain_efficiency_penalty,
        "min_delivery_efficiency": min_delivery_efficiency,
        "max_delivery_efficiency": max_delivery_efficiency,
        "eta_divisor": eta_divisor,
    }

func from_dict(values: Dictionary) -> void:
    schema_version = int(values.get("schema_version", schema_version))
    base_speed_multiplier = clampf(float(values.get("base_speed_multiplier", base_speed_multiplier)), 0.05, 3.0)
    path_strength_speed_bonus = clampf(float(values.get("path_strength_speed_bonus", path_strength_speed_bonus)), 0.0, 3.0)
    roughness_speed_penalty = clampf(float(values.get("roughness_speed_penalty", roughness_speed_penalty)), 0.0, 2.0)
    brush_speed_penalty = clampf(float(values.get("brush_speed_penalty", brush_speed_penalty)), 0.0, 2.0)
    slope_speed_penalty = clampf(float(values.get("slope_speed_penalty", slope_speed_penalty)), 0.0, 2.0)
    shallow_water_speed_penalty = clampf(float(values.get("shallow_water_speed_penalty", shallow_water_speed_penalty)), 0.0, 2.0)
    floodplain_speed_penalty = clampf(float(values.get("floodplain_speed_penalty", floodplain_speed_penalty)), 0.0, 2.0)
    min_speed_multiplier = clampf(float(values.get("min_speed_multiplier", min_speed_multiplier)), 0.05, 2.0)
    max_speed_multiplier = clampf(float(values.get("max_speed_multiplier", max_speed_multiplier)), min_speed_multiplier, 4.0)
    base_delivery_efficiency = clampf(float(values.get("base_delivery_efficiency", base_delivery_efficiency)), 0.05, 1.0)
    path_efficiency_bonus = clampf(float(values.get("path_efficiency_bonus", path_efficiency_bonus)), 0.0, 1.0)
    roughness_efficiency_penalty = clampf(float(values.get("roughness_efficiency_penalty", roughness_efficiency_penalty)), 0.0, 1.0)
    terrain_efficiency_penalty = clampf(float(values.get("terrain_efficiency_penalty", terrain_efficiency_penalty)), 0.0, 1.0)
    min_delivery_efficiency = clampf(float(values.get("min_delivery_efficiency", min_delivery_efficiency)), 0.05, 1.0)
    max_delivery_efficiency = clampf(float(values.get("max_delivery_efficiency", max_delivery_efficiency)), min_delivery_efficiency, 1.0)
    eta_divisor = maxf(0.1, float(values.get("eta_divisor", eta_divisor)))
