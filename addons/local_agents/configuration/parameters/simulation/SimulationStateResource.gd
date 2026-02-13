extends Resource
class_name LocalAgentsSimulationStateResource

const WorldSnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldSnapshotResource.gd")
const HydrologySnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/HydrologySnapshotResource.gd")
const WeatherSnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WeatherSnapshotResource.gd")
const GeologySnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/GeologySnapshotResource.gd")
const SolarSnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/SolarSnapshotResource.gd")

@export var sim_tick: int = 0
@export var simulated_seconds: float = 0.0
@export var simulation_accumulator: float = 0.0
@export var active_branch_id: String = "main"
@export var landslide_count: int = 0
@export var solar_seed: int = 0
@export var world_snapshot: LocalAgentsWorldSnapshotResource = WorldSnapshotResourceScript.new()
@export var hydrology_snapshot: LocalAgentsHydrologySnapshotResource = HydrologySnapshotResourceScript.new()
@export var weather_snapshot: LocalAgentsWeatherSnapshotResource = WeatherSnapshotResourceScript.new()
@export var geology_snapshot: LocalAgentsGeologySnapshotResource = GeologySnapshotResourceScript.new()
@export var solar_snapshot: LocalAgentsSolarSnapshotResource = SolarSnapshotResourceScript.new()

func reset_runtime_state() -> void:
	sim_tick = 0
	simulated_seconds = 0.0
	simulation_accumulator = 0.0
	active_branch_id = "main"
	landslide_count = 0
	solar_seed = 0
	world_snapshot = WorldSnapshotResourceScript.new()
	hydrology_snapshot = HydrologySnapshotResourceScript.new()
	weather_snapshot = WeatherSnapshotResourceScript.new()
	geology_snapshot = GeologySnapshotResourceScript.new()
	solar_snapshot = SolarSnapshotResourceScript.new()
