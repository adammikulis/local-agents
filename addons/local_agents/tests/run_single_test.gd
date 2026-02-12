@tool
extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var script_path := _test_script_from_args()
	if script_path == "":
		push_error("Missing --test=<res://...> argument")
		quit(2)
		return
	var script := load(script_path)
	if script == null:
		push_error("Failed to load test script: %s" % script_path)
		quit(2)
		return
	if not script.has_method("new"):
		push_error("Script is not instantiable: %s" % script_path)
		quit(2)
		return
	var instance = script.new()
	if instance == null or not instance.has_method("run_test"):
		push_error("run_test method missing: %s" % script_path)
		quit(2)
		return
	print("==> Running %s" % script_path)
	var result = instance.run_test(self)
	var ok := true
	if typeof(result) == TYPE_BOOL:
		ok = result
	if ok:
		print("==> %s passed" % script_path)
		quit(0)
	else:
		push_error("==> %s failed" % script_path)
		quit(1)

func _test_script_from_args() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--test="):
			return arg.trim_prefix("--test=").strip_edges()
	return ""
