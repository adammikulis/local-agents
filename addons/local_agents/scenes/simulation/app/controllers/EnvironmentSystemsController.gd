extends RefCounted
class_name LocalAgentsEnvironmentSystemsController

const WorldGeneratorScript = preload("res://addons/local_agents/simulation/WorldGenerator.gd")
const HydrologySystemScript = preload("res://addons/local_agents/simulation/HydrologySystem.gd")
const WeatherSystemScript = preload("res://addons/local_agents/simulation/WeatherSystem.gd")
const ErosionSystemScript = preload("res://addons/local_agents/simulation/ErosionSystem.gd")
const SolarExposureSystemScript = preload("res://addons/local_agents/simulation/SolarExposureSystem.gd")

var world_generator = WorldGeneratorScript.new()
var hydrology_system = HydrologySystemScript.new()
var weather_system = WeatherSystemScript.new()
var erosion_system = ErosionSystemScript.new()
var solar_system = SolarExposureSystemScript.new()

func generate(seed: int, config: Resource) -> Dictionary:
	var world = world_generator.generate(seed, config)
	var hydrology = hydrology_system.build_network(world, config)
	return {"world": world, "hydrology": hydrology}

func configure(seed_text: String, world: Dictionary, hydrology: Dictionary) -> Dictionary:
	var weather_seed = int(hash("%s_weather" % seed_text))
	var erosion_seed = int(hash("%s_erosion" % seed_text))
	var solar_seed = int(hash("%s_solar" % seed_text))
	weather_system.configure_environment(world, hydrology, weather_seed)
	erosion_system.configure_environment(world, hydrology, erosion_seed)
	solar_system.configure_environment(world, solar_seed)
	return {
		"weather": weather_system.current_snapshot(0),
		"erosion": erosion_system.current_snapshot(0),
		"solar": solar_system.current_snapshot(0),
		"solar_seed": solar_seed,
	}

func rebake_hydrology(world: Dictionary, config: Resource) -> Dictionary:
	world["flow_map"] = world_generator.rebake_flow_map(world)
	return hydrology_system.build_network(world, config)
