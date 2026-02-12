@tool
extends RefCounted

const SolarExposureSystemScript = preload("res://addons/local_agents/simulation/SolarExposureSystem.gd")

func run_test(_tree: SceneTree) -> bool:
	var solar = SolarExposureSystemScript.new()
	var environment := _build_environment()
	var setup: Dictionary = solar.configure_environment(environment, 9911)
	if not bool(setup.get("ok", false)):
		push_error("Solar setup failed for albedo RGBA test")
		return false

	var weather := {
		"avg_cloud_cover": 0.0,
		"avg_rain_intensity": 0.0,
		"avg_humidity": 0.3,
		"avg_fog_intensity": 0.0,
		"tile_index": {
			"0:0": {"cloud": 0.0, "rain": 0.0, "humidity": 0.3, "fog": 0.0},
			"1:0": {"cloud": 0.0, "rain": 0.0, "humidity": 0.3, "fog": 0.0},
		},
	}
	var snapshot: Dictionary = {}
	for tick in range(6, 15):
		snapshot = solar.step(tick, 1.0, environment, weather)
	var index: Dictionary = snapshot.get("tile_index", {})
	var dark_row: Dictionary = index.get("0:0", {})
	var light_row: Dictionary = index.get("1:0", {})
	if dark_row.is_empty() or light_row.is_empty():
		push_error("Missing tiles in solar albedo snapshot")
		return false
	var dark_albedo = float(dark_row.get("surface_albedo", -1.0))
	var light_albedo = float(light_row.get("surface_albedo", -1.0))
	var dark_absorbed = float(dark_row.get("sunlight_absorbed", -1.0))
	var light_absorbed = float(light_row.get("sunlight_absorbed", -1.0))
	var dark_reflected = float(dark_row.get("sunlight_reflected", -1.0))
	var light_reflected = float(light_row.get("sunlight_reflected", -1.0))
	if not (dark_albedo < light_albedo):
		push_error("Expected darker RGBA tile to have lower albedo")
		return false
	if not (dark_absorbed > light_absorbed):
		push_error("Expected darker RGBA tile to absorb more sunlight")
		return false
	if not (dark_reflected < light_reflected):
		push_error("Expected lighter RGBA tile to reflect more sunlight")
		return false
	print("Solar albedo RGBA test passed.")
	return true

func _build_environment() -> Dictionary:
	var tile_dark = {
		"tile_id": "0:0",
		"x": 0,
		"y": 0,
		"elevation": 0.45,
		"moisture": 0.4,
		"temperature": 0.5,
		"slope": 0.2,
	}
	var tile_light = {
		"tile_id": "1:0",
		"x": 1,
		"y": 0,
		"elevation": 0.45,
		"moisture": 0.4,
		"temperature": 0.5,
		"slope": 0.2,
	}
	return {
		"width": 2,
		"height": 1,
		"tiles": [tile_dark, tile_light],
		"tile_index": {"0:0": tile_dark.duplicate(true), "1:0": tile_light.duplicate(true)},
		"voxel_world": {
			"columns": [
				{"x": 0, "z": 0, "surface_y": 8, "top_block": "coal_ore", "top_block_rgba": [0.22, 0.22, 0.22, 1.0]},
				{"x": 1, "z": 0, "surface_y": 8, "top_block": "snow", "top_block_rgba": [0.9, 0.94, 0.98, 1.0]},
			]
		}
	}
