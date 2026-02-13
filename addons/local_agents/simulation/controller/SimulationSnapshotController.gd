extends RefCounted

static func get_environment_snapshot(controller) -> Dictionary:
	return controller._environment_snapshot.duplicate(true)

static func get_water_network_snapshot(controller) -> Dictionary:
	return controller._water_network_snapshot.duplicate(true)

static func get_weather_snapshot(controller) -> Dictionary:
	return controller._weather_snapshot.duplicate(true)

static func get_erosion_snapshot(controller) -> Dictionary:
	return controller._erosion_snapshot.duplicate(true)

static func get_solar_snapshot(controller) -> Dictionary:
	return controller._solar_snapshot.duplicate(true)

static func runtime_backend_metrics(controller) -> Dictionary:
	return {
		"hydrology_compute": bool(controller._hydrology_system != null and controller._hydrology_system.has_method("is_compute_active") and controller._hydrology_system.is_compute_active()),
		"weather_compute": bool(controller._weather_system != null and controller._weather_system.has_method("is_compute_active") and controller._weather_system.is_compute_active()),
		"erosion_compute": bool(controller._erosion_system != null and controller._erosion_system.has_method("is_compute_active") and controller._erosion_system.is_compute_active()),
		"solar_compute": bool(controller._solar_system != null and controller._solar_system.has_method("is_compute_active") and controller._solar_system.is_compute_active()),
	}

static func build_environment_signal_snapshot(controller, tick: int = -1):
	var snapshot_resource = controller.EnvironmentSignalSnapshotResourceScript.new()
	snapshot_resource.tick = tick if tick >= 0 else controller._last_tick_processed
	snapshot_resource.environment_snapshot = controller._environment_snapshot.duplicate(true)
	snapshot_resource.water_network_snapshot = controller._water_network_snapshot.duplicate(true)
	snapshot_resource.weather_snapshot = controller._weather_snapshot.duplicate(true)
	snapshot_resource.erosion_snapshot = controller._erosion_snapshot.duplicate(true)
	snapshot_resource.solar_snapshot = controller._solar_snapshot.duplicate(true)
	snapshot_resource.erosion_changed = controller._erosion_changed_last_tick
	snapshot_resource.erosion_changed_tiles = controller._erosion_changed_tiles_last_tick.duplicate(true)
	return snapshot_resource

static func get_spawn_artifact(controller) -> Dictionary:
	return controller._spawn_artifact.duplicate(true)

static func get_backstory_service(controller):
	return controller._backstory_service

static func get_store(controller):
	return controller._store

static func list_llm_trace_events(controller, tick_from: int, tick_to: int, task: String = "") -> Array:
	controller._ensure_initialized()
	var out: Array = []
	if controller._store == null:
		return out
	var rows: Array = controller._store.list_resource_events(controller.world_id, controller.active_branch_id, tick_from, tick_to)
	for row_variant in rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		if String(row.get("event_type", "")) != "sim_llm_trace_event":
			continue
		var payload: Dictionary = row.get("payload", {})
		var task_name = String(payload.get("task", ""))
		if task.strip_edges() != "" and task_name != task.strip_edges():
			continue
		out.append({
			"tick": int(row.get("tick", 0)),
			"task": task_name,
			"scope": String(row.get("scope", "")),
			"owner_id": String(row.get("owner_id", "")),
			"actor_ids": payload.get("actor_ids", []),
			"profile_id": String(payload.get("profile_id", "")),
			"seed": int(payload.get("seed", 0)),
			"query_keys": payload.get("query_keys", []),
			"referenced_ids": payload.get("referenced_ids", []),
			"sampler_params": payload.get("sampler_params", {}),
		})
	out.sort_custom(func(a, b):
		var ad = a as Dictionary
		var bd = b as Dictionary
		var at = int(ad.get("tick", 0))
		var bt = int(bd.get("tick", 0))
		if at != bt:
			return at < bt
		return String(ad.get("task", "")) < String(bd.get("task", ""))
	)
	return out

static func get_active_branch_id(controller) -> String:
	return controller.active_branch_id

static func fork_branch(controller, new_branch_id: String, fork_tick: int) -> Dictionary:
	controller._ensure_initialized()
	var target = new_branch_id.strip_edges()
	if target == "":
		return {"ok": false, "error": "invalid_branch_id"}
	if target == controller.active_branch_id:
		return {"ok": false, "error": "branch_id_unchanged"}
	var entry = {
		"branch_id": controller.active_branch_id,
		"tick": maxi(0, fork_tick),
	}
	var next_lineage: Array = controller._branch_lineage.duplicate(true)
	next_lineage.append(entry)
	var fork_hash = str(hash(JSON.stringify(controller.current_snapshot(maxi(0, fork_tick)), "", false, true)))
	if controller._store != null:
		controller._store.create_checkpoint(controller.world_id, target, maxi(0, fork_tick), fork_hash, next_lineage, maxi(0, fork_tick))
	controller.active_branch_id = target
	controller._branch_lineage = next_lineage
	controller._branch_fork_tick = maxi(0, fork_tick)
	return {
		"ok": true,
		"branch_id": controller.active_branch_id,
		"lineage": controller._branch_lineage.duplicate(true),
		"fork_tick": controller._branch_fork_tick,
	}

static func restore_to_tick(controller, target_tick: int, branch_id: String = "") -> Dictionary:
	controller._ensure_initialized()
	var effective_branch = branch_id.strip_edges()
	if effective_branch == "":
		effective_branch = controller.active_branch_id
	if controller._store == null:
		return {"ok": false, "error": "store_unavailable"}
	var events: Array = controller._store.list_events(controller.world_id, effective_branch, 0, maxi(0, target_tick))
	if events.is_empty():
		return {"ok": false, "error": "snapshot_not_found", "tick": target_tick, "branch_id": effective_branch}
	var selected: Dictionary = {}
	for row_variant in events:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		if String(row.get("event_type", "")) != "tick":
			continue
		selected = row
	if selected.is_empty():
		return {"ok": false, "error": "snapshot_not_found", "tick": target_tick, "branch_id": effective_branch}
	var payload: Dictionary = selected.get("payload", {})
	if payload.is_empty():
		return {"ok": false, "error": "snapshot_payload_missing"}
	controller._apply_snapshot(payload)
	controller.active_branch_id = effective_branch
	controller._last_tick_processed = int(payload.get("tick", target_tick))
	return {"ok": true, "tick": controller._last_tick_processed, "branch_id": controller.active_branch_id}

static func branch_diff(controller, base_branch_id: String, compare_branch_id: String, tick_from: int, tick_to: int) -> Dictionary:
	controller._ensure_initialized()
	if controller._branch_analysis == null:
		return {"ok": false, "error": "branch_analysis_unavailable"}
	return controller._branch_analysis.compare_branches(
		controller._store,
		controller.world_id,
		base_branch_id,
		compare_branch_id,
		tick_from,
		tick_to,
		controller._backstory_service
	)
