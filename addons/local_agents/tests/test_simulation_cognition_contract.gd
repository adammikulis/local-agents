@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const MindServiceScript = preload("res://addons/local_agents/simulation/VillagerMindService.gd")
const CognitionContractConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/CognitionContractConfigResource.gd")

func run_test(tree: SceneTree) -> bool:
	var expected_order = [
		"villager_state",
		"waking_memories",
		"dream_memories",
		"beliefs",
		"belief_truth_conflicts",
		"role_household_economic_context",
		"oral_knowledge_ritual_taboo_context",
	]
	var mind = MindServiceScript.new()
	mind.set_contract_limits({"context_schema_version": 3})
	var prompt_context: Dictionary = mind.call("_assemble_prompt_context", {
		"mood": "calm",
		"morale": 0.6,
		"belief_context": {"beliefs": [], "conflicts": []},
		"culture_context": {"oral_knowledge": [], "ritual_events": [], "taboo_ids": []},
	}, {"waking": [], "dreams": []})
	if int(prompt_context.get("schema_version", -1)) != 3:
		push_error("Expected context schema version=3 in mind prompt contract")
		return false
	if prompt_context.get("section_order", []) != expected_order:
		push_error("Prompt section order contract mismatch")
		return false

	var controller = SimulationControllerScript.new()
	tree.get_root().add_child(controller)
	var contract = CognitionContractConfigResourceScript.new()
	contract.context_schema_version = 3
	contract.max_prompt_chars = 7777
	var thought_profile = contract.profile_for_task("internal_thought")
	if thought_profile != null:
		thought_profile.set("profile_id", "thought_contract_test")
	controller.set_cognition_contract_config(contract)
	controller.configure("seed-cognition-contract", false, false)
	controller.set_cognition_features(false, false, false)
	controller.register_villager("npc_contract", "Contract NPC", {"household_id": "house_contract"})

	var trace_payload = {
		"profile_id": "thought_contract_test",
		"seed": 41,
		"query_keys": ["villager_state_snapshot", "memory_recall_candidates_waking"],
		"referenced_ids": ["npc_contract"],
		"sampler_params": {"temperature": 0.5, "top_p": 0.9},
	}
	controller.call("_persist_llm_trace_event", 1, "internal_thought", ["npc_contract"], trace_payload)
	var rows: Array = controller.get_store().list_resource_events(controller.world_id, controller.get_active_branch_id(), 1, 1)
	var found = false
	for row_variant in rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		if String(row.get("event_type", "")) != "sim_llm_trace_event":
			continue
		var payload: Dictionary = row.get("payload", {})
		if String(payload.get("task", "")) != "internal_thought":
			continue
		if String(payload.get("profile_id", "")) != "thought_contract_test":
			continue
		if int(payload.get("seed", -1)) != 41:
			push_error("Trace payload seed mismatch")
			controller.queue_free()
			return false
		var query_keys: Array = payload.get("query_keys", [])
		if not query_keys.has("villager_state_snapshot"):
			push_error("Trace payload missing query_keys")
			controller.queue_free()
			return false
		found = true
		break
	controller.queue_free()
	if not found:
		push_error("Expected persisted sim_llm_trace_event row")
		return false

	print("Simulation cognition contract test passed")
	return true
