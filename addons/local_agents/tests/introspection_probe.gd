@tool
extends SceneTree

# Standalone headless introspection harness.
# Boots the LocalAgents native simulation, steps N ticks, and dumps native
# introspection + profiler state as a single machine-parseable JSON line so an
# external CLI can observe live sim state headlessly.
#
# Run:
#   godot --headless --no-window -s addons/local_agents/tests/introspection_probe.gd -- --ticks=30
#
# Native/GPU-only mandate, ZERO fallback: if the native sim core or a required
# capability is unavailable, this FAILS LOUDLY with a typed reason code and
# never synthesizes a snapshot.

const ExtensionLoader := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const WorldGenConfigScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")

const NATIVE_CORE_SINGLETON := "LocalAgentsSimulationCore"
const FIXED_DELTA := 1.0 / 60.0

var _did_finish := false
var _started_ms: int = 0
var _controller = null
var _native_drive: Dictionary = {}
var _profiler_after: Dictionary = {}

func _init() -> void:
	_started_ms = Time.get_ticks_msec()
	# Native sim core is env-gated; enable before any configure call.
	OS.set_environment("LOCAL_AGENTS_ENABLE_NATIVE_SIM_CORE", "1")
	call_deferred("_run")

func _run() -> void:
	var ticks := _int_arg("--ticks", 30)
	if ticks < 1:
		ticks = 1
	var timeout_sec := _int_arg("--timeout-sec", 60)
	if timeout_sec < 1:
		timeout_sec = 1
	var seed_text := _string_arg("--seed", "introspection-probe")
	var map_size := _int_arg("--map", 20)
	if map_size < 1:
		map_size = 1
	var drive_native := _string_arg("--drive-native", "true").to_lower() != "false"
	_arm_watchdog(float(timeout_sec))

	if not ExtensionLoader.ensure_initialized():
		_fail("NATIVE_REQUIRED", "Extension loader init failed: %s" % ExtensionLoader.get_error(), {
			"ticks": ticks, "seed": seed_text,
		})
		return

	if not Engine.has_singleton(NATIVE_CORE_SINGLETON):
		_fail("NATIVE_REQUIRED", "Native singleton '%s' unavailable after extension init" % NATIVE_CORE_SINGLETON, {
			"ticks": ticks, "seed": seed_text,
		})
		return

	_controller = SimulationControllerScript.new()
	get_root().add_child(_controller)
	_controller.configure(seed_text, false, false)

	var config = WorldGenConfigScript.new()
	config.map_width = map_size
	config.map_height = map_size

	var setup: Dictionary = _controller.configure_environment(config)
	if not bool(setup.get("ok", false)):
		var reason := String(setup.get("reason", setup.get("error", "environment configure failed")))
		var code := "GPU_REQUIRED" if reason.to_lower().contains("gpu") else "NATIVE_REQUIRED"
		_fail(code, reason, {"ticks": ticks, "seed": seed_text, "setup": setup})
		return

	var tick_errors: Array = []
	for tick in range(ticks):
		if _did_finish:
			return
		var step: Dictionary = _controller.process_tick(tick, FIXED_DELTA, true, [])
		var err := _extract_tick_error(tick, step)
		if not err.is_empty():
			tick_errors.append(err)

	# Drive the native step_simulation path so the native LocalAgentsSimProfiler
	# counters populate; the GDScript process_tick loop above does not touch it.
	if drive_native and not _did_finish:
		_drive_native_steps(ticks)

	var payload := _build_success_payload(ticks, seed_text, tick_errors)
	_emit(payload)
	_finish(0)

# Best-effort native step driver. Configures the native core with an empty
# config (safe defaults) and runs step_simulation N times; each call routes
# through sim_profiler_->end_step, advancing total_steps. Records outcome and
# re-reads the post-drive profiler snapshot. Native/GPU-only: no synthesized
# success — a failing step is recorded as an error, not masked.
func _drive_native_steps(ticks: int) -> void:
	var core = Engine.get_singleton(NATIVE_CORE_SINGLETON) if Engine.has_singleton(NATIVE_CORE_SINGLETON) else null
	if core == null:
		_native_drive = {"driven": false, "reason": "core singleton missing"}
		return
	if not core.has_method("step_simulation"):
		_native_drive = {"driven": false, "reason": "step_simulation not exposed"}
		return
	var configured := false
	if core.has_method("configure"):
		configured = bool(core.call("configure", {}))
	var steps_ok := 0
	var errors: Array = []
	var last_result: Dictionary = {}
	for i in range(ticks):
		if _did_finish:
			return
		var result = core.call("step_simulation", FIXED_DELTA, i)
		if result is Dictionary:
			last_result = result
			if bool((result as Dictionary).get("ok", false)):
				steps_ok += 1
			elif (result as Dictionary).has("error"):
				errors.append({"step": i, "error": (result as Dictionary)["error"]})
		else:
			errors.append({"step": i, "error": "non-dictionary step result"})
	_native_drive = {
		"driven": true,
		"configured": configured,
		"steps_attempted": ticks,
		"steps_ok": steps_ok,
		"errors": errors,
		"last_result": last_result,
	}
	if core.has_method("get_debug_snapshot"):
		var snap = core.call("get_debug_snapshot")
		if snap is Dictionary:
			var prof = (snap as Dictionary).get("sim_profiler", null)
			if prof is Dictionary:
				_profiler_after = (prof as Dictionary).duplicate(true)

func _build_success_payload(ticks: int, seed_text: String, tick_errors: Array) -> Dictionary:
	var core = Engine.get_singleton(NATIVE_CORE_SINGLETON) if Engine.has_singleton(NATIVE_CORE_SINGLETON) else null
	var debug_snapshot := _core_call(core, "get_debug_snapshot")
	var profiler: Dictionary = {"note": "native sim_profiler from LocalAgentsSimProfiler via get_debug_snapshot()"}
	# Prefer the post-drive profiler snapshot when the native step path was driven;
	# otherwise fall back to the pre-drive profiler from the debug snapshot.
	var native_profiler = _profiler_after if not _profiler_after.is_empty() else debug_snapshot.get("sim_profiler", null)
	if native_profiler is Dictionary:
		for key in (native_profiler as Dictionary).keys():
			profiler[key] = (native_profiler as Dictionary)[key]
	else:
		profiler["available"] = false

	var payload := {
		"ok": true,
		"ticks": ticks,
		"seed": seed_text,
		"duration_s": _elapsed_s(),
		"profiler": profiler,
		"engine_performance": _engine_performance(),
		"debug_snapshot": debug_snapshot,
		"voxel_orchestration_metrics": _core_call(core, "get_voxel_orchestration_metrics"),
		"voxel_orchestration_state": _core_call(core, "get_voxel_orchestration_state"),
		"physics_contacts": _core_call(core, "get_physics_contact_snapshot"),
		"field_handles": _core_call(core, "list_field_handles_snapshot"),
		"runtime_health": _runtime_health(),
		"snapshot": _controller_snapshot(ticks),
		"native_step_drive": _native_drive,
		"tick_errors": tick_errors,
	}
	return payload

func _controller_snapshot(ticks: int) -> Dictionary:
	if _controller != null and _controller.has_method("current_snapshot"):
		var snap = _controller.current_snapshot(ticks)
		if snap is Dictionary:
			return snap
	return {}

func _core_call(core, method: String) -> Dictionary:
	if core == null:
		return {"available": false, "reason": "core singleton missing"}
	if not core.has_method(method):
		return {"available": false, "reason": "method '%s' not exposed" % method}
	var result = core.call(method)
	if result is Dictionary:
		return result
	return {"available": true, "value": result}

func _engine_performance() -> Dictionary:
	var monitors := {
		"time_fps": Performance.TIME_FPS,
		"time_process": Performance.TIME_PROCESS,
		"time_physics_process": Performance.TIME_PHYSICS_PROCESS,
		"memory_static": Performance.MEMORY_STATIC,
		"object_count": Performance.OBJECT_COUNT,
		"object_node_count": Performance.OBJECT_NODE_COUNT,
	}
	var out := {}
	for label in monitors.keys():
		var value = _safe_monitor(monitors[label])
		if value != null:
			out[label] = value
	return out

func _safe_monitor(monitor_id):
	# Guard: an unavailable monitor id can throw; return null on any failure.
	if monitor_id == null:
		return null
	var value = Performance.get_monitor(monitor_id)
	return value

func _runtime_health() -> Dictionary:
	if not Engine.has_singleton("AgentRuntime"):
		return {"available": false, "reason": "AgentRuntime singleton missing"}
	var runtime = Engine.get_singleton("AgentRuntime")
	if runtime == null or not runtime.has_method("get_runtime_health"):
		return {"available": false, "reason": "get_runtime_health not exposed"}
	var health = runtime.call("get_runtime_health")
	if health is Dictionary:
		return health
	return {"available": true, "value": health}

func _extract_tick_error(tick: int, step: Dictionary) -> Dictionary:
	var errors: Array = []
	var dep = step.get("dependency_errors", null)
	if dep is Array and not (dep as Array).is_empty():
		errors.append_array(dep as Array)
	if step.has("error"):
		errors.append(step["error"])
	if bool(step.get("ok", true)) == false and errors.is_empty():
		errors.append("tick reported ok=false")
	if errors.is_empty():
		return {}
	return {"tick": tick, "errors": errors}

func _emit(payload: Dictionary) -> void:
	print("AGENT_INTROSPECT=" + JSON.stringify(payload))

func _fail(reason: String, detail: String, extra: Dictionary) -> void:
	if _did_finish:
		return
	push_error("introspection_probe %s: %s" % [reason, detail])
	var payload := {
		"ok": false,
		"error": reason,
		"detail": detail,
		"duration_s": _elapsed_s(),
	}
	for key in extra.keys():
		payload[key] = extra[key]
	_emit(payload)
	_finish(1)

func _elapsed_s() -> float:
	return float(Time.get_ticks_msec() - _started_ms) / 1000.0

func _arm_watchdog(timeout_sec: float) -> void:
	var watchdog := create_timer(timeout_sec)
	watchdog.timeout.connect(_on_timeout)

func _on_timeout() -> void:
	if _did_finish:
		return
	push_error("introspection_probe TIMEOUT")
	_emit({"ok": false, "error": "TIMEOUT", "duration_s": _elapsed_s()})
	_finish(124)

func _finish(code: int) -> void:
	if _did_finish:
		return
	_did_finish = true
	if _controller != null and is_instance_valid(_controller):
		_controller.queue_free()
		_controller = null
	quit(code)

func _int_arg(flag: String, fallback: int) -> int:
	var raw := _string_arg(flag, "")
	if raw == "":
		return fallback
	if not raw.is_valid_int():
		return fallback
	return raw.to_int()

func _string_arg(flag: String, fallback: String) -> String:
	var prefix := flag + "="
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix).strip_edges()
	return fallback
