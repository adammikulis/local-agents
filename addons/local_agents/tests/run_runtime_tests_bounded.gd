@tool
extends SceneTree

const TestLaneRegistry := preload("res://addons/local_agents/tests/test_lane_registry.gd")

const RUNTIME_TESTS := TestLaneRegistry.RUNTIME_HEAVY_TESTS
const FAST_RUNTIME_TESTS := [
	"res://addons/local_agents/tests/test_agent_integration.gd",
	"res://addons/local_agents/tests/test_llama_server_e2e.gd",
]
const SUITE_RUNTIME := "runtime"
const SUITE_FAST := "fast"
const DEFAULT_SUITE := SUITE_RUNTIME

const TestModelHelper := preload("res://addons/local_agents/tests/test_model_helper.gd")
const AgentResultReporter := preload("res://addons/local_agents/tests/agent_result_reporter.gd")
const CmdlineArgs := preload("res://addons/local_agents/runtime/CmdlineArgs.gd")
const DEFAULT_TIMEOUT_SECONDS := 120
const GPU_MOBILE_TIMEOUT_SECONDS := 180

var _started_ms: int = 0

var _timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS
var _poll_interval_seconds: float = 0.25
var _failures: Array[String] = []
var _selected_tests: Array[String] = []
var _fast_mode: bool = false
var _suite: String = DEFAULT_SUITE
var _suite_parse_failed: bool = false
var _workers: int = 1
var _processes: Dictionary = {}
var _gpu_enabled: bool = false
var _gpu_layers: int = 0
var _override_context_size: int = 0
var _override_max_tokens: int = 0

func _init() -> void:
	_fast_mode = CmdlineArgs.has_flag("--fast")
	_gpu_enabled = CmdlineArgs.has_flag("--use-gpu")
	_gpu_layers = CmdlineArgs.int_value("--gpu-layers=", 0)
	_override_context_size = CmdlineArgs.int_value("--context-size=", 0)
	_override_max_tokens = CmdlineArgs.int_value("--max-tokens=", 0)
	_suite = _suite_from_args()
	_timeout_seconds = _timeout_from_args()
	_workers = _workers_from_args()
	_selected_tests = _tests_from_args()
	_started_ms = Time.get_ticks_msec()
	call_deferred("_run_all")

func _run_all() -> void:
	if _suite_parse_failed:
		quit(1)
		return
	if _selected_tests.is_empty():
		_selected_tests = _default_tests_for_suite()
	if not _validate_selected_tests():
		quit(1)
		return
	var model_helper = TestModelHelper.new()
	var ensured := model_helper.ensure_local_model()
	if ensured == "":
		push_error("Failed to auto-download required test model")
		quit(1)
		return
	OS.set_environment("LOCAL_AGENTS_TEST_GGUF", ensured)
	OS.set_environment("LOCAL_AGENTS_TEST_FAST", "1" if _fast_mode else "0")
	OS.set_environment("LOCAL_AGENTS_TEST_USE_GPU", "1" if _gpu_enabled else "0")
	if _gpu_layers > 0:
		OS.set_environment("LOCAL_AGENTS_TEST_GPU_LAYERS", str(_gpu_layers))
	if _override_context_size > 0:
		OS.set_environment("LOCAL_AGENTS_TEST_CONTEXT_SIZE", str(_override_context_size))
	if _override_max_tokens > 0:
		OS.set_environment("LOCAL_AGENTS_TEST_MAX_TOKENS", str(_override_max_tokens))
	OS.set_environment("LOCAL_AGENTS_HEAVY_TIMEOUT_SEC", str(_timeout_seconds))
	await _run_all_bounded()

	var duration_s := float(Time.get_ticks_msec() - _started_ms) / 1000.0
	var failed := _failures.size()
	AgentResultReporter.emit("bounded", maxi(0, _selected_tests.size() - failed), failed, _failures, duration_s)
	if _failures.is_empty():
		print("All bounded runtime tests passed.")
		quit(0)
		return
	push_error("Bounded runtime test failures:")
	for script_path in _failures:
		push_error("  - %s" % script_path)
	quit(1)

func _run_all_bounded() -> void:
	var queue: Array[String] = []
	queue.append_array(_selected_tests)
	while not queue.is_empty() or not _processes.is_empty():
		while _processes.size() < _workers and not queue.is_empty():
			var script_path = String(queue.pop_front())
			_start_case_process(script_path)
		var done_pids: Array = []
		var pids = _processes.keys()
		pids.sort()
		for pid_variant in pids:
			var pid = int(pid_variant)
			var info: Dictionary = _processes.get(pid, {})
			var script_path = String(info.get("script_path", ""))
			var started_ms = int(info.get("started_ms", Time.get_ticks_msec()))
			if not OS.is_process_running(pid):
				var exit_code := OS.get_process_exit_code(pid)
				if exit_code == 0:
					print("==> %s passed" % script_path)
				else:
					push_error("==> %s failed with exit code %d" % [script_path, exit_code])
					_failures.append(script_path)
				done_pids.append(pid)
				continue
			var elapsed_ms: int = int(Time.get_ticks_msec() - started_ms)
			var timeout_ms := maxi(1, _timeout_seconds) * 1000
			if elapsed_ms < timeout_ms:
				continue
			var kill_error := OS.kill(pid)
			if kill_error != OK:
				push_error("Timeout on %s and failed to kill pid %d" % [script_path, pid])
			push_error("Timed out after %ss: %s" % [_timeout_seconds, script_path])
			_failures.append(script_path)
			done_pids.append(pid)
		for pid_variant in done_pids:
			_processes.erase(int(pid_variant))
		if queue.is_empty() and _processes.is_empty():
			break
		await create_timer(_poll_interval_seconds).timeout

func _start_case_process(script_path: String) -> void:
	print("==> Running %s (timeout=%ss)" % [script_path, _timeout_seconds])
	var executable := OS.get_executable_path()
	var args := PackedStringArray([
		"--headless",
		"--no-window",
		"-s",
		"res://addons/local_agents/tests/run_single_test.gd",
		"--",
		"--test=%s" % script_path,
		"--timeout=%d" % _timeout_seconds,
	])
	var pid := OS.create_process(executable, args, false)
	if pid <= 0:
		push_error("Failed to spawn process for %s" % script_path)
		_failures.append(script_path)
		return
	_processes[pid] = {
		"script_path": script_path,
		"started_ms": Time.get_ticks_msec(),
	}

func _timeout_from_args() -> int:
	for arg in CmdlineArgs.all():
		if arg.begins_with("--timeout-sec="):
			return maxi(30, int(arg.trim_prefix("--timeout-sec=")))
		if arg.begins_with("--timeout="):
			return maxi(30, int(arg.trim_prefix("--timeout=")))
	if _gpu_enabled:
		return GPU_MOBILE_TIMEOUT_SECONDS
	return DEFAULT_TIMEOUT_SECONDS

func _workers_from_args() -> int:
	for arg in CmdlineArgs.all():
		if arg.begins_with("--workers="):
			return maxi(1, int(arg.trim_prefix("--workers=")))
	return 1

func _tests_from_args() -> Array[String]:
	var selected: Array[String] = []
	for arg in CmdlineArgs.all():
		if not arg.begins_with("--tests="):
			continue
		var raw = arg.trim_prefix("--tests=").strip_edges()
		if raw == "":
			continue
		var tokens = raw.split(",", false)
		for token_variant in tokens:
			var token = String(token_variant).strip_edges()
			if token == "":
				continue
			var resolved = TestLaneRegistry.resolve(token, RUNTIME_TESTS)
			if resolved == "":
				selected.append(token)
				continue
			if not selected.has(resolved):
				selected.append(resolved)
	return selected

func _validate_selected_tests() -> bool:
	var ok := true
	for script_path in _selected_tests:
		if RUNTIME_TESTS.has(script_path):
			continue
		push_error("Unknown runtime test in --tests filter: %s" % script_path)
		ok = false
	if ok and _selected_tests.is_empty():
		push_error("No runtime tests selected")
		ok = false
	return ok

func _suite_from_args() -> String:
	for arg in CmdlineArgs.all():
		if not arg.begins_with("--suite="):
			continue
		var raw = arg.trim_prefix("--suite=").strip_edges().to_lower()
		if raw == "":
			continue
		if raw == SUITE_RUNTIME or raw == SUITE_FAST:
			return raw
		push_error("Unknown runtime test suite: %s" % raw)
		_suite_parse_failed = true
		return ""
	return SUITE_FAST if _fast_mode else DEFAULT_SUITE

func _default_tests_for_suite() -> Array[String]:
	var selected: Array[String] = []
	if _suite == SUITE_FAST:
		selected.append_array(FAST_RUNTIME_TESTS)
		return selected
	selected.append_array(RUNTIME_TESTS)
	return selected
