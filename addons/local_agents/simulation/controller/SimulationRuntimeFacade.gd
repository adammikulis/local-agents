extends RefCounted

const FieldRegistryConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FieldRegistryConfigResource.gd")
const NativeComputeBridgeScript = preload("res://addons/local_agents/simulation/controller/NativeComputeBridge.gd")
static var _native_field_registry_session_configured: bool = false

static func ensure_native_sim_core_initialized(controller, tick: int = -1) -> bool:
	if not NativeComputeBridgeScript.is_native_sim_core_enabled():
		return true
	if _native_field_registry_session_configured:
		return true
	if not apply_native_field_registry_config(controller, null, tick):
		return false
	_native_field_registry_session_configured = true
	return true

static func generation_cap(controller, task: String, fallback: int) -> int:
	var key = "max_generations_per_tick_%s" % task
	return maxi(1, int(controller._llama_server_options.get(key, fallback)))

static func apply_native_field_registry_config(controller, config_resource, tick: int = -1) -> bool:
	if not NativeComputeBridgeScript.is_native_sim_core_enabled():
		return true
	var effective_tick = tick
	if effective_tick < 0:
		effective_tick = int(controller._last_tick_processed)
	var normalized = config_resource
	if normalized == null:
		normalized = FieldRegistryConfigResourceScript.new()
	if normalized.has_method("ensure_defaults"):
		normalized.call("ensure_defaults")
	if not normalized.has_method("to_dict"):
		return controller._emit_dependency_error(effective_tick, "native_field_registry", "invalid_config_resource")
	var payload: Dictionary = normalized.call("to_dict")
	var dispatch = NativeComputeBridgeScript.dispatch_stage_call(
		controller,
		effective_tick,
		"native_field_registry",
		"configure_field_registry",
		[payload],
		true
	)
	return bool(dispatch.get("ok", false))

static func enqueue_native_voxel_edit_ops(controller, tick: int, voxel_ops: Array, strict: bool = false) -> Dictionary:
	if not NativeComputeBridgeScript.is_native_sim_core_enabled():
		if strict:
			controller._emit_dependency_error(tick, "voxel_edit_enqueue", "native_sim_core_disabled")
			return {
				"ok": false,
				"executed": false,
				"dispatched": false,
				"error": "native_sim_core_disabled",
			}
		return {
			"ok": true,
			"executed": false,
			"dispatched": false,
			"error": "",
			"fallback": true,
			"queued_count": 0,
		}
	if not ensure_native_sim_core_initialized(controller, tick):
		return {
			"ok": false,
			"executed": false,
			"dispatched": false,
			"error": "native_field_registry_unavailable",
		}
	var dispatch = NativeComputeBridgeScript.dispatch_voxel_edit_enqueue_call(
		controller,
		tick,
		"voxel_edit_enqueue",
		voxel_ops,
		strict
	)
	var native_payload = NativeComputeBridgeScript.voxel_stage_result(dispatch)
	return {
		"ok": bool(dispatch.get("ok", false)),
		"executed": bool(dispatch.get("executed", false)),
		"dispatched": NativeComputeBridgeScript.is_voxel_stage_dispatched(dispatch),
		"result": dispatch.get("result", {}),
		"voxel_result": native_payload,
		"error": String(dispatch.get("error", "")),
		"queued_count": int(native_payload.get("queued_count", 0)),
	}

static func execute_native_voxel_stage(controller, tick: int, stage_name: StringName, payload: Dictionary = {}, strict: bool = false) -> Dictionary:
	if not NativeComputeBridgeScript.is_native_sim_core_enabled():
		if strict:
			controller._emit_dependency_error(tick, "voxel_stage", "native_sim_core_disabled")
			return {
				"ok": false,
				"executed": false,
				"dispatched": false,
				"error": "native_sim_core_disabled",
			}
		return {
			"ok": true,
			"executed": false,
			"dispatched": false,
			"error": "",
			"fallback": true,
		}
	if not ensure_native_sim_core_initialized(controller, tick):
		return {
			"ok": false,
			"executed": false,
			"dispatched": false,
			"error": "native_field_registry_unavailable",
		}
	var dispatch = NativeComputeBridgeScript.dispatch_voxel_stage_call(
		controller,
		tick,
		"voxel_stage",
		stage_name,
		payload,
		strict
	)
	return {
		"ok": bool(dispatch.get("ok", false)),
		"executed": bool(dispatch.get("executed", false)),
		"dispatched": NativeComputeBridgeScript.is_voxel_stage_dispatched(dispatch),
		"result": dispatch.get("result", {}),
		"voxel_result": NativeComputeBridgeScript.voxel_stage_result(dispatch),
		"error": String(dispatch.get("error", "")),
	}

static func enqueue_thought_npcs(controller, npc_ids: Array) -> void:
	for npc_id_variant in npc_ids:
		var npc_id = String(npc_id_variant).strip_edges()
		if npc_id == "" or controller._pending_thought_npc_ids.has(npc_id):
			continue
		controller._pending_thought_npc_ids.append(npc_id)

static func enqueue_dream_npcs(controller, npc_ids: Array) -> void:
	for npc_id_variant in npc_ids:
		var npc_id = String(npc_id_variant).strip_edges()
		if npc_id == "" or controller._pending_dream_npc_ids.has(npc_id):
			continue
		controller._pending_dream_npc_ids.append(npc_id)

static func enqueue_dialogue_pairs(controller, npc_ids: Array) -> void:
	if npc_ids.size() < 2:
		return
	for index in range(0, npc_ids.size() - 1, 2):
		var source_id = String(npc_ids[index]).strip_edges()
		var target_id = String(npc_ids[index + 1]).strip_edges()
		if source_id == "" or target_id == "":
			continue
		var pair_key = "%s|%s" % [source_id, target_id]
		var already_queued = false
		for pair_variant in controller._pending_dialogue_pairs:
			if not (pair_variant is Dictionary):
				continue
			var pair = pair_variant as Dictionary
			if "%s|%s" % [String(pair.get("source_id", "")), String(pair.get("target_id", ""))] == pair_key:
				already_queued = true
				break
		if not already_queued:
			controller._pending_dialogue_pairs.append({
				"source_id": source_id,
				"target_id": target_id,
			})

static func drain_thought_queue(controller, tick: int, limit: int) -> bool:
	var consumed = 0
	while consumed < limit and not controller._pending_thought_npc_ids.is_empty():
		var npc_id = String(controller._pending_thought_npc_ids[0]).strip_edges()
		controller._pending_thought_npc_ids.remove_at(0)
		if npc_id == "":
			continue
		if not controller._run_thought_cycle(npc_id, tick):
			return false
		consumed += 1
	return true

static func drain_dream_queue(controller, tick: int, limit: int) -> bool:
	var consumed = 0
	while consumed < limit and not controller._pending_dream_npc_ids.is_empty():
		var npc_id = String(controller._pending_dream_npc_ids[0]).strip_edges()
		controller._pending_dream_npc_ids.remove_at(0)
		if npc_id == "":
			continue
		if not controller._run_dream_cycle(npc_id, tick):
			return false
		consumed += 1
	return true

static func drain_dialogue_queue(controller, tick: int, limit: int) -> bool:
	var consumed = 0
	while consumed < limit and not controller._pending_dialogue_pairs.is_empty():
		var pair_variant = controller._pending_dialogue_pairs[0]
		controller._pending_dialogue_pairs.remove_at(0)
		if not (pair_variant is Dictionary):
			continue
		var pair = pair_variant as Dictionary
		var source_id = String(pair.get("source_id", "")).strip_edges()
		var target_id = String(pair.get("target_id", "")).strip_edges()
		if source_id == "" or target_id == "":
			continue
		if not controller._run_dialogue_pair(source_id, target_id, tick):
			return false
		consumed += 1
	return true

static func apply_need_decay(controller, npc_id: String, fixed_delta: float) -> void:
	var state = controller._villagers.get(npc_id, null)
	if state == null:
		return
	state.energy = clampf(float(state.energy) - (0.004 * fixed_delta), 0.0, 1.0)
	state.hunger = clampf(float(state.hunger) + (0.006 * fixed_delta), 0.0, 1.0)

	var econ_state = controller._individual_ledgers.get(npc_id, null)
	if econ_state != null:
		econ_state.energy = clampf(float(state.energy), 0.0, 1.0)
		controller._individual_ledgers[npc_id] = controller._individual_ledger_system.ensure_bounds(econ_state)

static func generate_narrator_direction(controller, tick: int) -> bool:
	var seed = controller._rng.derive_seed("narrator", controller.world_id, controller.active_branch_id, tick)
	var result = controller._narrator.generate_direction(controller.current_snapshot(tick), seed, controller._directive_text())
	if not bool(result.get("ok", false)):
		return controller._emit_dependency_error(tick, "narrator", String(result.get("error", "narrator_failed")))
	controller._persist_llm_trace_event(tick, "narrator_direction", [], result.get("trace", {}))
	controller.emit_signal("narrator_direction_generated", tick, result.get("text", ""))
	return true

static func run_dialogue_cycle(controller, npc_ids: Array, tick: int) -> bool:
	if npc_ids.size() < 2:
		return true
	for index in range(0, npc_ids.size() - 1, 2):
		var source_id = String(npc_ids[index]).strip_edges()
		var target_id = String(npc_ids[index + 1]).strip_edges()
		if source_id == "" or target_id == "":
			continue
		if not controller._run_dialogue_pair(source_id, target_id, tick):
			return false
	return true

static func run_structure_lifecycle(controller, tick: int) -> void:
	if NativeComputeBridgeScript.is_native_sim_core_enabled():
		if not ensure_native_sim_core_initialized(controller, tick):
			return
		var dispatch = NativeComputeBridgeScript.dispatch_stage_call(
			controller,
			tick,
			"structure_lifecycle",
			"step_structure_lifecycle",
			[tick],
			true
		)
		if bool(dispatch.get("ok", false)):
			var native_result = dispatch.get("result", {})
			if native_result is Dictionary:
				var native_payload = native_result as Dictionary
				controller._structure_lifecycle_events = {
					"expanded": native_payload.get("expanded", []),
					"abandoned": native_payload.get("abandoned", []),
				}
			else:
				controller._structure_lifecycle_events = {"expanded": [], "abandoned": []}
		return
	if controller._structure_lifecycle_system == null:
		return
	var household_counts = controller._household_member_counts()
	var result: Dictionary = controller._structure_lifecycle_system.step_lifecycle(
		tick,
		household_counts,
		controller._household_growth_metrics,
		controller._household_positions,
		controller._water_network_snapshot
	)
	controller._structure_lifecycle_events = {
		"expanded": result.get("expanded", []),
		"abandoned": result.get("abandoned", []),
	}
	if not controller._structure_lifecycle_events.get("expanded", []).is_empty():
		controller._log_resource_event(tick, "sim_structure_event", "settlement", "settlement_main", {
			"kind": "structure_expansion",
			"structure_ids": controller._structure_lifecycle_events.get("expanded", []),
		})
	if not controller._structure_lifecycle_events.get("abandoned", []).is_empty():
		controller._log_resource_event(tick, "sim_structure_event", "settlement", "settlement_main", {
			"kind": "structure_abandonment",
			"structure_ids": controller._structure_lifecycle_events.get("abandoned", []),
		})

static func assert_resource_invariants(controller, tick: int, npc_ids: Array) -> void:
	for key in ["food", "water", "wood", "stone", "tools", "currency", "labor_pool", "waste"]:
		var value = float(controller._community_ledger.to_dict().get(key, 0.0))
		if value < -0.000001:
			controller._emit_dependency_error(tick, "resource_invariant", "community_negative_" + key)

	var household_ids = controller._household_ledgers.keys()
	household_ids.sort()
	for hid in household_ids:
		var ledger = controller._household_ledgers.get(String(hid), null)
		if ledger == null:
			continue
		var row = ledger.to_dict()
		for key in ["food", "water", "wood", "stone", "tools", "currency", "debt", "waste"]:
			if float(row.get(key, 0.0)) < -0.000001:
				controller._emit_dependency_error(tick, "resource_invariant", "household_negative_" + key)

	for npc_id in npc_ids:
		var state = controller._individual_ledgers.get(npc_id, null)
		if state == null:
			continue
		var row = state.to_dict()
		var inv: Dictionary = row.get("inventory", {})
		for key in ["food", "water", "currency", "tools", "waste"]:
			if float(inv.get(key, 0.0)) < -0.000001:
				controller._emit_dependency_error(tick, "resource_invariant", "individual_negative_" + key)
		if float(row.get("wage_due", 0.0)) < -0.000001:
			controller._emit_dependency_error(tick, "resource_invariant", "individual_negative_wage_due")

static func log_resource_event(controller, tick: int, event_type: String, scope: String, owner_id: String, payload: Dictionary) -> void:
	if not controller.resource_event_logging_enabled:
		return
	if controller._store == null:
		return
	var normalized_scope = scope.strip_edges()
	if normalized_scope == "":
		normalized_scope = "settlement"
	var normalized_owner = owner_id.strip_edges()
	if normalized_owner == "":
		normalized_owner = "settlement_main"
	var bundle = controller.BundleResourceScript.new()
	bundle.from_dict(payload)
	var normalized = payload.duplicate(true)
	if not bundle.to_dict().is_empty():
		normalized["resource_bundle"] = bundle.to_dict()
	var event_id: int = controller._store.append_resource_event(controller.world_id, controller.active_branch_id, tick, controller._resource_event_sequence, event_type, normalized_scope, normalized_owner, normalized)
	if event_id == -1:
		controller._store.open(controller._store_path_for_instance())
		event_id = controller._store.append_resource_event(controller.world_id, controller.active_branch_id, tick, controller._resource_event_sequence, event_type, normalized_scope, normalized_owner, normalized)
	if event_id == -1:
		controller._emit_dependency_error(tick, "resource_event_store", "append_failed")
	controller._resource_event_sequence += 1

static func persist_llm_trace_event(controller, tick: int, task: String, actor_ids: Array, trace_variant) -> void:
	if not controller.resource_event_logging_enabled:
		return
	if not (trace_variant is Dictionary):
		return
	var trace: Dictionary = trace_variant
	if trace.is_empty():
		return
	var query_keys: Array = trace.get("query_keys", [])
	var referenced_ids: Array = trace.get("referenced_ids", [])
	var normalized_actors: Array = controller._normalize_id_array(actor_ids)
	var normalized_referenced: Array = controller._normalize_id_array(referenced_ids)
	var profile_id = String(trace.get("profile_id", "")).strip_edges()
	var sampler_params: Dictionary = {}
	var sampler_variant = trace.get("sampler_params", {})
	if sampler_variant is Dictionary:
		sampler_params = (sampler_variant as Dictionary).duplicate(true)
	var payload := {
		"kind": "llm_trace",
		"task": task,
		"actor_ids": normalized_actors,
		"profile_id": profile_id,
		"seed": int(trace.get("seed", 0)),
		"query_keys": controller._normalize_id_array(query_keys),
		"referenced_ids": normalized_referenced,
		"sampler_params": sampler_params,
	}
	if controller._store == null:
		controller._emit_dependency_error(tick, "llm_trace_store", "store_unavailable")
		return
	var scope = "settlement"
	var owner_id = "settlement_main"
	if normalized_actors.size() == 1:
		scope = "individual"
		owner_id = String(normalized_actors[0])
	elif normalized_referenced.size() == 1:
		scope = "individual"
		owner_id = String(normalized_referenced[0])
	controller._log_resource_event(tick, "sim_llm_trace_event", scope, owner_id, payload)
