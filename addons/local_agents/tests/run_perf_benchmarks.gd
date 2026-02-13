@tool
extends SceneTree

const TestRunnerHelper = preload("res://addons/local_agents/tests/test_runner_helper.gd")

var _runner := TestRunnerHelper.new()

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	# Keep benchmark args explicit and small for CI runtime bounds.
	var result = _runner.run_scene_tree_script("addons/local_agents/tests/benchmark_voxel_pipeline.gd", ["--mode=both", "--iterations=1", "--ticks=16", "--gpu-frames=24", "--width=48", "--height=48", "--world-height=32"])
	if int(result.get("code", 1)) != 0:
		push_error("benchmark_voxel_pipeline failed:\n%s" % String(result.get("output", "")))
		quit(1)
		return
	print(String(result.get("output", "")))
	quit(0)
