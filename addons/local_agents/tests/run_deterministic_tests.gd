@tool
extends SceneTree

const TestLaneRegistry = preload("res://addons/local_agents/tests/test_lane_registry.gd")
const TestRunnerHelper = preload("res://addons/local_agents/tests/test_runner_helper.gd")

var _runner := TestRunnerHelper.new()

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_runner.run_script_suite(self, TestLaneRegistry.DETERMINISTIC_TESTS)
	_runner.quit_with_summary(self)
