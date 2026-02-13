extends RefCounted
class_name LocalAgentsSimulationControllerRuntimeHelpers

static func run_thought_cycle(svc, npc_id: String, tick: int) -> bool:
	var villager_state = svc._villagers.get(npc_id, null)
	if villager_state == null:
		return true
	var state: Dictionary = villager_state.to_dict()
	var world_day = int(tick / 24)
	state["belief_context"] = svc._belief_context_for_npc(npc_id, world_day, 3)
	state["culture_context"] = svc._culture_context_for_npc(npc_id, world_day)
	var recall = svc._mind.select_recall_context(svc._backstory_service, npc_id, world_day, 6, 2)
	var seed = svc._rng.derive_seed("thought", npc_id, svc.active_branch_id, tick)
	var thought = svc._mind.generate_internal_thought(npc_id, state, recall, seed, svc._directive_text())
	if not bool(thought.get("ok", false)):
		return svc._emit_dependency_error(tick, "thought", String(thought.get("error", "thought_failed")))
	var thought_text = String(thought.get("text", "")).strip_edges()
	if thought_text == "":
		return true
	var memory_id = "thought:%s:%s:%d" % [svc.world_id, npc_id, tick]
	var metadata = {"source": "llm_thought", "is_factual": false, "recall_ids": svc._memory_refs_from_recall(recall), "evidence_trace": thought.get("trace", {})}
	var memory = svc._backstory_service.add_thought_memory(memory_id, npc_id, thought_text, world_day, svc._memory_refs_from_recall(recall), 0.4, 0.7, metadata)
	if not bool(memory.get("ok", false)):
		return svc._emit_dependency_error(tick, "thought_memory", "backstory_write_failed")
	svc._persist_llm_trace_event(tick, "thought_generation", [npc_id], thought.get("trace", {}))
	svc.emit_signal("villager_thought_recorded", npc_id, tick, memory_id, thought_text)
	return true

static func run_dialogue_pair(svc, source_id: String, target_id: String, tick: int) -> bool:
	var source_state_resource = svc._villagers.get(source_id, null)
	var target_state_resource = svc._villagers.get(target_id, null)
	if source_state_resource == null or target_state_resource == null:
		return true
	var source_state: Dictionary = source_state_resource.to_dict()
	var target_state: Dictionary = target_state_resource.to_dict()
	var world_day = int(tick / 24)
	source_state["belief_context"] = svc._belief_context_for_npc(source_id, world_day, 3)
	target_state["belief_context"] = svc._belief_context_for_npc(target_id, world_day, 3)
	source_state["culture_context"] = svc._culture_context_for_npc(source_id, world_day)
	target_state["culture_context"] = svc._culture_context_for_npc(target_id, world_day)
	var source_recall = svc._mind.select_recall_context(svc._backstory_service, source_id, world_day, 4, 1)
	var target_recall = svc._mind.select_recall_context(svc._backstory_service, target_id, world_day, 4, 1)
	var seed = svc._rng.derive_seed("dialogue", source_id + "->" + target_id, svc.active_branch_id, tick)
	var result = svc._mind.generate_dialogue_exchange(source_id, target_id, source_state, target_state, source_recall, target_recall, seed, svc._directive_text())
	if not bool(result.get("ok", false)):
		return svc._emit_dependency_error(tick, "dialogue", String(result.get("error", "dialogue_failed")))
	var dialogue_text = String(result.get("text", "")).strip_edges()
	if dialogue_text == "":
		return true
	var event_id = "dialogue:%s:%s:%s:%d" % [svc.world_id, source_id, target_id, tick]
	svc._backstory_service.record_event(event_id, "villager_dialogue", dialogue_text, world_day, "", [source_id, target_id], {"source": "llm_dialogue", "is_factual": true, "source_recall": svc._memory_refs_from_recall(source_recall), "target_recall": svc._memory_refs_from_recall(target_recall), "evidence_trace": result.get("trace", {})})
	svc._persist_llm_trace_event(tick, "dialogue_exchange", [source_id, target_id], result.get("trace", {}))
	svc.emit_signal("villager_dialogue_recorded", source_id, target_id, tick, event_id, dialogue_text)
	return true

static func run_dream_cycle(svc, npc_id: String, tick: int) -> bool:
	var villager_state = svc._villagers.get(npc_id, null)
	if villager_state == null:
		return true
	var state: Dictionary = villager_state.to_dict()
	var seed = svc._rng.derive_seed("dream", npc_id, svc.active_branch_id, tick)
	var dream = svc._dreams.generate_dream_text(npc_id, state, seed, svc._directive_text())
	if not bool(dream.get("ok", false)):
		return svc._emit_dependency_error(tick, "dream", String(dream.get("error", "dream_failed")))
	var dream_text = String(dream.get("text", "")).strip_edges()
	if dream_text == "":
		return true
	var influence = svc._dreams.get_dream_influence(npc_id)
	var metadata = svc._dreams.dream_memory_metadata(influence, seed)
	metadata["evidence_trace"] = dream.get("trace", {})
	var world_day = int(tick / 24)
	var memory_id = "dream:%s:%s:%d" % [svc.world_id, npc_id, tick]
	var memory = svc._backstory_service.add_dream_memory(memory_id, npc_id, dream_text, world_day, influence, 0.55, 0.65, metadata)
	if not bool(memory.get("ok", false)):
		return svc._emit_dependency_error(tick, "dream_memory", "backstory_write_failed")
	var effect = svc._dreams.compute_dream_effect(dream_text)
	var next_state: Dictionary = svc._dreams.apply_dream_effect(state, effect)
	villager_state.from_dict(next_state)
	svc._persist_llm_trace_event(tick, "dream_generation", [npc_id], dream.get("trace", {}))
	svc.emit_signal("villager_dream_recorded", npc_id, tick, memory_id, dream_text, effect)
	return true

static func run_resource_pipeline(svc, tick: int, npc_ids: Array) -> void:
	svc._last_market_prices = svc._economy_system.compute_market_prices(svc._community_ledger)
	svc._log_resource_event(tick, "sim_transfer_event", "community", "community_main", {"kind": "market_price_update", "prices": svc._last_market_prices.duplicate(true)})
	for npc_id in npc_ids:
		var villager_state_resource = svc._villagers.get(npc_id, null)
		if villager_state_resource == null:
			continue
		var villager_state: Dictionary = villager_state_resource.to_dict()
		var econ_state = svc._individual_ledgers.get(npc_id, svc._individual_ledger_system.initial_individual_ledger(npc_id))
		var production: Dictionary = svc._economy_system.villager_production(villager_state, econ_state, tick)
		svc._community_ledger = svc._community_ledger_system.deposit(svc._community_ledger, {"food": float(production.get("food", 0.0)), "water": float(production.get("water", 0.0)), "wood": float(production.get("wood", 0.0)), "stone": float(production.get("stone", 0.0)), "tools": float(production.get("tools", 0.0)), "currency": float(production.get("currency", 0.0))})
		econ_state.wage_due += float(production.get("wage_due", 0.0))
		svc._individual_ledgers[npc_id] = svc._individual_ledger_system.ensure_bounds(econ_state)
		svc._log_resource_event(tick, "sim_production_event", "individual", npc_id, {"production": production.duplicate(true)})

	svc._community_ledger = svc._community_ledger_system.produce(svc._community_ledger, svc._villagers.size(), tick)
	svc._log_resource_event(tick, "sim_production_event", "community", "community_main", {"delta": {"food": 0.18 * svc._villagers.size() * (1.0 if (tick % 24) < 18 else 0.65), "water": 0.14 * svc._villagers.size(), "wood": 0.05 * svc._villagers.size(), "stone": 0.03 * svc._villagers.size(), "currency": 0.02 * svc._villagers.size()}})
	svc._community_ledger = svc._community_ledger_system.consume_upkeep(svc._community_ledger, 1.0)
	svc._log_resource_event(tick, "sim_transfer_event", "community", "community_main", {"kind": "upkeep", "delta": {"tools": -0.03, "wood": -0.04, "stone": -0.02}})

	var household_ids = svc._household_members.keys()
	household_ids.sort()
	for household_id_variant in household_ids:
		var household_id = String(household_id_variant)
		var members_resource = svc._household_members.get(household_id, null)
		var members: Array = members_resource.member_ids if members_resource != null else []
		var household_ledger = svc._household_ledgers.get(household_id, svc._household_ledger_system.initial_household_ledger(household_id))
		var transport_capacity = svc._economy_system.total_transport_capacity(members, svc._carry_profiles)
		var ration_request: Dictionary = svc._household_ledger_system.ration_request_for_members(members.size(), svc._transfer_rules)
		var conservation = svc._cultural_policy_strength("water_conservation")
		if conservation > 0.0:
			ration_request["water"] = maxf(0.0, float(ration_request.get("water", 0.0)) * (1.0 + conservation * 0.14))
		var withdrawal: Dictionary = svc._community_ledger_system.withdraw(svc._community_ledger, ration_request)
		svc._community_ledger = withdrawal.get("ledger", svc._community_ledger)
		var ration_granted: Dictionary = withdrawal.get("granted", {})
		var ration_transport: Dictionary = svc._economy_system.allocate_carrier_assignments(ration_granted, members, svc._carry_profiles)
		var route_adjusted = svc._apply_route_transport(ration_transport.get("assignments", {}), svc._community_anchor_position, svc._household_position(household_id), tick)
		var ration_moved: Dictionary = route_adjusted.get("moved_payload", {})
		var ration_unmoved: Dictionary = svc._merge_payloads(ration_transport.get("remaining_payload", {}), route_adjusted.get("unmoved_payload", {}))
		if not ration_unmoved.is_empty():
			svc._community_ledger = svc._community_ledger_system.deposit(svc._community_ledger, ration_unmoved)
		svc._apply_carry_assignments(members, route_adjusted.get("assignments", {}))
		svc._log_resource_event(tick, "sim_transfer_event", "household", household_id, {"kind": "community_ration", "requested": ration_request.duplicate(true), "granted": ration_granted.duplicate(true), "moved": ration_moved.duplicate(true), "unmoved": ration_unmoved.duplicate(true), "transport_capacity_weight": transport_capacity, "route_profiles": route_adjusted.get("route_profiles", {})})
		svc._household_growth_metrics[household_id] = {"throughput": svc._sum_payload(ration_moved), "path_strength": svc._mean_route_path_strength(route_adjusted.get("route_profiles", {}))}
		household_ledger = svc._household_ledger_system.apply_ration(household_ledger, ration_moved)
		var trade_step: Dictionary = svc._economy_system.household_trade_step(household_ledger, svc._community_ledger, svc._last_market_prices, transport_capacity)
		household_ledger = trade_step.get("household", household_ledger)
		svc._community_ledger = trade_step.get("community", svc._community_ledger)
		var trades: Array = trade_step.get("trades", [])
		if not trades.is_empty():
			var trade_payload: Dictionary = trade_step.get("transport_payload", {})
			var trade_transport: Dictionary = svc._economy_system.allocate_carrier_assignments(trade_payload, members, svc._carry_profiles)
			svc._apply_carry_assignments(members, trade_transport.get("assignments", {}))
			svc._log_resource_event(tick, "sim_transfer_event", "household", household_id, {"kind": "market_trade", "trades": trades, "spent": float(trade_step.get("spent", 0.0)), "earned": float(trade_step.get("earned", 0.0)), "transport_payload": trade_payload.duplicate(true), "transport_weight_used": float(trade_step.get("transport_weight_used", 0.0)), "transport_capacity_weight": float(trade_step.get("transport_capacity_weight", 0.0))})
		var household_before = household_ledger.to_dict()
		household_ledger = svc._household_ledger_system.consume_for_members(household_ledger, members.size(), svc._transfer_rules)
		svc._log_resource_event(tick, "sim_transfer_event", "household", household_id, {"kind": "household_consumption", "member_count": members.size(), "before": {"food": float(household_before.get("food", 0.0)), "water": float(household_before.get("water", 0.0))}, "after": {"food": float(household_ledger.food), "water": float(household_ledger.water)}})
		for npc_id_variant in members:
			var member_npc_id = String(npc_id_variant)
			var econ_state_member = svc._individual_ledgers.get(member_npc_id, svc._individual_ledger_system.initial_individual_ledger(member_npc_id))
			var inv_before = econ_state_member.inventory.to_dict()
			econ_state_member = svc._individual_ledger_system.distribute_from_household(econ_state_member, household_ledger, 0.25)
			econ_state_member = svc._individual_ledger_system.consume_personal(econ_state_member, svc._transfer_rules)
			var wage_due = float(econ_state_member.wage_due)
			if wage_due > 0.0:
				var wage_result: Dictionary = svc._community_ledger_system.withdraw(svc._community_ledger, {"currency": wage_due})
				svc._community_ledger = wage_result.get("ledger", svc._community_ledger)
				var wage_granted = float(wage_result.get("granted", {}).get("currency", 0.0))
				econ_state_member = svc._individual_ledger_system.pay_wage(econ_state_member, wage_granted)
				svc._log_resource_event(tick, "sim_transfer_event", "individual", member_npc_id, {"kind": "wage_payment", "wage_due": wage_due, "wage_paid": wage_granted})
			econ_state_member = svc._individual_ledger_system.ensure_bounds(econ_state_member)
			svc._individual_ledgers[member_npc_id] = econ_state_member
			svc._log_resource_event(tick, "sim_transfer_event", "individual", member_npc_id, {"kind": "household_distribution_and_personal_consumption", "before": {"food": float(inv_before.get("food", 0.0)), "water": float(inv_before.get("water", 0.0)), "currency": float(inv_before.get("currency", 0.0)), "energy": float(econ_state_member.energy)}, "after": {"food": float(econ_state_member.inventory.food), "water": float(econ_state_member.inventory.water), "currency": float(econ_state_member.inventory.currency), "energy": float(econ_state_member.energy)}})
		var taxed: Dictionary = svc._household_ledger_system.collect_tax(household_ledger, svc._transfer_rules)
		household_ledger = taxed.get("ledger", household_ledger)
		var tax_amount = float(taxed.get("tax", 0.0))
		svc._community_ledger = svc._community_ledger_system.deposit(svc._community_ledger, {"currency": tax_amount})
		svc._log_resource_event(tick, "sim_transfer_event", "household", household_id, {"kind": "tax_paid", "currency": tax_amount})
		household_ledger = svc._household_ledger_system.enforce_non_negative(household_ledger)
		svc._household_ledgers[household_id] = household_ledger

	var waste_step: Dictionary = svc._economy_system.process_waste(svc._community_ledger, svc._household_ledgers, svc._individual_ledgers)
	svc._community_ledger = waste_step.get("community", svc._community_ledger)
	svc._household_ledgers = waste_step.get("households", svc._household_ledgers)
	svc._individual_ledgers = waste_step.get("individuals", svc._individual_ledgers)
	var taboo_compliance = svc._cultural_policy_strength("water_taboo_compliance")
	if taboo_compliance > 0.0:
		var waste_before = float(svc._community_ledger.waste)
		var reduction = waste_before * taboo_compliance * 0.18
		if reduction > 0.0:
			svc._community_ledger.waste = maxf(0.0, waste_before - reduction)
			svc._log_resource_event(tick, "sim_culture_event", "settlement", "settlement_main", {"kind": "taboo_compliance", "event": {"policy": "water_taboo_compliance", "salience": taboo_compliance, "gain_loss": 0.0, "waste_reduction": reduction}})
	svc._log_resource_event(tick, "sim_transfer_event", "community", "community_main", {"kind": "waste_processing", "incoming_waste": float(waste_step.get("incoming_waste", 0.0)), "processed_waste": float(waste_step.get("processed_waste", 0.0)), "recycled_wood": float(waste_step.get("recycled_wood", 0.0)), "recycled_currency": float(waste_step.get("recycled_currency", 0.0))})
	svc._community_ledger = svc._community_ledger_system.clamp_to_capacity(svc._community_ledger)
	svc._assert_resource_invariants(tick, npc_ids)
