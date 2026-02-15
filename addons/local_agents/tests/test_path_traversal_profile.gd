@tool
extends RefCounted

const SpatialFlowNetworkSystemScript = preload("res://addons/local_agents/simulation/SpatialFlowNetworkSystem.gd")
const FlowTraversalProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowTraversalProfileResource.gd")

func run_test(_tree: SceneTree) -> bool:
	var profile = FlowTraversalProfileResourceScript.new()
	profile.brush_speed_penalty = 0.55
	profile.slope_speed_penalty = 0.6
	profile.shallow_water_speed_penalty = 0.45
	profile.floodplain_speed_penalty = 0.25
	profile.flow_with_speed_bonus = 0.22
	profile.flow_against_speed_penalty = 0.5
	profile.cross_flow_speed_penalty = 0.08
	profile.flow_efficiency_bonus = 0.1
	profile.flow_efficiency_penalty = 0.18

	var a = SpatialFlowNetworkSystemScript.new()
	var b = SpatialFlowNetworkSystemScript.new()
	a.set_flow_profile(profile)
	b.set_flow_profile(profile)

	var environment = _build_environment()
	var hydrology = _build_hydrology()
	a.configure_environment(environment, hydrology)
	b.configure_environment(environment, hydrology)

	var path_start = Vector3(2.0, 0.0, 2.0)
	var path_target = Vector3(12.0, 0.0, 2.0)
	var rough_target = Vector3(2.0, 0.0, 12.0)

	for _i in range(0, 64):
		a.record_flow(path_start, path_target, 0.9)
		b.record_flow(path_start, path_target, 0.9)

	var preferred = a.evaluate_route(path_start, path_target)
	var reverse = a.evaluate_route(path_target, path_start)
	var rough = a.evaluate_route(path_start, rough_target)
	var preferred_b = b.evaluate_route(path_start, path_target)
	var rough_b = b.evaluate_route(path_start, rough_target)
	var dry = a.evaluate_route(path_start, path_target, {"tick": 10, "stage_intensity": 0.0})
	var wet = a.evaluate_route(path_start, path_target, {"tick": 190, "stage_intensity": 0.0})

	if float(preferred.get("travel_cost", 9999.0)) >= float(rough.get("travel_cost", 0.0)):
		push_error("Expected established low-brush path route to be faster than rough route")
		return false
	if float(preferred.get("speed_multiplier", 0.0)) <= float(rough.get("speed_multiplier", 0.0)):
		push_error("Expected path speed multiplier to exceed rough route multiplier")
		return false
	if float(rough.get("terrain_penalty", 0.0)) <= float(preferred.get("terrain_penalty", 0.0)):
		push_error("Expected rough route terrain penalty to exceed preferred route penalty")
		return false
	if float(wet.get("travel_cost", 0.0)) <= float(dry.get("travel_cost", 0.0)):
		push_error("Expected wet-season traversal to be slower than dry-season traversal for same route")
		return false
	if float(wet.get("seasonal_multiplier", 1.0)) >= float(dry.get("seasonal_multiplier", 1.0)):
		push_error("Expected wet-season multiplier to be lower than dry-season multiplier")
		return false
	if float(preferred.get("speed_multiplier", 0.0)) <= float(reverse.get("speed_multiplier", 0.0)):
		push_error("Expected downstream-aligned traversal to be faster than upstream traversal")
		return false
	if float(preferred.get("travel_cost", 0.0)) >= float(reverse.get("travel_cost", 9999.0)):
		push_error("Expected downstream-aligned traversal to cost less than upstream traversal")
		return false

	if not _profiles_match(preferred, preferred_b):
		push_error("Traversal profile should be deterministic for preferred route")
		return false
	if not _profiles_match(rough, rough_b):
		push_error("Traversal profile should be deterministic for rough route")
		return false

	print("Path traversal profile test passed")
	return true

func _profiles_match(a: Dictionary, b: Dictionary) -> bool:
	for key in ["travel_cost", "speed_multiplier", "delivery_efficiency", "terrain_penalty", "eta_ticks"]:
		if not is_equal_approx(float(a.get(key, 0.0)), float(b.get(key, 0.0))):
			return false
	var ta: Dictionary = a.get("terrain", {})
	var tb: Dictionary = b.get("terrain", {})
	for key in ["brush", "slope", "shallow_water", "flood_risk"]:
		if not is_equal_approx(float(ta.get(key, 0.0)), float(tb.get(key, 0.0))):
			return false
	return true

func _build_environment() -> Dictionary:
	var tiles: Array = []
	var tile_index: Dictionary = {}
	for y in range(0, 16):
		for x in range(0, 16):
			var tile_id = "%d:%d" % [x, y]
			var row = {
				"x": x,
				"y": y,
				"tile_id": tile_id,
				"moisture": 0.3,
				"slope": 0.08,
				"wood_density": 0.15,
			}
			if y >= 8:
				row["moisture"] = 0.65
				row["slope"] = 0.62
				row["wood_density"] = 0.84
			tiles.append(row)
			tile_index[tile_id] = row
	return {
		"tiles": tiles,
		"tile_index": tile_index,
		"flow_map": _build_flow_map(),
	}

func _build_hydrology() -> Dictionary:
	var water_tiles: Dictionary = {}
	for y in range(8, 16):
		var tile_id = "2:%d" % y
		water_tiles[tile_id] = {
			"water_reliability": 0.72,
			"flood_risk": 0.48,
		}
	return {
		"water_tiles": water_tiles,
	}

func _build_flow_map() -> Dictionary:
	var rows: Array = []
	var row_index: Dictionary = {}
	for y in range(0, 16):
		for x in range(0, 16):
			var tile_id = "%d:%d" % [x, y]
			var channel_strength = 0.0
			var dir_x = 0
			var dir_y = 0
			if y == 2 and x >= 2 and x <= 12:
				channel_strength = 0.9
				dir_x = 1
			var row = {
				"tile_id": tile_id,
				"x": x,
				"y": y,
				"dir_x": dir_x,
				"dir_y": dir_y,
				"channel_strength": channel_strength,
			}
			rows.append(row)
			row_index[tile_id] = row
	return {
		"schema_version": 1,
		"width": 16,
		"height": 16,
		"rows": rows,
		"row_index": row_index,
	}
