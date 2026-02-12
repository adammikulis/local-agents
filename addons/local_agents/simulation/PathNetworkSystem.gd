extends RefCounted
class_name LocalAgentsPathNetworkSystem

var _edge_heat: Dictionary = {}
var _edge_strength: Dictionary = {}
var _heat_decay_per_tick: float = 0.015
var _strength_decay_per_tick: float = 0.004
var _heat_gain_per_weight: float = 0.065
var _strength_gain_factor: float = 0.075

func step_decay() -> void:
	for key_variant in _edge_heat.keys():
		var key = String(key_variant)
		var next_heat = maxf(0.0, float(_edge_heat.get(key, 0.0)) - _heat_decay_per_tick)
		if next_heat <= 0.0001:
			_edge_heat.erase(key)
		else:
			_edge_heat[key] = next_heat
	for key_variant in _edge_strength.keys():
		var key = String(key_variant)
		var next_strength = maxf(0.0, float(_edge_strength.get(key, 0.0)) - _strength_decay_per_tick)
		if next_strength <= 0.0001:
			_edge_strength.erase(key)
		else:
			_edge_strength[key] = next_strength

func route_profile(start: Vector3, target: Vector3) -> Dictionary:
	var delta = target - start
	delta.y = 0.0
	var planar_distance = maxf(0.01, delta.length())
	var avg_strength = _sample_path_strength(start, target)
	var roughness = _route_roughness(start, target)
	var speed_multiplier = clampf(0.72 + avg_strength * 0.95 - roughness * 0.22, 0.35, 1.85)
	var travel_cost = planar_distance / speed_multiplier
	var efficiency = clampf(0.52 + avg_strength * 0.34 - roughness * 0.12, 0.22, 0.99)
	var eta_ticks = maxi(1, int(ceil(travel_cost / 1.8)))
	return {
		"distance": planar_distance,
		"avg_path_strength": avg_strength,
		"roughness": roughness,
		"speed_multiplier": speed_multiplier,
		"travel_cost": travel_cost,
		"delivery_efficiency": efficiency,
		"eta_ticks": eta_ticks,
	}

func record_traversal(start: Vector3, target: Vector3, carry_weight: float) -> void:
	if carry_weight <= 0.0:
		return
	for edge_key in _route_edge_keys(start, target):
		var gain = carry_weight * _heat_gain_per_weight
		var next_heat = float(_edge_heat.get(edge_key, 0.0)) + gain
		_edge_heat[edge_key] = minf(8.0, next_heat)
		var next_strength = float(_edge_strength.get(edge_key, 0.0)) + (gain * _strength_gain_factor)
		_edge_strength[edge_key] = minf(1.0, next_strength)

func snapshot(max_edges: int = 96) -> Dictionary:
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
	return {
		"schema_version": 1,
		"edges": rows,
		"edge_count": rows.size(),
	}

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
	var v = sin(mid.x * 0.19) * 0.55 + cos(mid.z * 0.17) * 0.45
	return clampf(absf(v), 0.0, 1.0)

func _route_edge_keys(start: Vector3, target: Vector3) -> Array:
	var keys: Array = []
	var steps = maxi(1, int(ceil(start.distance_to(target) / 1.25)))
	var prev = start
	for i in range(1, steps + 1):
		var t = float(i) / float(steps)
		var point = start.lerp(target, t)
		var a = Vector2i(int(round(prev.x)), int(round(prev.z)))
		var b = Vector2i(int(round(point.x)), int(round(point.z)))
		if a == b:
			prev = point
			continue
		var left = "%d:%d" % [a.x, a.y]
		var right = "%d:%d" % [b.x, b.y]
		if left < right:
			keys.append(left + ">" + right)
		else:
			keys.append(right + ">" + left)
		prev = point
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
