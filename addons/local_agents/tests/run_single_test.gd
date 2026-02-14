@tool
extends SceneTree

var _did_finish := false
var _timeout_seconds := 120.0
const _CANONICAL_HELPER := "scripts/run_single_test.sh"
const _TEST_ROOT := "res://addons/local_agents/tests/"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var script_path := _test_script_from_args()
	if script_path == "":
		_fail_bad_invocation("Missing required --test=<res://addons/local_agents/tests/test_*.gd> argument")
		return
	if not _is_valid_test_path(script_path):
		_fail_bad_invocation("Invalid --test path '%s'. Expected res://addons/local_agents/tests/test_*.gd" % script_path)
		return

	_timeout_seconds = _timeout_from_args()
	if _timeout_seconds <= 0.0:
		_fail_bad_invocation("Missing or invalid --timeout=<seconds> argument; expected a positive number")
		return
	_arm_timeout_watchdog()

	var script := load(script_path)
	if script == null:
		_fail(2, "Failed to load test script: %s" % script_path)
		return
	if not script.has_method("new"):
		_fail(2, "Script is not instantiable: %s" % script_path)
		return
	var instance = script.new()
	if instance == null or not instance.has_method("run_test"):
		_fail(2, "run_test method missing: %s" % script_path)
		return
	print("==> Running %s" % script_path)
	var result = instance.run_test(self)
	if _is_awaitable_result(result):
		result = await result
		if _did_finish:
			return
	var ok := true
	if typeof(result) == TYPE_BOOL:
		ok = result
	if ok:
		print("==> %s passed" % script_path)
		_finish(0)
	else:
		_fail(1, "==> %s failed" % script_path)

func _test_script_from_args() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--test="):
			return arg.trim_prefix("--test=").strip_edges()
	return ""

func _timeout_from_args() -> float:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--timeout="):
			var value := arg.trim_prefix("--timeout=").strip_edges().to_float()
			if value > 0.0:
				return value
			return -1.0
	return -1.0

func _is_valid_test_path(script_path: String) -> bool:
	if not script_path.begins_with(_TEST_ROOT):
		return false
	var file_name := script_path.trim_prefix(_TEST_ROOT)
	if file_name == "" or file_name.contains("/"):
		return false
	if not file_name.begins_with("test_"):
		return false
	return file_name.ends_with(".gd")

func _fail_bad_invocation(message: String) -> void:
	var usage := "Use %s <test_*.gd> [--timeout=120] or run: godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=%stest_example.gd --timeout=120" % [_CANONICAL_HELPER, _TEST_ROOT]
	_fail(2, "%s. %s" % [message, usage])

func _is_awaitable_result(result: Variant) -> bool:
	if result == null:
		return false
	if not (result is Object):
		return false
	# Godot 4.6 no longer resolves GDScriptFunctionState as a type literal in scripts.
	# Detect by runtime class name to keep async run_test support without parse-time coupling.
	return String((result as Object).get_class()) == "GDScriptFunctionState"

func _arm_timeout_watchdog() -> void:
	var watchdog := create_timer(_timeout_seconds)
	watchdog.timeout.connect(_on_timeout_watchdog)

func _on_timeout_watchdog() -> void:
	if _did_finish:
		return
	_fail(124, "Test timed out after %.3f seconds" % _timeout_seconds)

func _fail(code: int, message: String) -> void:
	push_error(message)
	_finish(code)

func _finish(code: int) -> void:
	if _did_finish:
		return
	_did_finish = true
	quit(code)
