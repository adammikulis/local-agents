extends RefCounted
class_name LocalAgentsSimulationControllerOpsHelpers

static func memory_refs_from_recall(recall: Dictionary) -> Array:
	var refs: Array = []
	for key in ["waking", "dreams"]:
		var rows: Array = recall.get(key, [])
		for row_variant in rows:
			if row_variant is Dictionary:
				var row: Dictionary = row_variant
				refs.append(String(row.get("memory_id", "")))
	return refs

static func sorted_npc_ids(svc) -> Array:
	var ids = svc._villagers.keys()
	ids.sort()
	var out: Array = []
	for item in ids:
		out.append(String(item))
	return out

static func serialize_villagers(svc) -> Dictionary:
	var out = {}
	var ids = svc._villagers.keys()
	ids.sort()
	for npc_id in ids:
		var villager_state = svc._villagers.get(npc_id, null)
		if villager_state == null:
			continue
		out[String(npc_id)] = villager_state.to_dict()
	return out

static func serialize_household_ledgers(svc) -> Dictionary:
	var out = {}
	var ids = svc._household_ledgers.keys()
	ids.sort()
	for household_id in ids:
		var ledger = svc._household_ledgers[household_id]
		out[String(household_id)] = ledger.to_dict()
	return out

static func serialize_individual_ledgers(svc) -> Dictionary:
	var out = {}
	var ids = svc._individual_ledgers.keys()
	ids.sort()
	for npc_id in ids:
		var state = svc._individual_ledgers[npc_id]
		out[String(npc_id)] = state.to_dict()
	return out

static func serialize_carry_profiles(svc) -> Dictionary:
	var out = {}
	var ids = svc._carry_profiles.keys()
	ids.sort()
	for npc_id in ids:
		var profile = svc._carry_profiles[npc_id]
		out[String(npc_id)] = profile.to_dict()
	return out

static func belief_context_for_npc(svc, npc_id: String, world_day: int, limit: int) -> Dictionary:
	var out := {"beliefs": [], "conflicts": []}
	if svc._backstory_service == null:
		return out
	if svc._backstory_service.has_method("get_beliefs_for_npc"):
		var beliefs_result: Dictionary = svc._backstory_service.call("get_beliefs_for_npc", npc_id, world_day, limit)
		if bool(beliefs_result.get("ok", false)):
			out["beliefs"] = beliefs_result.get("beliefs", [])
	if svc._backstory_service.has_method("get_belief_truth_conflicts"):
		var conflicts_result: Dictionary = svc._backstory_service.call("get_belief_truth_conflicts", npc_id, world_day, limit)
		if bool(conflicts_result.get("ok", false)):
			out["conflicts"] = conflicts_result.get("conflicts", [])
	return out

static func culture_context_for_npc(svc, npc_id: String, world_day: int) -> Dictionary:
	var out := {"oral_knowledge": [], "ritual_events": [], "taboo_ids": []}
	if svc._backstory_service == null:
		return out
	var oral_limit = 3
	var ritual_limit = 2
	var taboo_limit = 6
	if svc._cognition_contract_config != null:
		oral_limit = maxi(1, int(svc._cognition_contract_config.get("budget_oral_knowledge")))
		ritual_limit = maxi(1, int(svc._cognition_contract_config.get("budget_ritual_events")))
		taboo_limit = maxi(1, int(svc._cognition_contract_config.get("budget_taboo_ids")))
	if svc._backstory_service.has_method("get_oral_knowledge_for_npc"):
		var oral_result: Dictionary = svc._backstory_service.call("get_oral_knowledge_for_npc", npc_id, world_day, oral_limit)
		if bool(oral_result.get("ok", false)):
			out["oral_knowledge"] = oral_result.get("oral_knowledge", [])
	if svc._sacred_site_id != "" and svc._backstory_service.has_method("get_ritual_history_for_site"):
		var ritual_result: Dictionary = svc._backstory_service.call("get_ritual_history_for_site", svc._sacred_site_id, world_day, ritual_limit)
		if bool(ritual_result.get("ok", false)):
			out["ritual_events"] = ritual_result.get("ritual_events", [])
	if svc._sacred_site_id != "" and svc._backstory_service.has_method("get_sacred_site"):
		var site_result: Dictionary = svc._backstory_service.call("get_sacred_site", svc._sacred_site_id)
		if bool(site_result.get("ok", false)):
			var site: Dictionary = site_result.get("site", {})
			var taboo_ids: Array = site.get("taboo_ids", [])
			var filtered: Array = []
			for taboo_variant in taboo_ids:
				if filtered.size() >= taboo_limit:
					break
				var taboo = String(taboo_variant).strip_edges()
				if taboo == "":
					continue
				filtered.append(taboo)
			out["taboo_ids"] = filtered
	return out

static func normalize_id_array(values: Array) -> Array:
	var out: Array = []
	for value in values:
		var text = String(value).strip_edges()
		if text == "" or out.has(text):
			continue
		out.append(text)
	out.sort()
	return out

static func apply_carry_assignments(svc, members: Array, assignments: Dictionary) -> void:
	for npc_id_variant in members:
		var npc_id = String(npc_id_variant)
		var econ_state = svc._individual_ledgers.get(npc_id, svc._individual_ledger_system.initial_individual_ledger(npc_id))
		var assignment: Dictionary = assignments.get(npc_id, {})
		if assignment.is_empty():
			econ_state = svc._individual_ledger_system.apply_carry_assignment(econ_state, {}, 0.0)
			svc._individual_ledgers[npc_id] = svc._individual_ledger_system.ensure_bounds(econ_state)
			continue
		var carried_weight = svc._economy_system.assignment_weight(assignment)
		econ_state = svc._individual_ledger_system.apply_carry_assignment(econ_state, assignment, carried_weight)
		econ_state = svc._individual_ledger_system.complete_carry_delivery(econ_state)
		svc._individual_ledgers[npc_id] = svc._individual_ledger_system.ensure_bounds(econ_state)

static func apply_route_transport(svc, assignments: Dictionary, start: Vector3, target: Vector3, tick: int) -> Dictionary:
	var delivered_assignments: Dictionary = {}
	var moved_payload: Dictionary = {}
	var unmoved_payload: Dictionary = {}
	var profiles: Dictionary = {}
	var npc_ids = assignments.keys()
	npc_ids.sort()
	for npc_id_variant in npc_ids:
		var npc_id = String(npc_id_variant)
		var assignment: Dictionary = assignments.get(npc_id, {})
		var profile: Dictionary = {}
		if svc._flow_network_system != null:
			var rain_intensity = clampf(float(svc._atmosphere_state_snapshot.get("avg_rain_intensity", 0.0)), 0.0, 1.0)
			profile = svc._flow_network_system.evaluate_route(start, target, {"tick": tick, "stage_intensity": rain_intensity})
		var efficiency = clampf(float(profile.get("delivery_efficiency", 1.0)), 0.2, 1.0)
		var jitter = svc._rng.randomf("route_delivery", npc_id, svc.active_branch_id, tick)
		var route_discipline = svc._cultural_policy_strength("route_discipline")
		efficiency = clampf(efficiency - (0.12 * jitter * (1.0 - route_discipline * 0.75)), 0.15, 1.0)
		var delivered_assignment: Dictionary = {}
		for resource in assignment.keys():
			var amount = maxf(0.0, float(assignment.get(resource, 0.0)))
			if amount <= 0.0:
				continue
			var resource_efficiency = efficiency
			if resource == "water":
				resource_efficiency = clampf(resource_efficiency + svc._cultural_policy_strength("water_conservation") * 0.16, 0.15, 1.0)
			var delivered = amount * resource_efficiency
			var shortfall = amount - delivered
			if delivered > 0.0:
				delivered_assignment[resource] = delivered
				moved_payload[resource] = float(moved_payload.get(resource, 0.0)) + delivered
			if shortfall > 0.0:
				unmoved_payload[resource] = float(unmoved_payload.get(resource, 0.0)) + shortfall
				svc._last_partial_delivery_count += 1
		delivered_assignments[npc_id] = delivered_assignment
		if svc._flow_network_system != null:
			var carry_weight = svc._economy_system.assignment_weight(delivered_assignment)
			svc._flow_network_system.record_flow(start, target, carry_weight)
			profile["delivery_efficiency_final"] = efficiency
			profiles[npc_id] = profile
	return {"assignments": delivered_assignments, "moved_payload": moved_payload, "unmoved_payload": unmoved_payload, "route_profiles": profiles}

static func merge_payloads(primary: Dictionary, secondary: Dictionary) -> Dictionary:
	var out = primary.duplicate(true)
	for key in secondary.keys():
		var resource = String(key)
		out[resource] = float(out.get(resource, 0.0)) + float(secondary.get(resource, 0.0))
	return out

static func spawn_offset_position(svc, entity_id: String, radius: float) -> Vector3:
	var seed = svc._rng.derive_seed("entity_position", entity_id, svc.active_branch_id, 0)
	var angle = float(abs(seed % 3600)) * 0.001745329
	return svc._community_anchor_position + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)

static func household_position(svc, household_id: String) -> Vector3:
	if svc._household_positions.has(household_id):
		return svc._household_positions[household_id]
	var generated = spawn_offset_position(svc, household_id, 4.0)
	svc._household_positions[household_id] = generated
	return generated

static func sum_payload(payload: Dictionary) -> float:
	var total = 0.0
	for key_variant in payload.keys():
		total += maxf(0.0, float(payload.get(String(key_variant), 0.0)))
	return total

static func mean_route_path_strength(route_profiles: Dictionary) -> float:
	var keys = route_profiles.keys()
	if keys.is_empty():
		return 0.0
	var total = 0.0
	for key in keys:
		var row: Dictionary = route_profiles.get(String(key), {})
		total += clampf(float(row.get("avg_path_strength", 0.0)), 0.0, 1.0)
	return total / float(keys.size())

static func household_member_counts(svc) -> Dictionary:
	var counts: Dictionary = {}
	var household_ids = svc._household_members.keys()
	household_ids.sort()
	for household_id_variant in household_ids:
		var household_id = String(household_id_variant)
		var members_resource = svc._household_members.get(household_id, null)
		counts[household_id] = int(members_resource.member_ids.size()) if members_resource != null else 0
	return counts

static func seed_sacred_site(svc) -> void:
	svc._sacred_site_id = "site:%s:%s:spring" % [svc.world_id, svc.active_branch_id]
	if svc._backstory_service == null:
		return
	var site_pos = {"x": svc._community_anchor_position.x + 1.0, "y": 0.0, "z": svc._community_anchor_position.z - 1.0}
	svc._backstory_service.upsert_sacred_site(svc._sacred_site_id, "spring", site_pos, 4.5, ["taboo_water_waste"], 0, {"source": "simulation_seed"})
