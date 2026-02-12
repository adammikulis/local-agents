extends Resource
class_name LocalAgentsVoxelTimelapseSnapshotResource

@export var schema_version: int = 1
@export var tick: int = 0
@export var time_of_day: float = 0.0
@export var world: Dictionary = {}
@export var hydrology: Dictionary = {}
@export var weather: Dictionary = {}
@export var erosion: Dictionary = {}
@export var solar: Dictionary = {}

func to_dict() -> Dictionary:
	return {
		"schema_version": schema_version,
		"tick": tick,
		"time_of_day": time_of_day,
		"world": world.duplicate(true),
		"hydrology": hydrology.duplicate(true),
		"weather": weather.duplicate(true),
		"erosion": erosion.duplicate(true),
		"solar": solar.duplicate(true),
	}

func from_dict(values: Dictionary) -> void:
	schema_version = int(values.get("schema_version", schema_version))
	tick = int(values.get("tick", tick))
	time_of_day = clampf(float(values.get("time_of_day", time_of_day)), 0.0, 1.0)
	var world_variant = values.get("world", {})
	world = world_variant.duplicate(true) if world_variant is Dictionary else {}
	var hydrology_variant = values.get("hydrology", {})
	hydrology = hydrology_variant.duplicate(true) if hydrology_variant is Dictionary else {}
	var weather_variant = values.get("weather", {})
	weather = weather_variant.duplicate(true) if weather_variant is Dictionary else {}
	var erosion_variant = values.get("erosion", {})
	erosion = erosion_variant.duplicate(true) if erosion_variant is Dictionary else {}
	var solar_variant = values.get("solar", {})
	solar = solar_variant.duplicate(true) if solar_variant is Dictionary else {}

