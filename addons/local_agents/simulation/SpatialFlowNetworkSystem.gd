extends RefCounted
class_name LocalAgentsSpatialFlowNetworkSystem

const FlowTraversalProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowTraversalProfileResource.gd")
const FlowFormationConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowFormationConfigResource.gd")
const FlowRuntimeConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowRuntimeConfigResource.gd")
const FlowNetworkResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowNetworkResource.gd")
const VoxelGridSystemScript = preload("res://addons/local_agents/simulation/VoxelGridSystem.gd")

var _edge_heat: Dictionary = {}
var _edge_strength: Dictionary = {}
var _traversal_profile = FlowTraversalProfileResourceScript.new()
var _formation_config = FlowFormationConfigResourceScript.new()
var _flow_runtime_config = FlowRuntimeConfigResourceScript.new()
var _tile_index: Dictionary = {}
var _water_tile_index: Dictionary = {}
var _voxel_grid = VoxelGridSystemScript.new()

func set_flow_profile(profile_resource) -> void:
	if profile_resource == null:
		_traversal_profile = FlowTraversalProfileResourceScript.new()
		return
	_traversal_profile = profile_resource

func set_flow_formation_config(config_resource) -> void:
	if config_resource == null:
		_formation_config = FlowFormationConfigResourceScript.new()
		return
	_formation_config = config_resource

func set_flow_runtime_config(config_resource) -> void:
	if config_resource == null:
		_flow_runtime_config = FlowRuntimeConfigResourceScript.new()
		return
	_flow_runtime_config = config_resource

func configure_environment(environment_snapshot: Dictionary, water_snapshot: Dictionary) -> void:
	_tile_index = _extract_tile_index(environment_snapshot)
	_water_tile_index = {}
	for tile_id_variant in water_snapshot.get("water_tiles", {}).keys():
		var tile_id = String(tile_id_variant)
		var row = water_snapshot.get("water_tiles", {}).get(tile_id, {})
		if row is Dictionary:
			_water_tile_index[tile_id] = (row as Dictionary).duplicate(true)
	_voxelize_world_bounds()

func step_decay() -> void:
	for key_variant in _edge_heat.keys():
		var key = String(key_variant)
		var next_heat = maxf(0.0, float(_edge_heat.get(key, 0.0)) - float(_formation_config.heat_decay_per_tick))
		if next_heat <= 0.0001:
			_edge_heat.erase(key)
		else:
			_edge_heat[key] = next_heat
	for key_variant in _edge_strength.keys():
		var key = String(key_variant)
		var next_strength = maxf(0.0, float(_edge_strength.get(key, 0.0)) - float(_formation_config.strength_decay_per_tick))
		if next_strength <= 0.0001:
			_edge_strength.erase(key)
		else:
			_edge_strength[key] = next_strength

func evaluate_route(start: Vector3, target: Vector3, context: Dictionary = {}) -> Dictionary:
	var delta = target - start
	delta.y = 0.0
	var planar_distance = maxf(0.01, delta.length())
	var avg_strength = _sample_path_strength(start, target)
	var roughness = _route_roughness(start, target)
	var terrain = _route_terrain_profile(start, target)
	var terrain_penalty = (
		float(terrain.get("brush", 0.0)) * float(_traversal_profile.brush_speed_penalty) +
		float(terrain.get("slope", 0.0)) * float(_traversal_profile.slope_speed_penalty) +
		float(terrain.get("shallow_water", 0.0)) * float(_traversal_profile.shallow_water_speed_penalty) +
		float(terrain.get("flood_risk", 0.0)) * float(_traversal_profile.floodplain_speed_penalty)
	)
	var speed_multiplier = clampf(
		float(_traversal_profile.base_speed_multiplier) +
		avg_strength * float(_traversal_profile.path_strength_speed_bonus) -
		roughness * float(_traversal_profile.roughness_speed_penalty) -
		terrain_penalty,
		float(_traversal_profile.min_speed_multiplier),
		float(_traversal_profile.max_speed_multiplier)
	)
	var seasonal_multiplier = _seasonal_multiplier(context)
	var weather_multiplier = _weather_multiplier(context)
	speed_multiplier *= seasonal_multiplier * weather_multiplier
	speed_multiplier = clampf(speed_multiplier, float(_traversal_profile.min_speed_multiplier), float(_traversal_profile.max_speed_multiplier))
	var travel_cost = planar_distance / speed_multiplier
	var efficiency = clampf(
		float(_traversal_profile.base_delivery_efficiency) +
		avg_strength * float(_traversal_profile.path_efficiency_bonus) -
		roughness * float(_traversal_profile.roughness_efficiency_penalty) -
		terrain_penalty * float(_traversal_profile.terrain_efficiency_penalty),
		float(_traversal_profile.min_delivery_efficiency),
		float(_traversal_profile.max_delivery_efficiency)
	)
	var eta_ticks = maxi(1, int(ceil(travel_cost / float(_traversal_profile.eta_divisor))))
	return {
		"distance": planar_distance,
		"avg_path_strength": avg_strength,
		"roughness": roughness,
		"terrain": terrain,
		"terrain_penalty": terrain_penalty,
		"seasonal_multiplier": seasonal_multiplier,
		"weather_multiplier": weather_multiplier,
		"speed_multiplier": speed_multiplier,
		"travel_cost": travel_cost,
		"delivery_efficiency": efficiency,
		"eta_ticks": eta_ticks,
	}

func record_flow(start: Vector3, target: Vector3, carry_weight: float) -> void:
	if carry_weight <= 0.0:
		return
	for edge_key in _route_edge_keys(start, target):
		var gain = carry_weight * float(_formation_config.heat_gain_per_weight)
		var next_heat = float(_edge_heat.get(edge_key, 0.0)) + gain
		_edge_heat[edge_key] = minf(float(_formation_config.max_heat), next_heat)
		var next_strength = float(_edge_strength.get(edge_key, 0.0)) + (gain * float(_formation_config.strength_gain_factor))
		_edge_strength[edge_key] = minf(float(_formation_config.max_strength), next_strength)

func export_network(max_edges: int = 96) -> Dictionary:
	var rows: Array = []
	for key_variant in _edge_heat.keys():
		var key = String(key_variant)
		rows.append({
			"edge": key,
			"heat": float(_edge_heat.get(key, 0.0)),
			"strength": float(_edge_strength.get(key, 0.0)),
		})
	rows.sort_custom(func(a, b):
		var ah = float(a.get("heat", 0.0))
		var bh = float(b.get("heat", 0.0))
		if is_equal_approx(ah, bh):
			return String(a.get("edge", "")) < String(b.get("edge", ""))
		return ah > bh
	)
	if rows.size() > max_edges:
		rows.resize(max_edges)
	var network = FlowNetworkResourceScript.new()
	network.from_dict({
		"schema_version": 1,
		"edges": rows,
		"edge_count": rows.size(),
	})
	return network.to_dict()

func import_network(payload: Dictionary) -> void:
	_edge_heat.clear()
	_edge_strength.clear()
	var rows: Array = payload.get("edges", [])
	for row_variant in rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var edge_key = String(row.get("edge", "")).strip_edges()
		if edge_key == "":
			continue
		_edge_heat[edge_key] = maxf(0.0, float(row.get("heat", 0.0)))
		_edge_strength[edge_key] = clampf(float(row.get("strength", 0.0)), 0.0, float(_formation_config.max_strength))

func _sample_path_strength(start: Vector3, target: Vector3) -> float:
	var keys = _route_edge_keys(start, target)
	if keys.is_empty():
		return 0.0
	var total = 0.0
	for edge_key in keys:
		total += float(_edge_strength.get(edge_key, 0.0))
	return clampf(total / float(keys.size()), 0.0, 1.0)

func _route_roughness(start: Vector3, target: Vector3) -> float:
	var mid = (start + target) * 0.5
	var mid_voxel = _voxel_grid.world_to_voxel(mid)
	if mid_voxel == _voxel_grid.invalid_voxel():
		return 0.0
	var v = sin(float(mid_voxel.x) * 0.19) * 0.55 + cos(float(mid_voxel.z) * 0.17) * 0.45
	return clampf(absf(v), 0.0, 1.0)

func _route_terrain_profile(start: Vector3, target: Vector3) -> Dictionary:
	var steps = maxi(1, int(ceil(start.distance_to(target) / 1.25)))
	var brush = 0.0
	var slope = 0.0
	var shallow_water = 0.0
	var flood_risk = 0.0
	for i in range(0, steps + 1):
		var t = float(i) / float(steps)
		var sample = start.lerp(target, t)
		var tile_id = _sample_tile_id(sample)
		var tile = _tile_index.get(tile_id, {})
		if tile is Dictionary:
			var tile_row = tile as Dictionary
			brush += clampf(float(tile_row.get("wood_density", 0.0)) * 0.8 + float(tile_row.get("moisture", 0.0)) * 0.2, 0.0, 1.0)
			slope += clampf(float(tile_row.get("slope", 0.0)), 0.0, 1.0)
		var water = _water_tile_index.get(tile_id, {})
		if water is Dictionary:
			var water_row = water as Dictionary
			var reliability = clampf(float(water_row.get("water_reliability", 0.0)), 0.0, 1.0)
			shallow_water += clampf(reliability, 0.0, 0.85)
			flood_risk += clampf(float(water_row.get("flood_risk", 0.0)), 0.0, 1.0)
	var denominator = float(steps + 1)
	return {
		"brush": brush / denominator,
		"slope": slope / denominator,
		"shallow_water": shallow_water / denominator,
		"flood_risk": flood_risk / denominator,
	}

func _route_edge_keys(start: Vector3, target: Vector3) -> Array:
	var keys: Array = []
	var steps = maxi(1, int(ceil(start.distance_to(target) / 1.25)))
	var prev_voxel = _voxel_grid.world_to_voxel(start)
	if prev_voxel == _voxel_grid.invalid_voxel():
		return keys
	for i in range(1, steps + 1):
		var t = float(i) / float(steps)
		var point = start.lerp(target, t)
		var voxel = _voxel_grid.world_to_voxel(point)
		if voxel == _voxel_grid.invalid_voxel() or voxel == prev_voxel:
			continue
		var left = "%d:%d" % [prev_voxel.x, prev_voxel.z]
		var right = "%d:%d" % [voxel.x, voxel.z]
		if left < right:
			keys.append(left + ">" + right)
		else:
			keys.append(right + ">" + left)
		prev_voxel = voxel
	keys.sort()
	var unique: Array = []
	var last = ""
	for key_variant in keys:
		var key = String(key_variant)
		if key == last:
			continue
		unique.append(key)
		last = key
	return unique

func _sample_tile_id(world_position: Vector3) -> String:
	var voxel = _voxel_grid.world_to_voxel(world_position)
	if voxel == _voxel_grid.invalid_voxel():
		return "0:0"
	return "%d:%d" % [voxel.x, voxel.z]

func _extract_tile_index(environment_snapshot: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var from_index: Dictionary = environment_snapshot.get("tile_index", {})
	for key_variant in from_index.keys():
		var tile_id = String(key_variant)
		var row = from_index.get(tile_id, {})
		if row is Dictionary:
			out[tile_id] = (row as Dictionary).duplicate(true)
	if out.is_empty():
		for row_variant in environment_snapshot.get("tiles", []):
			if not (row_variant is Dictionary):
				continue
			var row = row_variant as Dictionary
			var tile_id = "%d:%d" % [int(row.get("x", 0)), int(row.get("y", 0))]
			out[tile_id] = row.duplicate(true)
	return out

func _voxelize_world_bounds() -> void:
	var max_abs = 8.0
	for tile_id_variant in _tile_index.keys():
		var tile_id = String(tile_id_variant)
		var parts = tile_id.split(":")
		if parts.size() != 2:
			continue
		max_abs = maxf(max_abs, absf(float(parts[0])))
		max_abs = maxf(max_abs, absf(float(parts[1])))
	_voxel_grid.configure(max_abs + 2.0, 1.0, 1.0)

func _seasonal_multiplier(context: Dictionary) -> float:
	if not bool(_flow_runtime_config.seasonal_modifiers_enabled):
		return 1.0
	var tick = int(context.get("tick", 0))
	var cycle = maxi(24, int(_flow_runtime_config.seasonal_cycle_ticks))
	var phase = float(posmod(tick, cycle)) / float(cycle)
	if phase < 0.5:
		return clampf(float(_flow_runtime_config.dry_season_bonus), 0.5, 1.5)
	return clampf(float(_flow_runtime_config.wet_season_slowdown), 0.3, 1.0)

func _weather_multiplier(context: Dictionary) -> float:
	if not bool(_flow_runtime_config.weather_modifiers_enabled):
		return 1.0
	var rain_intensity = clampf(float(context.get("rain_intensity", 0.0)), 0.0, 1.0)
	return clampf(
		1.0 - rain_intensity * float(_flow_runtime_config.rain_slowdown_per_intensity),
		float(_flow_runtime_config.min_weather_multiplier),
		1.0
	)
