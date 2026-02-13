extends RefCounted
class_name LocalAgentsWorldSessionController

const SimulationStateResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/SimulationStateResource.gd")
const VoxelTimelapseSnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/VoxelTimelapseSnapshotResource.gd")

signal session_generated(seed_text: String, seed: int)
signal snapshot_recorded(tick: int)
signal snapshot_restored(tick: int)

var state: LocalAgentsSimulationStateResource = SimulationStateResourceScript.new()
var timelapse_snapshots: Dictionary = {}

func reset_for_new_world() -> void:
	state.reset_runtime_state()
	timelapse_snapshots.clear()

func set_world_snapshot(world: Dictionary) -> void:
	state.world_snapshot.set_from_dictionary(world, state.sim_tick)
	state.geology_snapshot.set_from_dictionary(world.get("geology", {}), state.sim_tick)

func set_hydrology_snapshot(hydrology: Dictionary) -> void:
	state.hydrology_snapshot.set_from_dictionary(hydrology, state.sim_tick)

func set_weather_snapshot(weather: Dictionary) -> void:
	state.weather_snapshot.set_from_dictionary(weather, state.sim_tick)

func set_solar_snapshot(solar: Dictionary, seed: int = -1) -> void:
	state.solar_snapshot.set_from_dictionary(solar, state.sim_tick)
	if seed >= 0:
		state.solar_seed = seed

func world_snapshot() -> Dictionary:
	return state.world_snapshot.to_dictionary()

func hydrology_snapshot() -> Dictionary:
	return state.hydrology_snapshot.to_dictionary()

func weather_snapshot() -> Dictionary:
	return state.weather_snapshot.to_dictionary()

func geology_snapshot() -> Dictionary:
	return state.geology_snapshot.to_dictionary()

func solar_snapshot() -> Dictionary:
	return state.solar_snapshot.to_dictionary()

func advance_tick(tick_duration: float) -> void:
	state.sim_tick += 1
	state.simulated_seconds += maxf(0.0, tick_duration)

func record_snapshot(time_of_day: float) -> void:
	var snapshot_resource = VoxelTimelapseSnapshotResourceScript.new()
	snapshot_resource.tick = state.sim_tick
	snapshot_resource.time_of_day = time_of_day
	snapshot_resource.simulated_seconds = state.simulated_seconds
	snapshot_resource.world = world_snapshot()
	snapshot_resource.hydrology = hydrology_snapshot()
	snapshot_resource.weather = weather_snapshot()
	snapshot_resource.erosion = {}
	snapshot_resource.solar = solar_snapshot()
	timelapse_snapshots[state.sim_tick] = snapshot_resource
	emit_signal("snapshot_recorded", state.sim_tick)

func restore_snapshot(target_tick: int) -> Dictionary:
	if timelapse_snapshots.is_empty():
		return {}
	var keys = timelapse_snapshots.keys()
	keys.sort()
	var selected_tick = int(keys[0])
	for key_variant in keys:
		var tick = int(key_variant)
		if tick <= target_tick:
			selected_tick = tick
		else:
			break
	var snapshot_variant = timelapse_snapshots.get(selected_tick, null)
	if snapshot_variant == null:
		return {}
	var snapshot_dict: Dictionary = {}
	if snapshot_variant is Resource and snapshot_variant.has_method("to_dict"):
		snapshot_dict = snapshot_variant.to_dict()
	elif snapshot_variant is Dictionary:
		snapshot_dict = (snapshot_variant as Dictionary).duplicate(true)
	if snapshot_dict.is_empty():
		return {}
	state.sim_tick = int(snapshot_dict.get("tick", selected_tick))
	state.simulated_seconds = float(snapshot_dict.get("simulated_seconds", 0.0))
	set_world_snapshot(snapshot_dict.get("world", {}))
	set_hydrology_snapshot(snapshot_dict.get("hydrology", {}))
	set_weather_snapshot(snapshot_dict.get("weather", {}))
	set_solar_snapshot(snapshot_dict.get("solar", {}), int(snapshot_dict.get("solar", {}).get("seed", 0)))
	emit_signal("snapshot_restored", state.sim_tick)
	return snapshot_dict
