@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const StateHasherScript = preload("res://addons/local_agents/simulation/SimulationStateHasher.gd")

func run_test(tree: SceneTree) -> bool:
	var sim = SimulationControllerScript.new()
	tree.get_root().add_child(sim)
	sim.world_id = "world_rewind_diff_%d" % Time.get_ticks_usec()
	sim.configure("seed-rewind-diff", false, false)
	sim.set_cognition_features(false, false, false)
	sim.register_villager("npc_rd_1", "RD1", {"household_id": "home_rd"})
	sim.register_villager("npc_rd_2", "RD2", {"household_id": "home_rd"})

	var hasher = StateHasherScript.new()
	var hash_tick_30_before = ""
	for tick in range(1, 41):
		var result = sim.process_tick(tick, 1.0)
		if tick == 30:
			hash_tick_30_before = hasher.hash_state(result.get("state", {}))

	var restored = sim.restore_to_tick(30, "main")
	if not bool(restored.get("ok", false)):
		push_error("Expected restore_to_tick to succeed")
		sim.queue_free()
		return false
	if int(restored.get("tick", -1)) != 30:
		push_error("Expected restore_to_tick to return requested tick")
		sim.queue_free()
		return false

	var hash_tick_40_after = ""
	for tick in range(31, 41):
		var result = sim.process_tick(tick, 1.0)
		if tick == 40:
			hash_tick_40_after = hasher.hash_state(result.get("state", {}))
	if hash_tick_40_after.strip_edges() == "":
		push_error("Expected valid state hash after post-restore replay ticks")
		sim.queue_free()
		return false

	var forked = sim.fork_branch("branch_alt_diff", 30)
	if not bool(forked.get("ok", false)):
		push_error("Expected fork_branch for diff test to succeed")
		sim.queue_free()
		return false
	sim.register_villager("npc_rd_3", "RD3", {"household_id": "home_rd"})
	for tick in range(31, 41):
		sim.process_tick(tick, 1.0)

	var diff: Dictionary = sim.branch_diff("main", "branch_alt_diff", 31, 40)
	sim.queue_free()
	if not bool(diff.get("ok", false)):
		push_error("Expected branch_diff to succeed")
		return false
	if int(diff.get("population_delta", 0)) <= 0:
		push_error("Expected branch population delta to reflect added villager")
		return false
	if not (diff.get("resource_delta", {}) is Dictionary):
		push_error("Expected branch_diff resource_delta dictionary")
		return false
	if not diff.has("belief_divergence"):
		push_error("Expected branch_diff belief_divergence field")
		return false
	if not diff.has("culture_continuity_score_delta"):
		push_error("Expected branch_diff culture continuity delta field")
		return false

	print("Simulation rewind and branch diff test passed")
	return true
