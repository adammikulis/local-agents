extends SceneTree

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var runner: RefCounted = preload("res://addons/local_agents/tests/check_llm_http_stream.gd").new()
    var passed: bool = await runner.run_test(self)
    quit(0 if passed else 1)
