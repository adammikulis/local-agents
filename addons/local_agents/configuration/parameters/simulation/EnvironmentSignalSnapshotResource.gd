extends Resource
class_name LocalAgentsEnvironmentSignalSnapshotResource

@export var schema_version: int = 1
@export var tick: int = 0
@export var environment_snapshot: Dictionary = {}
@export var water_network_snapshot: Dictionary = {}
@export var weather_snapshot: Dictionary = {}
@export var erosion_snapshot: Dictionary = {}
@export var solar_snapshot: Dictionary = {}
@export var erosion_changed: bool = false
@export var erosion_changed_tiles: Array = []

func to_dict() -> Dictionary:
	return {
		"schema_version": schema_version,
		"tick": tick,
		"environment_snapshot": environment_snapshot.duplicate(true),
		"water_network_snapshot": water_network_snapshot.duplicate(true),
		"weather_snapshot": weather_snapshot.duplicate(true),
		"erosion_snapshot": erosion_snapshot.duplicate(true),
		"solar_snapshot": solar_snapshot.duplicate(true),
		"erosion_changed": erosion_changed,
		"erosion_changed_tiles": erosion_changed_tiles.duplicate(true),
	}

func from_dict(values: Dictionary) -> void:
	schema_version = int(values.get("schema_version", schema_version))
	tick = int(values.get("tick", tick))
	var env_variant = values.get("environment_snapshot", {})
	environment_snapshot = env_variant.duplicate(true) if env_variant is Dictionary else {}
	var water_variant = values.get("water_network_snapshot", {})
	water_network_snapshot = water_variant.duplicate(true) if water_variant is Dictionary else {}
	var weather_variant = values.get("weather_snapshot", {})
	weather_snapshot = weather_variant.duplicate(true) if weather_variant is Dictionary else {}
	var erosion_variant = values.get("erosion_snapshot", {})
	erosion_snapshot = erosion_variant.duplicate(true) if erosion_variant is Dictionary else {}
	var solar_variant = values.get("solar_snapshot", {})
	solar_snapshot = solar_variant.duplicate(true) if solar_variant is Dictionary else {}
	erosion_changed = bool(values.get("erosion_changed", erosion_changed))
	var changed_variant = values.get("erosion_changed_tiles", [])
	erosion_changed_tiles = changed_variant.duplicate(true) if changed_variant is Array else []

