@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const StateHasherScript = preload("res://addons/local_agents/simulation/SimulationStateHasher.gd")

func run_test(tree: SceneTree) -> bool:
	var a = SimulationControllerScript.new()
	var b = SimulationControllerScript.new()
	tree.get_root().add_child(a)
	tree.get_root().add_child(b)

	a.configure("seed-path-logistics", false, false)
	b.configure("seed-path-logistics", false, false)
	a.set_cognition_features(false, false, false)
	b.set_cognition_features(false, false, false)

	a.register_villager("npc_p1", "PathOne", {"household_id": "home_p1"})
	a.register_villager("npc_p2", "PathTwo", {"household_id": "home_p1"})
	b.register_villager("npc_p1", "PathOne", {"household_id": "home_p1"})
	b.register_villager("npc_p2", "PathTwo", {"household_id": "home_p1"})

	var hasher = StateHasherScript.new()
	var hashes_a: Array = []
	var hashes_b: Array = []
	var saw_path_edges := false
	var saw_partial := false

	for tick in range(1, 73):
		var ra: Dictionary = a.process_tick(tick, 1.0)
		var rb: Dictionary = b.process_tick(tick, 1.0)
		hashes_a.append(hasher.hash_state(ra))
		hashes_b.append(hasher.hash_state(rb))
		var state: Dictionary = ra.get("state", {})
		var path_network: Dictionary = state.get("path_network", {})
		if int(path_network.get("edge_count", 0)) > 0:
			saw_path_edges = true
		if int(state.get("partial_delivery_count", 0)) > 0:
			saw_partial = true

	a.queue_free()
	b.queue_free()

	if hashes_a != hashes_b:
		push_error("Path logistics determinism hash mismatch")
		return false
	if not saw_path_edges:
		push_error("Expected path edges to accumulate from transport traversal")
		return false
	if not saw_partial:
		push_error("Expected at least one explicit partial delivery")
		return false

	print("Path logistics deterministic test passed")
	return true
