@tool
extends SceneTree

var _did_finish := false
var _timeout_seconds := 180.0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_timeout_seconds = _timeout_from_args()
	if _timeout_seconds <= 0.0:
		push_error("Invalid --timeout value; expected > 0 seconds")
		_finish(2)
		return
	_arm_timeout_watchdog()

	var script_path := _test_script_from_args()
	if script_path == "":
		_fail(2, "Missing --test=<res://...> argument")
		return
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
	if result is GDScriptFunctionState:
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
	return 180.0

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
