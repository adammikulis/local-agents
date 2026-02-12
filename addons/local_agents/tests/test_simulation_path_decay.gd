@tool
extends RefCounted

const SpatialFlowNetworkSystemScript = preload("res://addons/local_agents/simulation/SpatialFlowNetworkSystem.gd")
const FlowFormationConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowFormationConfigResource.gd")

func run_test(_tree: SceneTree) -> bool:
	var config = FlowFormationConfigResourceScript.new()
	config.heat_gain_per_weight = 0.25
	config.strength_gain_factor = 0.18
	config.heat_decay_per_tick = 0.08
	config.strength_decay_per_tick = 0.05

	var a = SpatialFlowNetworkSystemScript.new()
	var b = SpatialFlowNetworkSystemScript.new()
	a.set_flow_formation_config(config)
	b.set_flow_formation_config(config)

	var start = Vector3(1.0, 0.0, 1.0)
	var target = Vector3(8.0, 0.0, 1.0)
	for _i in range(0, 12):
		a.record_flow(start, target, 0.9)
		b.record_flow(start, target, 0.9)

	var active_a: Dictionary = a.export_network()
	var active_b: Dictionary = b.export_network()
	if active_a != active_b:
		push_error("Path network snapshot should be deterministic after traversals")
		return false

	var first_edge = _first_edge(active_a)
	if first_edge.is_empty():
		push_error("Expected at least one path edge after traversal")
		return false
	var heat_before = float(first_edge.get("heat", 0.0))
	var strength_before = float(first_edge.get("strength", 0.0))

	for _j in range(0, 6):
		a.step_decay()
		b.step_decay()

	var decayed_a: Dictionary = a.export_network()
	var decayed_b: Dictionary = b.export_network()
	if decayed_a != decayed_b:
		push_error("Path network decay should remain deterministic")
		return false

	var edge_after = _first_edge(decayed_a)
	if edge_after.is_empty():
		push_error("Expected decayed edge to remain present after limited decay steps")
		return false
	var heat_after = float(edge_after.get("heat", 0.0))
	var strength_after = float(edge_after.get("strength", 0.0))
	if heat_after >= heat_before:
		push_error("Expected heat to decay after step_decay calls")
		return false
	if strength_after >= strength_before:
		push_error("Expected strength to decay after step_decay calls")
		return false

	for _k in range(0, 4):
		a.record_flow(start, target, 0.8)
	var recovered = _first_edge(a.export_network())
	if float(recovered.get("strength", 0.0)) <= strength_after:
		push_error("Expected strength recovery after additional traversal")
		return false

	print("Path decay deterministic test passed")
	return true

func _first_edge(snapshot: Dictionary) -> Dictionary:
	var rows: Array = snapshot.get("edges", [])
	if rows.is_empty():
		return {}
	var edge = rows[0]
	if edge is Dictionary:
		return edge
	return {}
