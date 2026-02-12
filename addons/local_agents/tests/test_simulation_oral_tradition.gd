@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")

func run_test(tree: SceneTree) -> bool:
	var sim = SimulationControllerScript.new()
	tree.get_root().add_child(sim)
	sim.configure("seed-oral-tradition", false, false)
	sim.set_cognition_features(false, false, false)
	sim.register_villager("npc_oral_1", "Elder", {"household_id": "home_oral"})
	sim.register_villager("npc_oral_2", "YouthA", {"household_id": "home_oral"})
	sim.register_villager("npc_oral_3", "YouthB", {"household_id": "home_oral"})

	var saw_oral = false
	var saw_ritual = false
	var site_id = ""
	for tick in range(1, 97):
		var result: Dictionary = sim.process_tick(tick, 1.0)
		var state: Dictionary = result.get("state", {})
		site_id = String(state.get("sacred_site_id", site_id))
		var oral_events: Array = state.get("oral_transfer_events", [])
		var ritual_events: Array = state.get("ritual_events", [])
		if not oral_events.is_empty():
			saw_oral = true
		if not ritual_events.is_empty():
			saw_ritual = true

	if not saw_oral:
		push_error("Expected deterministic oral transfer events")
		sim.queue_free()
		return false
	if not saw_ritual:
		push_error("Expected deterministic ritual events")
		sim.queue_free()
		return false
	if site_id == "":
		push_error("Expected seeded sacred site id in snapshot")
		sim.queue_free()
		return false

	var service = sim.get_backstory_service()
	var oral_lookup: Dictionary = service.get_oral_knowledge_for_npc("npc_oral_2", 8, 16)
	if not bool(oral_lookup.get("ok", false)) or (oral_lookup.get("oral_knowledge", []) as Array).is_empty():
		push_error("Expected oral knowledge records to be queryable for listener NPC")
		sim.queue_free()
		return false
	var history: Dictionary = service.get_ritual_history_for_site(site_id, 8, 12)
	if not bool(history.get("ok", false)) or (history.get("ritual_events", []) as Array).is_empty():
		push_error("Expected ritual history to be queryable for seeded sacred site")
		sim.queue_free()
		return false

	sim.queue_free()
	print("Simulation oral tradition test passed")
	return true
