@tool
extends SceneTree

const RUNTIME_TESTS := [
	"res://addons/local_agents/tests/test_simulation_villager_cognition.gd",
	"res://addons/local_agents/tests/test_simulation_no_empty_generation.gd",
	"res://addons/local_agents/tests/test_simulation_cognition_trace_isolation.gd",
	"res://addons/local_agents/tests/test_llama_server_e2e.gd",
	"res://addons/local_agents/tests/test_agent_integration.gd",
	"res://addons/local_agents/tests/test_agent_runtime_heavy.gd",
]
const COGNITION_DEPENDENT_TESTS := [
	"res://addons/local_agents/tests/test_simulation_villager_cognition.gd",
	"res://addons/local_agents/tests/test_simulation_cognition_trace_isolation.gd",
]
const FAST_RUNTIME_TESTS := [
	"res://addons/local_agents/tests/test_simulation_no_empty_generation.gd",
	"res://addons/local_agents/tests/test_simulation_cognition_trace_isolation.gd",
	"res://addons/local_agents/tests/test_llama_server_e2e.gd",
]
const HEAVY_RUNTIME_TEST := "res://addons/local_agents/tests/test_agent_runtime_heavy.gd"

const TestModelHelper := preload("res://addons/local_agents/tests/test_model_helper.gd")
const DEFAULT_TIMEOUT_SECONDS := 120
const GPU_MOBILE_TIMEOUT_SECONDS := 180

var _timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS
var _poll_interval_seconds: float = 0.25
var _failures: Array[String] = []
var _selected_tests: Array[String] = []
var _fast_mode: bool = false
var _workers: int = 1
var _processes: Dictionary = {}
var _gpu_enabled: bool = false
var _gpu_layers: int = 0
var _override_context_size: int = 0
var _override_max_tokens: int = 0

func _init() -> void:
	_fast_mode = _has_flag("--fast")
	_gpu_enabled = _has_flag("--use-gpu")
	_gpu_layers = _int_arg("--gpu-layers=", 0)
	_override_context_size = _int_arg("--context-size=", 0)
	_override_max_tokens = _int_arg("--max-tokens=", 0)
	_timeout_seconds = _timeout_from_args()
	_workers = _workers_from_args()
	_selected_tests = _tests_from_args()
	call_deferred("_run_all")

func _run_all() -> void:
	if _selected_tests.is_empty():
		var default_tests: Array[String] = []
		default_tests.append_array(FAST_RUNTIME_TESTS if _fast_mode else RUNTIME_TESTS)
		_selected_tests = default_tests
	if not _validate_selected_tests():
		quit(1)
		return
	_apply_cognition_runtime_gate()
	if _selected_tests.is_empty():
		print("All selected runtime tests were skipped by gating.")
		print("All bounded runtime tests passed.")
		quit(0)
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
			_start_case_process(script_path, _timeout_for_test(script_path))
		var done_pids: Array = []
		var pids = _processes.keys()
		pids.sort()
		for pid_variant in pids:
			var pid = int(pid_variant)
			var info: Dictionary = _processes.get(pid, {})
			var script_path = String(info.get("script_path", ""))
			var timeout_seconds = int(info.get("timeout_seconds", _timeout_seconds))
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
			var timeout_ms := maxi(1, timeout_seconds) * 1000
			if elapsed_ms < timeout_ms:
				continue
			var kill_error := OS.kill(pid)
			if kill_error != OK:
				push_error("Timeout on %s and failed to kill pid %d" % [script_path, pid])
			push_error("Timed out after %ss: %s" % [timeout_seconds, script_path])
			_failures.append(script_path)
			done_pids.append(pid)
		for pid_variant in done_pids:
			_processes.erase(int(pid_variant))
		if queue.is_empty() and _processes.is_empty():
			break
		await create_timer(_poll_interval_seconds).timeout

func _start_case_process(script_path: String, timeout_seconds: int) -> void:
	print("==> Running %s (timeout=%ss)" % [script_path, timeout_seconds])
	var executable := OS.get_executable_path()
	var args := PackedStringArray([
		"--headless",
		"--no-window",
		"-s",
		"res://addons/local_agents/tests/run_single_test.gd",
		"--",
		"--test=%s" % script_path,
		"--timeout=%d" % timeout_seconds,
	])
	var pid := OS.create_process(executable, args, false)
	if pid <= 0:
		push_error("Failed to spawn process for %s" % script_path)
		_failures.append(script_path)
		return
	_processes[pid] = {
		"script_path": script_path,
		"timeout_seconds": timeout_seconds,
		"started_ms": Time.get_ticks_msec(),
	}

func _timeout_from_args() -> int:
	for arg in _all_cmdline_args():
		if arg.begins_with("--timeout-sec="):
			return maxi(30, int(arg.trim_prefix("--timeout-sec=")))
		if arg.begins_with("--timeout="):
			return maxi(30, int(arg.trim_prefix("--timeout=")))
	if _gpu_enabled:
		return GPU_MOBILE_TIMEOUT_SECONDS
	return DEFAULT_TIMEOUT_SECONDS

func _workers_from_args() -> int:
	for arg in _all_cmdline_args():
		if arg.begins_with("--workers="):
			return maxi(1, int(arg.trim_prefix("--workers=")))
	return 1

func _timeout_for_test(script_path: String) -> int:
	var timeout = _timeout_seconds
	if not _fast_mode:
		return timeout
	if script_path == HEAVY_RUNTIME_TEST:
		return timeout
	return timeout

func _has_flag(flag: String) -> bool:
	for arg in _all_cmdline_args():
		if arg == flag:
			return true
	return false

func _int_arg(prefix: String, fallback: int) -> int:
	for arg in _all_cmdline_args():
		if arg.begins_with(prefix):
			return int(arg.trim_prefix(prefix))
	return fallback

func _tests_from_args() -> Array[String]:
	var selected: Array[String] = []
	for arg in _all_cmdline_args():
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
			var resolved = _resolve_test_token(token)
			if resolved == "":
				selected.append(token)
				continue
			if not selected.has(resolved):
				selected.append(resolved)
	return selected

func _resolve_test_token(token: String) -> String:
	if RUNTIME_TESTS.has(token):
		return token
	if FAST_RUNTIME_TESTS.has(token):
		return token
	for script_path in RUNTIME_TESTS:
		if script_path.ends_with("/%s" % token) or script_path.get_file() == token:
			return script_path
	return ""

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

func _apply_cognition_runtime_gate() -> void:
	var skip_reason := _cognition_runtime_skip_reason()
	if skip_reason == "":
		return
	var kept: Array[String] = []
	var skipped: Array[String] = []
	for script_path in _selected_tests:
		if COGNITION_DEPENDENT_TESTS.has(script_path):
			skipped.append(script_path)
			continue
		kept.append(script_path)
	if skipped.is_empty():
		return
	print("Cognition runtime gate active: %s" % skip_reason)
	for script_path in skipped:
		print("==> %s skipped due to missing cognition runtime (%s)" % [script_path, skip_reason])
	_selected_tests = kept

func _cognition_runtime_skip_reason() -> String:
	if not ClassDB.class_exists("NetworkGraph"):
		return "NetworkGraph extension unavailable"
	if not Engine.has_singleton("AgentRuntime"):
		return "AgentRuntime singleton unavailable"
	var runtime = Engine.get_singleton("AgentRuntime")
	if runtime == null:
		return "AgentRuntime singleton unavailable"
	if not runtime.has_method("load_model"):
		return "AgentRuntime.load_model unavailable"
	var base_url := _cognition_backend_base_url()
	var endpoint := _parse_backend_endpoint(base_url)
	var host := String(endpoint.get("host", "127.0.0.1"))
	var port := int(endpoint.get("port", 8080))
	if not _is_tcp_endpoint_reachable(host, port, 750):
		return "cognition HTTP backend unreachable at %s" % base_url
	return ""

func _cognition_backend_base_url() -> String:
	for key in [
		"LOCAL_AGENTS_TEST_COGNITION_BASE_URL",
		"LOCAL_AGENTS_COGNITION_BASE_URL",
		"LOCAL_AGENTS_SERVER_BASE_URL",
	]:
		var value := OS.get_environment(key).strip_edges()
		if value != "":
			return value
	return "http://127.0.0.1:8080"

func _parse_backend_endpoint(base_url: String) -> Dictionary:
	var cleaned := base_url.strip_edges()
	if cleaned == "":
		return {"host": "127.0.0.1", "port": 8080}
	var scheme_idx := cleaned.find("://")
	if scheme_idx >= 0:
		cleaned = cleaned.substr(scheme_idx + 3)
	var slash_idx := cleaned.find("/")
	if slash_idx >= 0:
		cleaned = cleaned.substr(0, slash_idx)
	var host := cleaned
	var port := 8080
	var colon_idx := cleaned.rfind(":")
	if colon_idx > 0 and colon_idx < cleaned.length() - 1:
		host = cleaned.substr(0, colon_idx)
		port = int(cleaned.substr(colon_idx + 1))
	if host == "":
		host = "127.0.0.1"
	return {"host": host, "port": port}

func _is_tcp_endpoint_reachable(host: String, port: int, timeout_ms: int) -> bool:
	var peer := StreamPeerTCP.new()
	var err := peer.connect_to_host(host, port)
	if err != OK:
		return false
	var deadline_ms := Time.get_ticks_msec() + maxi(50, timeout_ms)
	while true:
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			peer.disconnect_from_host()
			return true
		if status != StreamPeerTCP.STATUS_CONNECTING:
			peer.disconnect_from_host()
			return false
		if Time.get_ticks_msec() >= deadline_ms:
			peer.disconnect_from_host()
			return false
		OS.delay_msec(25)
	return false

func _all_cmdline_args() -> PackedStringArray:
	var args := PackedStringArray()
	for arg in OS.get_cmdline_args():
		args.append(arg)
	for arg in OS.get_cmdline_user_args():
		if not args.has(arg):
			args.append(arg)
	return args
