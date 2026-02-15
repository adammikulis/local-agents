@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const StateHasherScript = preload("res://addons/local_agents/simulation/SimulationStateHasher.gd")

func run_test(tree: SceneTree) -> bool:
	var sim = SimulationControllerScript.new()
	tree.get_root().add_child(sim)
	sim.world_id = "world_branch_%d" % Time.get_ticks_usec()
	sim.configure("seed-branching", false, false)
	sim.set_cognition_features(false, false, false)
	sim.resource_event_logging_enabled = true
	sim.persist_tick_history_enabled = true
	sim.persist_tick_history_interval = 1
	sim.register_villager("npc_branch_1", "BranchOne", {"household_id": "home_branch"})
	sim.register_villager("npc_branch_2", "BranchTwo", {"household_id": "home_branch"})

	var hasher = StateHasherScript.new()
	var hash_main_tick24 = ""
	for tick in range(1, 25):
		var result: Dictionary = sim.process_tick(tick, 1.0)
		if tick == 24:
			hash_main_tick24 = hasher.hash_state(result)

	var store = sim.get_store()
	var main_events: Array = store.list_resource_events(sim.world_id, "main", 1, 24)
	if main_events.is_empty():
		push_error("Expected main branch resource events before fork")
		sim.queue_free()
		return false

	var fork = sim.fork_branch("branch_alt", 24)
	if not bool(fork.get("ok", false)):
		push_error("Expected fork_branch to succeed")
		sim.queue_free()
		return false
	if sim.get_active_branch_id() != "branch_alt":
		push_error("Expected active branch to switch after fork")
		sim.queue_free()
		return false

	var hash_branch_tick30 = ""
	for tick in range(25, 31):
		var result: Dictionary = sim.process_tick(tick, 1.0)
		if tick == 30:
			hash_branch_tick30 = hasher.hash_state(result)

	var alt_events: Array = store.list_resource_events(sim.world_id, "branch_alt", 25, 30)
	var main_post_events: Array = store.list_resource_events(sim.world_id, "main", 25, 30)
	if alt_events.is_empty():
		push_error("Expected branch_alt events after fork")
		sim.queue_free()
		return false
	if not main_post_events.is_empty():
		push_error("Expected main branch to stop receiving events after fork")
		sim.queue_free()
		return false

	var checkpoints: Array = store.list_checkpoints(sim.world_id, "branch_alt")
	if checkpoints.is_empty():
		push_error("Expected branch_alt checkpoint with lineage")
		sim.queue_free()
		return false
	var first_checkpoint: Dictionary = checkpoints[0]
	var lineage: Array = first_checkpoint.get("lineage", [])
	if lineage.is_empty():
		push_error("Expected lineage entry on branch checkpoint")
		sim.queue_free()
		return false
	var first_lineage: Dictionary = lineage[0]
	if String(first_lineage.get("branch_id", "")) != "main" or int(first_lineage.get("tick", -1)) != 24:
		push_error("Expected lineage back-reference to main@24")
		sim.queue_free()
		return false

	sim.queue_free()
	if hash_main_tick24 == hash_branch_tick30:
		push_error("Expected forked branch state hash to diverge from main tick 24")
		return false

	print("Simulation branching test passed")
	return true
