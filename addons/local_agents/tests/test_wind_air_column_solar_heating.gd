@tool
extends RefCounted

const WindFieldSystemScript = preload("res://addons/local_agents/simulation/WindFieldSystem.gd")

func run_test(_tree: SceneTree) -> bool:
	var wind = WindFieldSystemScript.new()
	wind.configure(6.0, 0.5, 3.0)
	wind.set_global_wind(Vector3(1.0, 0.0, 0.0), 0.2, 1.0)
	var sample_pos = Vector3(0.0, 1.5, 0.0)
	var baseline = wind.sample_temperature(sample_pos)
	for _i in range(12):
		wind.step(0.2, 0.5, 0.0, 0.0, {
			"sun_altitude": 1.0,
			"avg_insolation": 1.0,
			"avg_uv_index": 1.6,
			"avg_heat_load": 1.2,
			"air_heating_scalar": 1.0,
		})
	var heated = wind.sample_temperature(sample_pos)
	if not (heated > baseline + 0.01):
		push_error("Expected solar forcing to heat upper air voxels")
		return false
	print("Wind air-column solar heating test passed.")
	return true
