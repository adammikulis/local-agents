@tool
extends RefCounted
class_name LocalAgentsTestRunnerHelper

var failures: Array[String] = []

func run_script_case(tree: SceneTree, script_path: String) -> bool:
	var script := load(script_path)
	if script == null:
		_record_failure(script_path, "Failed to load script")
		return false
	if not script.has_method("new"):
		_record_failure(script_path, "Script is not instantiable")
		return false
	var instance = script.new()
	if instance == null or not instance.has_method("run_test"):
		_record_failure(script_path, "run_test method missing")
		return false
	print("==> Running %s" % script_path)
	var result = instance.run_test(tree)
	var ok := true
	if typeof(result) == TYPE_BOOL:
		ok = result
	if ok:
		print("==> %s passed" % script_path)
		return true
	_record_failure(script_path, "Reported failure")
	return false

func run_script_suite(tree: SceneTree, scripts: Array[String]) -> bool:
	var ok = true
	for script_path in scripts:
		ok = run_script_case(tree, script_path) and ok
	return ok

func run_scene_tree_script(script_path: String, args: Array[String]) -> Dictionary:
	var packed_args: PackedStringArray = PackedStringArray(args)
	var output: Array = []
	var cmd: PackedStringArray = PackedStringArray(["--headless", "--no-window", "--path", ".", "-s", script_path])
	for arg in packed_args:
		cmd.append(arg)
	var code = OS.execute(OS.get_executable_path(), cmd, output, true)
	return {
		"code": code,
		"output": "\n".join(output),
	}

func quit_with_summary(tree: SceneTree) -> void:
	if failures.is_empty():
		print("All selected tests passed.")
		tree.quit(0)
		return
	for line in failures:
		push_error(line)
	tree.quit(1)

func _record_failure(name: String, message: String) -> void:
	failures.append("%s: %s" % [name, message])
