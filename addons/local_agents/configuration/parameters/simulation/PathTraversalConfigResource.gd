extends Resource
class_name LocalAgentsPathTraversalConfigResource

@export var schema_version: int = 1
@export var seasonal_modifiers_enabled: bool = true
@export var seasonal_cycle_ticks: int = 240
@export var wet_season_slowdown: float = 0.85
@export var dry_season_bonus: float = 1.05
@export var weather_modifiers_enabled: bool = true
@export var rain_slowdown_per_intensity: float = 0.25
@export var min_weather_multiplier: float = 0.7

func to_dict() -> Dictionary:
    return {
        "schema_version": schema_version,
        "seasonal_modifiers_enabled": seasonal_modifiers_enabled,
        "seasonal_cycle_ticks": seasonal_cycle_ticks,
        "wet_season_slowdown": wet_season_slowdown,
        "dry_season_bonus": dry_season_bonus,
        "weather_modifiers_enabled": weather_modifiers_enabled,
        "rain_slowdown_per_intensity": rain_slowdown_per_intensity,
        "min_weather_multiplier": min_weather_multiplier,
    }

func from_dict(values: Dictionary) -> void:
    schema_version = int(values.get("schema_version", schema_version))
    seasonal_modifiers_enabled = bool(values.get("seasonal_modifiers_enabled", seasonal_modifiers_enabled))
    seasonal_cycle_ticks = maxi(24, int(values.get("seasonal_cycle_ticks", seasonal_cycle_ticks)))
    wet_season_slowdown = clampf(float(values.get("wet_season_slowdown", wet_season_slowdown)), 0.4, 1.0)
    dry_season_bonus = clampf(float(values.get("dry_season_bonus", dry_season_bonus)), 1.0, 1.4)
    weather_modifiers_enabled = bool(values.get("weather_modifiers_enabled", weather_modifiers_enabled))
    rain_slowdown_per_intensity = clampf(float(values.get("rain_slowdown_per_intensity", rain_slowdown_per_intensity)), 0.0, 0.8)
    min_weather_multiplier = clampf(float(values.get("min_weather_multiplier", min_weather_multiplier)), 0.3, 1.0)
