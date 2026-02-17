extends RefCounted
class_name LocalAgentsWorldHudBindingController

var _inspector_npc_id: String = ""
var _rolling_sim_timing_ms: Dictionary = {}
var _rolling_sim_timing_tick: int = -1
var _debug_event_lines: Array[String] = []
var _debug_last_runtime: Dictionary = {}
var _inspector_focus_pending: bool = false
const _DEBUG_EVENT_CAP := 8

func connect_simulation_hud(simulation_hud: CanvasLayer, callbacks: Dictionary) -> void:
	if simulation_hud == null:
		return
	_connect_if_present(simulation_hud, "play_pressed", callbacks.get("play", Callable()))
	_connect_if_present(simulation_hud, "pause_pressed", callbacks.get("pause", Callable()))
	_connect_if_present(simulation_hud, "fast_forward_pressed", callbacks.get("fast_forward", Callable()))
	_connect_if_present(simulation_hud, "rewind_pressed", callbacks.get("rewind", Callable()))
	_connect_if_present(simulation_hud, "fork_pressed", callbacks.get("fork", Callable()))
	_connect_if_present(simulation_hud, "inspector_npc_changed", callbacks.get("inspector_npc_changed", Callable()))
	_connect_if_present(simulation_hud, "overlays_changed", callbacks.get("overlays_changed", Callable()))
	_connect_if_present(simulation_hud, "graphics_option_changed", callbacks.get("graphics_option_changed", Callable()))

func connect_field_hud(field_hud: CanvasLayer, callbacks: Dictionary, spawn_mode: String) -> void:
	if field_hud == null:
		return
	_connect_if_present(field_hud, "spawn_mode_requested", callbacks.get("spawn_mode_requested", Callable()))
	_connect_if_present(field_hud, "spawn_random_requested", callbacks.get("spawn_random_requested", Callable()))
	_connect_if_present(field_hud, "debug_settings_changed", callbacks.get("debug_settings_changed", Callable()))
	if field_hud.has_method("set_spawn_mode"):
		field_hud.call("set_spawn_mode", spawn_mode)
	if field_hud.has_method("set_status"):
		field_hud.call("set_status", "Select mode active")

func set_field_spawn_mode(field_hud: CanvasLayer, spawn_mode: String) -> void:
	if field_hud == null:
		return
	if field_hud.has_method("set_spawn_mode"):
		field_hud.call("set_spawn_mode", spawn_mode)
	if field_hud.has_method("set_status"):
		if spawn_mode == "none":
			field_hud.call("set_status", "Select mode active")
		else:
			field_hud.call("set_status", "Click ground to spawn %s" % spawn_mode)

func set_field_random_spawn_status(field_hud: CanvasLayer, plants: int, rabbits: int) -> void:
	if field_hud != null and field_hud.has_method("set_status"):
		field_hud.call("set_status", "Spawned random: %d plants, %d rabbits" % [plants, rabbits])

func set_field_selection_restored(field_hud: CanvasLayer) -> void:
	if field_hud != null and field_hud.has_method("set_status"):
		field_hud.call("set_status", "Selection mode restored")

func on_inspector_npc_changed(npc_id: String) -> void:
	var next_id := npc_id.strip_edges()
	if next_id != "" and next_id != _inspector_npc_id:
		_inspector_focus_pending = true
	_inspector_npc_id = next_id

func push_graphics_state(simulation_hud: CanvasLayer, graphics_state: Dictionary) -> void:
	if simulation_hud != null and simulation_hud.has_method("set_graphics_state"):
		simulation_hud.call("set_graphics_state", graphics_state)

func refresh_hud(
	simulation_hud: CanvasLayer,
	simulation_controller: Node,
	loop_controller,
	last_state: Dictionary
) -> void:
	if simulation_hud == null:
		return
	var branch_id = "main"
	if simulation_controller != null and simulation_controller.has_method("get_active_branch_id"):
		branch_id = String(simulation_controller.get_active_branch_id())
	var current_tick = loop_controller.current_tick()
	var mode = "playing" if loop_controller.is_playing() else "paused"
	var year = loop_controller.simulated_year()
	var time_text = _format_duration_hms(loop_controller.simulated_seconds())
	simulation_hud.set_status_text("Year %.1f | T+%s | Tick %d | Branch %s | %s x%d" % [year, time_text, current_tick, branch_id, mode, loop_controller.ticks_per_frame()])
	_ensure_inspector_npc_selected(last_state)
	if simulation_hud.has_method("set_inspector_npc"):
		simulation_hud.set_inspector_npc(_inspector_npc_id)
	_apply_inspector_focus_if_needed(simulation_hud)
	if simulation_hud.has_method("set_details_text"):
		simulation_hud.set_details_text("\n".join(_curated_debug_lines(simulation_controller, current_tick)))
	_update_sim_timing_hud(simulation_hud, simulation_controller)

func _connect_if_present(emitter: Object, signal_name: String, callback: Callable) -> void:
	if emitter == null or callback.is_null() or not emitter.has_signal(signal_name):
		return
	if not emitter.is_connected(signal_name, callback):
		emitter.connect(signal_name, callback)

func _ensure_inspector_npc_selected(last_state: Dictionary) -> void:
	if _inspector_npc_id != "":
		return
	var villagers: Dictionary = last_state.get("villagers", {})
	var ids = villagers.keys()
	ids.sort_custom(func(a, b): return String(a) < String(b))
	if ids.is_empty():
		return
	_inspector_npc_id = String(ids[0])
	_inspector_focus_pending = true

func _apply_inspector_focus_if_needed(simulation_hud: CanvasLayer) -> void:
	if not _inspector_focus_pending or simulation_hud == null:
		return
	var tabs := simulation_hud.get_node_or_null("%HudTabContainer") as TabContainer
	if tabs == null:
		return
	tabs.current_tab = 1
	_inspector_focus_pending = false

func _curated_debug_lines(simulation_controller: Node, tick: int) -> Array[String]:
	var runtime := _read_native_dispatch_runtime(simulation_controller)
	if runtime.is_empty():
		return ["tick %d | mutation dispatch runtime unavailable" % tick]
	var contacts_total := int(runtime.get("contacts_dispatched", 0))
	var pulses_total := int(runtime.get("pulses_total", 0))
	var pulses_success := int(runtime.get("pulses_success", 0))
	var pulses_failed := int(runtime.get("pulses_failed", 0))
	var ops_applied_total := int(runtime.get("ops_applied", 0))
	var changed_chunks_total := int(runtime.get("changed_chunks", 0))
	var changed_tiles_total := int(runtime.get("changed_tiles", 0))
	var last_reason := String(runtime.get("last_drop_reason", runtime.get("last_dispatch_reason", ""))).strip_edges()
	var backend := String(runtime.get("last_backend", "gpu")).strip_edges()
	var contacts_delta := contacts_total - int(_debug_last_runtime.get("contacts_dispatched", 0))
	var pulses_delta := pulses_total - int(_debug_last_runtime.get("pulses_total", 0))
	var success_delta := pulses_success - int(_debug_last_runtime.get("pulses_success", 0))
	var failed_delta := pulses_failed - int(_debug_last_runtime.get("pulses_failed", 0))
	var ops_delta := ops_applied_total - int(_debug_last_runtime.get("ops_applied", 0))
	var chunk_delta := changed_chunks_total - int(_debug_last_runtime.get("changed_chunks", 0))
	var tile_delta := changed_tiles_total - int(_debug_last_runtime.get("changed_tiles", 0))
	if contacts_delta > 0:
		_push_debug_event("tick %d | contact with voxel: +%d (total=%d)" % [tick, contacts_delta, contacts_total])
	if pulses_delta > 0:
		_push_debug_event("tick %d | mutation dispatch start: +%d backend=%s" % [tick, pulses_delta, backend if backend != "" else "gpu"])
	if success_delta > 0:
		_push_debug_event("tick %d | mutation dispatch result: success +%d" % [tick, success_delta])
	if failed_delta > 0:
		_push_debug_event("tick %d | mutation dispatch result: failed +%d reason=%s" % [tick, failed_delta, last_reason if last_reason != "" else "unknown"])
	if ops_delta > 0:
		_push_debug_event("tick %d | mutation applied: ops +%d" % [tick, ops_delta])
	elif failed_delta > 0:
		_push_debug_event("tick %d | mutation failed: %s" % [tick, last_reason if last_reason != "" else "unknown"])
	if chunk_delta > 0 or tile_delta > 0:
		_push_debug_event("tick %d | changed summary: chunks +%d/%d tiles +%d/%d" % [tick, maxi(0, chunk_delta), changed_chunks_total, maxi(0, tile_delta), changed_tiles_total])
	_debug_last_runtime = {
		"contacts_dispatched": contacts_total,
		"pulses_total": pulses_total,
		"pulses_success": pulses_success,
		"pulses_failed": pulses_failed,
		"ops_applied": ops_applied_total,
		"changed_chunks": changed_chunks_total,
		"changed_tiles": changed_tiles_total,
	}
	if _debug_event_lines.is_empty():
		_debug_event_lines.append("tick %d | waiting for contact with voxel" % tick)
	return _debug_event_lines.duplicate()

func _read_native_dispatch_runtime(simulation_controller: Node) -> Dictionary:
	if simulation_controller == null or not simulation_controller.has_method("native_voxel_dispatch_runtime"):
		return {}
	var runtime_variant = simulation_controller.call("native_voxel_dispatch_runtime")
	return runtime_variant if runtime_variant is Dictionary else {}

func _push_debug_event(line: String) -> void:
	var clean := line.strip_edges()
	if clean == "":
		return
	_debug_event_lines.append(clean)
	while _debug_event_lines.size() > _DEBUG_EVENT_CAP:
		_debug_event_lines.remove_at(0)

func _inspector_summary_lines(_tick: int) -> Array[String]:
	var lines: Array[String] = []
	if _inspector_npc_id == "":
		lines.append("Inspector: no npc selected")
		return lines
	lines.append("Inspector NPC: %s" % _inspector_npc_id)
	lines.append("Inspector details trimmed for performance")
	return lines

func _format_duration_hms(total_seconds: float) -> String:
	var whole = maxi(0, int(floor(total_seconds)))
	var hours = int(whole / 3600)
	var minutes = int((whole % 3600) / 60)
	var seconds = int(whole % 60)
	return "%02d:%02d:%02d" % [hours, minutes, seconds]

func _update_sim_timing_hud(simulation_hud: CanvasLayer, simulation_controller: Node) -> void:
	if simulation_hud == null or not simulation_hud.has_method("set_sim_timing_text"):
		return
	if simulation_controller == null:
		simulation_hud.call("set_sim_timing_text", "SimTiming unavailable")
		return
	var profile: Dictionary = {}
	if simulation_controller.has_method("get_last_tick_profile"):
		profile = simulation_controller.call("get_last_tick_profile")
	else:
		var raw = simulation_controller.get("_last_tick_profile")
		if raw is Dictionary:
			profile = raw as Dictionary
	if profile.is_empty():
		simulation_hud.call("set_sim_timing_text", "SimTiming collecting...")
		return
	if simulation_hud.has_method("set_sim_timing_profile"):
		simulation_hud.call("set_sim_timing_profile", profile)
	var tick = int(profile.get("tick", -1))
	if tick != _rolling_sim_timing_tick:
		_rolling_sim_timing_tick = tick
		var alpha = 0.22
		var keys := [
			"total_ms",
			"transform_stage_a_ms",
			"transform_stage_b_ms",
			"transform_stage_c_ms",
			"transform_stage_d_ms",
			"resource_pipeline_ms",
			"structure_ms",
			"culture_ms",
			"cognition_ms",
			"snapshot_ms",
		]
		for key in keys:
			var value = maxf(0.0, float(profile.get(key, 0.0)))
			var prev = float(_rolling_sim_timing_ms.get(key, value))
			_rolling_sim_timing_ms[key] = value if prev <= 0.0 else lerpf(prev, value, alpha)
	var text = "SimTiming(avg ms): tot %.2f w %.2f h %.2f e %.2f s %.2f rp %.2f st %.2f c %.2f cg %.2f snap %.2f" % [
		float(_rolling_sim_timing_ms.get("total_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("transform_stage_a_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("transform_stage_b_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("transform_stage_c_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("transform_stage_d_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("resource_pipeline_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("structure_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("culture_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("cognition_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("snapshot_ms", 0.0)),
	]
	simulation_hud.call("set_sim_timing_text", text)
