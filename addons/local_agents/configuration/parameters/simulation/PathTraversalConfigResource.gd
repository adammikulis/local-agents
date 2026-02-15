extends Resource
class_name LocalAgentsPathTraversalConfigResource

@export var schema_version: int = 1
@export var seasonal_modifiers_enabled: bool = true
@export var seasonal_cycle_ticks: int = 240
@export var wet_season_slowdown: float = 0.85
@export var dry_season_bonus: float = 1.05
@export var transform_modifiers_enabled: bool = true
@export var stage_intensity_slowdown_per_unit: float = 0.25
@export var min_transform_multiplier: float = 0.7

func to_dict() -> Dictionary:
	return {
		"schema_version": schema_version,
		"seasonal_modifiers_enabled": seasonal_modifiers_enabled,
		"seasonal_cycle_ticks": seasonal_cycle_ticks,
		"wet_season_slowdown": wet_season_slowdown,
		"dry_season_bonus": dry_season_bonus,
		"transform_modifiers_enabled": transform_modifiers_enabled,
		"stage_intensity_slowdown_per_unit": stage_intensity_slowdown_per_unit,
		"min_transform_multiplier": min_transform_multiplier,
	}

func from_dict(values: Dictionary) -> void:
    schema_version = int(values.get("schema_version", schema_version))
    seasonal_modifiers_enabled = bool(values.get("seasonal_modifiers_enabled", seasonal_modifiers_enabled))
    seasonal_cycle_ticks = maxi(24, int(values.get("seasonal_cycle_ticks", seasonal_cycle_ticks)))
    wet_season_slowdown = clampf(float(values.get("wet_season_slowdown", wet_season_slowdown)), 0.4, 1.0)
    dry_season_bonus = clampf(float(values.get("dry_season_bonus", dry_season_bonus)), 1.0, 1.4)
	transform_modifiers_enabled = bool(values.get("transform_modifiers_enabled", transform_modifiers_enabled))
	stage_intensity_slowdown_per_unit = clampf(float(values.get("stage_intensity_slowdown_per_unit", stage_intensity_slowdown_per_unit)), 0.0, 0.8)
	min_transform_multiplier = clampf(float(values.get("min_transform_multiplier", min_transform_multiplier)), 0.3, 1.0)
