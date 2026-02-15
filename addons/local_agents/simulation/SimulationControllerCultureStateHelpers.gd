extends RefCounted
class_name LocalAgentsSimulationControllerCultureStateHelpers

const TileKeyUtilsScript = preload("res://addons/local_agents/simulation/TileKeyUtils.gd")

static func run_culture_cycle(svc, tick: int) -> void:
	if svc._culture_cycle == null:
		return
	var household_members: Dictionary = {}
	var household_ids = svc._household_members.keys()
	household_ids.sort()
	for household_id_variant in household_ids:
		var household_id = String(household_id_variant)
		var members_resource = svc._household_members.get(household_id, null)
		household_members[household_id] = members_resource.member_ids.duplicate() if members_resource != null else []
	var result: Dictionary = svc._culture_cycle.step(tick, {
		"graph_service": svc._backstory_service,
		"rng": svc._rng,
		"world_id": svc.world_id,
		"branch_id": svc.active_branch_id,
		"household_members": household_members,
		"npc_ids": svc._sorted_npc_ids(),
		"sacred_site_id": svc._sacred_site_id,
		"deterministic_seed": svc._rng.derive_seed("culture_driver", svc.world_id, svc.active_branch_id, tick),
		"culture_context": build_culture_context(svc, tick),
		"context_cues": svc._culture_context_cues.duplicate(true),
	})
	svc._culture_driver_events = result.get("drivers", [])
	svc._oral_tick_events = result.get("oral_events", [])
	svc._ritual_tick_events = result.get("ritual_events", [])
	svc._persist_llm_trace_event(tick, "oral_transmission_utterance", [], result.get("trace", {}))
	svc._cultural_policy = derive_cultural_policy(svc._culture_driver_events)
	for driver_variant in svc._culture_driver_events:
		if not (driver_variant is Dictionary):
			continue
		var driver = ensure_culture_event_metadata(driver_variant as Dictionary)
		var scope = String(driver.get("scope", "settlement")).strip_edges()
		if scope == "":
			scope = "settlement"
		var owner_id = String(driver.get("owner_id", "")).strip_edges()
		if owner_id == "":
			owner_id = "settlement_main"
		svc._log_resource_event(tick, "sim_culture_event", scope, owner_id, {
			"kind": "cultural_driver",
			"event": driver,
		})
	for oral_event_variant in svc._oral_tick_events:
		if not (oral_event_variant is Dictionary):
			continue
		var oral_event = ensure_culture_event_metadata(oral_event_variant as Dictionary)
		var household_id = String(oral_event.get("household_id", ""))
		svc._log_resource_event(tick, "sim_culture_event", "household", household_id, {
			"kind": "oral_transfer",
			"event": oral_event,
		})
	for ritual_event_variant in svc._ritual_tick_events:
		if not (ritual_event_variant is Dictionary):
			continue
		var ritual_event = ensure_culture_event_metadata(ritual_event_variant as Dictionary)
		svc._log_resource_event(tick, "sim_culture_event", "settlement", "settlement_main", {
			"kind": "ritual_event",
			"event": ritual_event,
		})

static func ensure_culture_event_metadata(event: Dictionary) -> Dictionary:
	var out := event.duplicate(true)
	var salience := clampf(float(out.get("salience", 0.0)), 0.0, 1.0)
	var gain_loss := clampf(float(out.get("gain_loss", 0.0)), -1.0, 1.0)
	out["salience"] = salience
	out["gain_loss"] = gain_loss
	var metadata_variant = out.get("metadata", {})
	var metadata: Dictionary = {}
	if metadata_variant is Dictionary:
		metadata = (metadata_variant as Dictionary).duplicate(true)
	metadata["salience"] = salience
	metadata["gain_loss"] = gain_loss
	out["metadata"] = metadata
	return out

static func apply_snapshot(svc, snapshot: Dictionary) -> void:
	svc.world_id = String(snapshot.get("world_id", svc.world_id))
	svc.active_branch_id = String(snapshot.get("branch_id", svc.active_branch_id))
	svc._branch_lineage = (snapshot.get("branch_lineage", []) as Array).duplicate(true)
	svc._branch_fork_tick = int(snapshot.get("branch_fork_tick", svc._branch_fork_tick))
	svc._environment_snapshot = snapshot.get("environment_snapshot", {}).duplicate(true)
	svc._network_state_snapshot = snapshot.get("network_state_snapshot", {}).duplicate(true)
	svc._atmosphere_state_snapshot = snapshot.get("atmosphere_state_snapshot", {}).duplicate(true)
	svc._deformation_state_snapshot = snapshot.get("deformation_state_snapshot", {}).duplicate(true)
	svc._exposure_state_snapshot = snapshot.get("exposure_state_snapshot", {}).duplicate(true)
	svc._transform_changed_last_tick = bool(snapshot.get("transform_changed", false))
	svc._transform_changed_tiles_last_tick = (snapshot.get("transform_changed_tiles", []) as Array).duplicate(true)
	svc._spawn_artifact = snapshot.get("spawn_artifact", {}).duplicate(true)
	svc._sacred_site_id = String(snapshot.get("sacred_site_id", svc._sacred_site_id))
	if svc._culture_cycle != null:
		svc._culture_cycle.import_state(snapshot.get("cultural_cycle_state", {}))
	svc._culture_driver_events = snapshot.get("culture_driver_events", [])
	svc._cultural_policy = snapshot.get("cultural_policy", {}).duplicate(true)
	svc._culture_context_cues = snapshot.get("culture_context_cues", {}).duplicate(true)
	var llama_options_variant = snapshot.get("llama_server_options", null)
	if llama_options_variant is Dictionary:
		svc._llama_server_options = (llama_options_variant as Dictionary).duplicate(true)
	var scheduler_variant = snapshot.get("cognition_scheduler", null)
	if scheduler_variant is Dictionary:
		var scheduler = scheduler_variant as Dictionary
		svc._pending_thought_npc_ids = svc._normalize_id_array(scheduler.get("pending_thoughts", []) as Array)
		svc._pending_dream_npc_ids = svc._normalize_id_array(scheduler.get("pending_dreams", []) as Array)
		svc._pending_dialogue_pairs.clear()
		var pending_pairs: Array = scheduler.get("pending_dialogues", [])
		for pair_variant in pending_pairs:
			if not (pair_variant is Dictionary):
				continue
			var pair = pair_variant as Dictionary
			var source_id = String(pair.get("source_id", "")).strip_edges()
			var target_id = String(pair.get("target_id", "")).strip_edges()
			if source_id == "" or target_id == "":
				continue
			svc._pending_dialogue_pairs.append({"source_id": source_id, "target_id": target_id})
	svc._apply_llama_server_integration()

	svc._community_ledger = svc._community_ledger_system.initial_community_ledger()
	apply_community_dict(svc._community_ledger, snapshot.get("community_ledger", {}))

	svc._household_ledgers.clear()
	var household_rows: Dictionary = snapshot.get("household_ledgers", {})
	var household_ids = household_rows.keys()
	household_ids.sort_custom(func(a, b): return String(a) < String(b))
	for household_id_variant in household_ids:
		var household_id = String(household_id_variant)
		var ledger = svc._household_ledger_system.initial_household_ledger(household_id)
		apply_household_dict(ledger, household_rows.get(household_id, {}))
		svc._household_ledgers[household_id] = ledger

	svc._individual_ledgers.clear()
	var individual_rows: Dictionary = snapshot.get("individual_ledgers", {})
	var npc_ids = individual_rows.keys()
	npc_ids.sort_custom(func(a, b): return String(a) < String(b))
	for npc_id_variant in npc_ids:
		var npc_id = String(npc_id_variant)
		var state = svc.VillagerEconomyStateResourceScript.new()
		state.npc_id = npc_id
		state.inventory = svc.VillagerInventoryResourceScript.new()
		apply_individual_dict(state, individual_rows.get(npc_id, {}))
		svc._individual_ledgers[npc_id] = svc._individual_ledger_system.ensure_bounds(state)

	svc._villagers.clear()
	var villager_rows: Dictionary = snapshot.get("villagers", {})
	var villager_ids = villager_rows.keys()
	villager_ids.sort_custom(func(a, b): return String(a) < String(b))
	for npc_id_variant in villager_ids:
		var npc_id = String(npc_id_variant)
		var villager_state = svc.VillagerStateResourceScript.new()
		villager_state.from_dict(villager_rows.get(npc_id, {}))
		svc._villagers[npc_id] = villager_state

	svc._carry_profiles.clear()
	var carry_rows: Dictionary = snapshot.get("carry_profiles", {})
	var carry_ids = carry_rows.keys()
	carry_ids.sort_custom(func(a, b): return String(a) < String(b))
	for npc_id_variant in carry_ids:
		var npc_id = String(npc_id_variant)
		var profile = svc.CarryProfileResourceScript.new()
		apply_carry_profile_dict(profile, carry_rows.get(npc_id, {}))
		svc._carry_profiles[npc_id] = profile

	if svc._flow_network_system != null:
		svc._flow_network_system.configure_environment(svc._environment_snapshot, svc._network_state_snapshot)
		svc._flow_network_system.import_network(snapshot.get("flow_network", {}))

	if svc._structure_lifecycle_system != null:
		svc._structure_lifecycle_system.import_lifecycle_state(snapshot.get("structures", {}), snapshot.get("anchors", []), snapshot.get("structure_lifecycle_runtime", {}))

static func build_culture_context(svc, tick: int) -> Dictionary:
	var households: Array = []
	var structure_rows: Dictionary = svc._structure_lifecycle_system.export_structures() if svc._structure_lifecycle_system != null else {}
	var household_ids = svc._household_members.keys()
	household_ids.sort()
	for household_id_variant in household_ids:
		var household_id = String(household_id_variant)
		var members_resource = svc._household_members.get(household_id, null)
		var members: Array = members_resource.member_ids.duplicate() if members_resource != null else []
		members.sort()
		var member_count = members.size()
		var ledger = svc._household_ledgers.get(household_id, null)
		var ledger_row: Dictionary = ledger.to_dict() if ledger != null else {}
		var structures: Array = structure_rows.get(household_id, [])
		var active_structures = 0
		for structure_variant in structures:
			if not (structure_variant is Dictionary):
				continue
			var structure = structure_variant as Dictionary
			if String(structure.get("state", "")) == "active":
				active_structures += 1
		var pos = svc._household_position(household_id)
		var tile = tile_context_for_position(svc, pos)
		var belonging_index = clampf(float(member_count) * 0.32 + clampf(float(active_structures) * 0.26, 0.0, 1.0) + clampf((maxf(0.0, float(ledger_row.get("food", 0.0))) + maxf(0.0, float(ledger_row.get("water", 0.0)))) * 0.09, 0.0, 1.0), 0.0, 3.0)
		var bone_signal = clampf(maxf(0.0, float(ledger_row.get("tools", 0.0))) * 0.08 + maxf(0.0, float(ledger_row.get("waste", 0.0))) * 0.04, 0.0, 1.0)
		households.append({
			"household_id": household_id,
			"members": members,
			"member_count": member_count,
			"food": maxf(0.0, float(ledger_row.get("food", 0.0))),
			"water": maxf(0.0, float(ledger_row.get("water", 0.0))),
			"wood": maxf(0.0, float(ledger_row.get("wood", 0.0))),
			"stone": maxf(0.0, float(ledger_row.get("stone", 0.0))),
			"tools": maxf(0.0, float(ledger_row.get("tools", 0.0))),
			"currency": maxf(0.0, float(ledger_row.get("currency", 0.0))),
			"debt": maxf(0.0, float(ledger_row.get("debt", 0.0))),
			"waste": maxf(0.0, float(ledger_row.get("waste", 0.0))),
			"active_structures": active_structures,
			"belonging_index": belonging_index,
			"bone_signal": bone_signal,
			"x": pos.x,
			"z": pos.z,
			"biome": String(tile.get("biome", "plains")),
			"temperature": float(tile.get("temperature", 0.5)),
			"moisture": float(tile.get("moisture", 0.5)),
			"water_reliability": float(tile.get("water_reliability", 0.5)),
			"flood_risk": float(tile.get("flood_risk", 0.0)),
		})

	var individuals: Array = []
	var npc_ids = svc._sorted_npc_ids()
	for npc_id in npc_ids:
		var state_resource = svc._villagers.get(npc_id, null)
		var econ_state = svc._individual_ledgers.get(npc_id, null)
		var state = state_resource.to_dict() if state_resource != null else {}
		var econ = econ_state.to_dict() if econ_state != null else {}
		var inv: Dictionary = econ.get("inventory", {})
		individuals.append({
			"npc_id": npc_id,
			"household_id": String(state.get("household_id", "")),
			"morale": float(state.get("morale", 0.5)),
			"fear": float(state.get("fear", 0.0)),
			"hunger": float(state.get("hunger", 0.0)),
			"energy": float(state.get("energy", 1.0)),
			"food": float(inv.get("food", 0.0)),
			"water": float(inv.get("water", 0.0)),
			"currency": float(inv.get("currency", 0.0)),
			"tools": float(inv.get("tools", 0.0)),
			"waste": float(inv.get("waste", 0.0)),
		})
	if individuals.size() > 20:
		individuals.resize(20)

	return {
		"tick": tick,
		"community": svc._community_ledger.to_dict() if svc._community_ledger != null else {},
		"households": households,
		"individuals": individuals,
		"living_entities": svc._external_living_entity_profiles.duplicate(true),
		"recent_events": recent_resource_event_context(svc, maxi(0, tick - 24), tick),
	}

static func derive_cultural_policy(drivers: Array) -> Dictionary:
	var policy := {"water_conservation": 0.0, "water_taboo_compliance": 0.0, "route_discipline": 0.0}
	for driver_variant in drivers:
		if not (driver_variant is Dictionary):
			continue
		var row = driver_variant as Dictionary
		var salience = clampf(float(row.get("salience", 0.0)), 0.0, 1.0)
		var gain_loss = clampf(float(row.get("gain_loss", 0.0)), -1.0, 1.0)
		var positive = clampf((gain_loss + 1.0) * 0.5, 0.0, 1.0)
		var tags: Array = row.get("tags", [])
		var topic = String(row.get("topic", ""))
		if topic == "water_route_reliability":
			policy["water_conservation"] = maxf(float(policy.get("water_conservation", 0.0)), salience * (0.4 + 0.6 * positive))
			policy["route_discipline"] = maxf(float(policy.get("route_discipline", 0.0)), salience * 0.75)
		if topic == "ritual_obligation":
			policy["water_taboo_compliance"] = maxf(float(policy.get("water_taboo_compliance", 0.0)), salience * (0.35 + 0.65 * positive))
		for tag_variant in tags:
			var tag = String(tag_variant)
			if tag == "water":
				policy["water_conservation"] = maxf(float(policy.get("water_conservation", 0.0)), salience * 0.6)
			elif tag == "ritual":
				policy["water_taboo_compliance"] = maxf(float(policy.get("water_taboo_compliance", 0.0)), salience * 0.52)
			elif tag == "ownership" or tag == "belonging":
				policy["route_discipline"] = maxf(float(policy.get("route_discipline", 0.0)), salience * 0.45)
	return policy

static func tile_context_for_position(svc, position: Vector3) -> Dictionary:
	var tile_id = TileKeyUtilsScript.from_world_xz(position)
	var tile_index: Dictionary = svc._environment_snapshot.get("tile_index", {})
	var tile = tile_index.get(tile_id, {})
	var water_tiles: Dictionary = svc._network_state_snapshot.get("water_tiles", {})
	var water = water_tiles.get(tile_id, {})
	return {
		"biome": String(tile.get("biome", "plains")),
		"temperature": clampf(float(tile.get("temperature", 0.5)), 0.0, 1.0),
		"moisture": clampf(float(tile.get("moisture", 0.5)), 0.0, 1.0),
		"water_reliability": clampf(float(water.get("water_reliability", 0.5)), 0.0, 1.0),
		"flood_risk": clampf(float(water.get("flood_risk", 0.0)), 0.0, 1.0),
	}

static func recent_resource_event_context(svc, tick_from: int, tick_to: int) -> Array:
	if svc._store == null:
		return []
	var rows: Array = svc._store.list_resource_events(svc.world_id, svc.active_branch_id, tick_from, tick_to)
	var out: Array = []
	for row_variant in rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var payload: Dictionary = row.get("payload", {})
		out.append({
			"tick": int(row.get("tick", 0)),
			"event_type": String(row.get("event_type", "")),
			"scope": String(row.get("scope", "")),
			"owner_id": String(row.get("owner_id", "")),
			"kind": String(payload.get("kind", "")),
			"magnitude": event_magnitude(payload),
		})
	out.sort_custom(func(a, b):
		var ad = a as Dictionary
		var bd = b as Dictionary
		return int(ad.get("tick", 0)) < int(bd.get("tick", 0))
	)
	if out.size() > 48:
		out = out.slice(out.size() - 48, out.size())
	return out

static func event_magnitude(payload: Dictionary) -> float:
	var total = 0.0
	var bundle: Dictionary = payload.get("resource_bundle", {})
	if not bundle.is_empty():
		var bundle_keys = bundle.keys()
		bundle_keys.sort_custom(func(a, b): return String(a) < String(b))
		for key_variant in bundle_keys:
			var key = String(key_variant)
			total += absf(float(bundle.get(key, 0.0)))
	var delta: Dictionary = payload.get("delta", {})
	if not delta.is_empty():
		var delta_keys = delta.keys()
		delta_keys.sort_custom(func(a, b): return String(a) < String(b))
		for key_variant in delta_keys:
			var key = String(key_variant)
			total += absf(float(delta.get(key, 0.0)))
	var moved: Dictionary = payload.get("moved", {})
	if not moved.is_empty():
		var moved_keys = moved.keys()
		moved_keys.sort_custom(func(a, b): return String(a) < String(b))
		for key_variant in moved_keys:
			var key = String(key_variant)
			total += absf(float(moved.get(key, 0.0)))
	return clampf(total, 0.0, 1000000.0)

static func apply_community_dict(ledger, payload_variant) -> void:
	if not (payload_variant is Dictionary):
		return
	var payload = payload_variant as Dictionary
	ledger.food = maxf(0.0, float(payload.get("food", ledger.food)))
	ledger.water = maxf(0.0, float(payload.get("water", ledger.water)))
	ledger.wood = maxf(0.0, float(payload.get("wood", ledger.wood)))
	ledger.stone = maxf(0.0, float(payload.get("stone", ledger.stone)))
	ledger.tools = maxf(0.0, float(payload.get("tools", ledger.tools)))
	ledger.currency = maxf(0.0, float(payload.get("currency", ledger.currency)))
	ledger.labor_pool = maxf(0.0, float(payload.get("labor_pool", ledger.labor_pool)))
	ledger.storage_capacity = maxf(1.0, float(payload.get("storage_capacity", ledger.storage_capacity)))
	ledger.spoiled = maxf(0.0, float(payload.get("spoiled", ledger.spoiled)))
	ledger.waste = maxf(0.0, float(payload.get("waste", ledger.waste)))

static func apply_household_dict(ledger, payload_variant) -> void:
	if not (payload_variant is Dictionary):
		return
	var payload = payload_variant as Dictionary
	ledger.food = maxf(0.0, float(payload.get("food", ledger.food)))
	ledger.water = maxf(0.0, float(payload.get("water", ledger.water)))
	ledger.wood = maxf(0.0, float(payload.get("wood", ledger.wood)))
	ledger.stone = maxf(0.0, float(payload.get("stone", ledger.stone)))
	ledger.tools = maxf(0.0, float(payload.get("tools", ledger.tools)))
	ledger.currency = maxf(0.0, float(payload.get("currency", ledger.currency)))
	ledger.debt = maxf(0.0, float(payload.get("debt", ledger.debt)))
	ledger.housing_quality = clampf(float(payload.get("housing_quality", ledger.housing_quality)), 0.0, 1.0)
	ledger.waste = maxf(0.0, float(payload.get("waste", ledger.waste)))

static func apply_individual_dict(state, payload_variant) -> void:
	if not (payload_variant is Dictionary):
		return
	var payload = payload_variant as Dictionary
	state.wage_due = maxf(0.0, float(payload.get("wage_due", state.wage_due)))
	state.moved_total_weight = maxf(0.0, float(payload.get("moved_total_weight", state.moved_total_weight)))
	state.energy = clampf(float(payload.get("energy", state.energy)), 0.0, 1.0)
	state.health = clampf(float(payload.get("health", state.health)), 0.0, 1.0)
	var inv_payload: Dictionary = payload.get("inventory", {})
	var inv = state.inventory
	inv.food = maxf(0.0, float(inv_payload.get("food", inv.food)))
	inv.water = maxf(0.0, float(inv_payload.get("water", inv.water)))
	inv.wood = maxf(0.0, float(inv_payload.get("wood", inv.wood)))
	inv.stone = maxf(0.0, float(inv_payload.get("stone", inv.stone)))
	inv.tools = maxf(0.0, float(inv_payload.get("tools", inv.tools)))
	inv.currency = maxf(0.0, float(inv_payload.get("currency", inv.currency)))
	inv.waste = maxf(0.0, float(inv_payload.get("waste", inv.waste)))
	inv.carried_food = maxf(0.0, float(inv_payload.get("carried_food", inv.carried_food)))
	inv.carried_water = maxf(0.0, float(inv_payload.get("carried_water", inv.carried_water)))
	inv.carried_wood = maxf(0.0, float(inv_payload.get("carried_wood", inv.carried_wood)))
	inv.carried_stone = maxf(0.0, float(inv_payload.get("carried_stone", inv.carried_stone)))
	inv.carried_tools = maxf(0.0, float(inv_payload.get("carried_tools", inv.carried_tools)))
	inv.carried_currency = maxf(0.0, float(inv_payload.get("carried_currency", inv.carried_currency)))
	inv.carried_weight = maxf(0.0, float(inv_payload.get("carried_weight", inv.carried_weight)))

static func apply_carry_profile_dict(profile, payload_variant) -> void:
	if not (payload_variant is Dictionary):
		return
	var payload = payload_variant as Dictionary
	profile.strength = clampf(float(payload.get("strength", profile.strength)), 0.0, 1.5)
	profile.tool_efficiency = maxf(0.0, float(payload.get("tool_efficiency", profile.tool_efficiency)))
	profile.base_capacity = maxf(0.1, float(payload.get("base_capacity", profile.base_capacity)))
	profile.strength_multiplier = maxf(0.0, float(payload.get("strength_multiplier", profile.strength_multiplier)))
	profile.max_tool_bonus = maxf(0.0, float(payload.get("max_tool_bonus", profile.max_tool_bonus)))
	profile.tool_bonus_factor = maxf(0.0, float(payload.get("tool_bonus_factor", profile.tool_bonus_factor)))
	profile.min_capacity = maxf(0.0, float(payload.get("min_capacity", profile.min_capacity)))
