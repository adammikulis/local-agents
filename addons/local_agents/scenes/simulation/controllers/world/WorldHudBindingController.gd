extends RefCounted
class_name LocalAgentsWorldHudBindingController

var _inspector_npc_id: String = ""
var _rolling_sim_timing_ms: Dictionary = {}
var _rolling_sim_timing_tick: int = -1

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
	_inspector_npc_id = npc_id.strip_edges()

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

	var detail_lines: Array[String] = []
	_ensure_inspector_npc_selected(last_state)
	for line in _inspector_summary_lines(current_tick):
		detail_lines.append(String(line))
	if branch_id != "main" and simulation_controller != null and simulation_controller.has_method("branch_diff"):
		var diff: Dictionary = simulation_controller.branch_diff("main", branch_id, maxi(0, current_tick - 48), current_tick)
		if bool(diff.get("ok", false)):
			var pop_delta = int(diff.get("population_delta", 0))
			var belief_delta = int(diff.get("belief_divergence", 0))
			var culture_delta = float(diff.get("culture_continuity_score_delta", 0.0))
			detail_lines.append("Diff vs main: pop %+d | belief %+d | culture %+0.3f" % [pop_delta, belief_delta, culture_delta])
	if simulation_hud.has_method("set_details_text"):
		simulation_hud.set_details_text("\n".join(detail_lines))
	if simulation_hud.has_method("set_inspector_npc"):
		simulation_hud.set_inspector_npc(_inspector_npc_id)
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
			"weather_ms",
			"hydrology_ms",
			"erosion_ms",
			"solar_ms",
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
		float(_rolling_sim_timing_ms.get("weather_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("hydrology_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("erosion_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("solar_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("resource_pipeline_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("structure_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("culture_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("cognition_ms", 0.0)),
		float(_rolling_sim_timing_ms.get("snapshot_ms", 0.0)),
	]
	simulation_hud.call("set_sim_timing_text", text)
