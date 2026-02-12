extends RefCounted
class_name LocalAgentsBranchAnalysisService

func compare_branches(store, world_id: String, base_branch_id: String, compare_branch_id: String, tick_from: int, tick_to: int, backstory_service = null) -> Dictionary:
	if store == null:
		return {"ok": false, "error": "store_unavailable"}
	var base_state = _last_snapshot_for_branch(store, world_id, base_branch_id, tick_to)
	var compare_state = _last_snapshot_for_branch(store, world_id, compare_branch_id, tick_to)
	if base_state.is_empty() or compare_state.is_empty():
		return {"ok": false, "error": "branch_state_missing"}

	var base_population = _snapshot_population(base_state)
	var compare_population = _snapshot_population(compare_state)
	var base_resources: Dictionary = base_state.get("community_ledger", {})
	var compare_resources: Dictionary = compare_state.get("community_ledger", {})
	var resource_delta: Dictionary = {}
	for key in ["food", "water", "wood", "stone", "tools", "currency", "waste"]:
		resource_delta[key] = float(compare_resources.get(key, 0.0)) - float(base_resources.get(key, 0.0))

	var base_culture = _culture_metrics(store, world_id, base_branch_id, tick_from, tick_to)
	var compare_culture = _culture_metrics(store, world_id, compare_branch_id, tick_from, tick_to)
	var base_belief = _belief_conflict_count(backstory_service, base_state, tick_to)
	var compare_belief = _belief_conflict_count(backstory_service, compare_state, tick_to)
	var base_continuity = _culture_continuity_score(base_population, base_culture)
	var compare_continuity = _culture_continuity_score(compare_population, compare_culture)

	return {
		"ok": true,
		"tick_from": tick_from,
		"tick_to": tick_to,
		"base_branch": base_branch_id,
		"compare_branch": compare_branch_id,
		"population_delta": compare_population - base_population,
		"resource_delta": resource_delta,
		"belief_divergence": compare_belief - base_belief,
		"culture_continuity_score_delta": compare_continuity - base_continuity,
		"base": {
			"population": base_population,
			"belief_conflicts": base_belief,
			"culture": base_culture,
			"culture_continuity_score": base_continuity,
		},
		"compare": {
			"population": compare_population,
			"belief_conflicts": compare_belief,
			"culture": compare_culture,
			"culture_continuity_score": compare_continuity,
		},
	}

func _last_snapshot_for_branch(store, world_id: String, branch_id: String, tick_to: int) -> Dictionary:
	var events: Array = store.list_events(world_id, branch_id, 0, tick_to)
	var snapshot: Dictionary = {}
	for row_variant in events:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		if String(row.get("event_type", "")) != "tick":
			continue
		snapshot = (row.get("payload", {}) as Dictionary).duplicate(true)
	return snapshot

func _snapshot_population(snapshot: Dictionary) -> int:
	return int((snapshot.get("villagers", {}) as Dictionary).size())

func _culture_metrics(store, world_id: String, branch_id: String, tick_from: int, tick_to: int) -> Dictionary:
	var oral = 0
	var ritual = 0
	var events: Array = store.list_resource_events(world_id, branch_id, tick_from, tick_to)
	for row_variant in events:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		if String(row.get("event_type", "")) != "sim_culture_event":
			continue
		var payload: Dictionary = row.get("payload", {})
		var kind = String(payload.get("kind", ""))
		if kind == "oral_transfer":
			oral += 1
		elif kind == "ritual_event":
			ritual += 1
	return {"oral_transfers": oral, "ritual_events": ritual}

func _belief_conflict_count(backstory_service, snapshot: Dictionary, tick_to: int) -> int:
	if backstory_service == null:
		return 0
	var world_day = int(tick_to / 24)
	var villagers: Dictionary = snapshot.get("villagers", {})
	var npc_ids = villagers.keys()
	npc_ids.sort_custom(func(a, b): return String(a) < String(b))
	var total = 0
	for npc_id_variant in npc_ids:
		var npc_id = String(npc_id_variant)
		var result: Dictionary = backstory_service.get_belief_truth_conflicts(npc_id, world_day, 16)
		if bool(result.get("ok", false)):
			total += int((result.get("conflicts", []) as Array).size())
	return total

func _culture_continuity_score(population: int, culture_metrics: Dictionary) -> float:
	var pop = max(1, population)
	var oral = float(culture_metrics.get("oral_transfers", 0))
	var ritual = float(culture_metrics.get("ritual_events", 0))
	return (oral * 0.65 + ritual * 1.15) / float(pop)
