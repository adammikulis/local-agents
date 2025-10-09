@tool
extends SceneTree

const CORE_TESTS := [
    "res://addons/local_agents/tests/test_smoke_agent.gd",
    "res://addons/local_agents/tests/test_agent_utilities.gd",
]

const HEAVY_TEST := "res://addons/local_agents/tests/test_agent_runtime_heavy.gd"
const HEAVY_FLAG := "--include-heavy"
const TestModelHelper := preload("res://addons/local_agents/tests/test_model_helper.gd")

var _failures: Array[String] = []
var _include_heavy := false
var _model_helper := TestModelHelper.new()

func _init() -> void:
    _include_heavy = _should_include_heavy()
    call_deferred("_run_all")

func _run_all() -> void:
    for script_path in CORE_TESTS:
        _run_case(script_path)
    if _include_heavy:
        var ensured := _model_helper.ensure_local_model()
        if ensured != "":
            OS.set_environment("LOCAL_AGENTS_TEST_GGUF", ensured)
        _run_case(HEAVY_TEST)
    else:
        print("Skipping heavy runtime test. Set LOCAL_AGENTS_TEST_GGUF or pass --include-heavy to enable it.")
    _finish()

func _run_case(script_path: String) -> void:
    var script := load(script_path)
    if script == null:
        _record_failure(script_path, "Failed to load script")
        return
    if not script.has_method("new"):
        _record_failure(script_path, "Script is not instantiable")
        return
    var instance = script.new()
    if instance == null or not instance.has_method("run_test"):
        _record_failure(script_path, "run_test method missing")
        return
    print("==> Running %s" % script_path)
    var result = instance.run_test(self)
    var ok := true
    if typeof(result) == TYPE_BOOL:
        ok = result
    if ok:
        print("==> %s passed" % script_path)
    else:
        _record_failure(script_path, "Reported failure")

func _should_include_heavy() -> bool:
    if OS.has_environment("LOCAL_AGENTS_TEST_GGUF"):
        var path := OS.get_environment("LOCAL_AGENTS_TEST_GGUF").strip_edges()
        if path != "":
            return true
    for arg in OS.get_cmdline_args():
        if arg == HEAVY_FLAG:
            return true
    return false

func _record_failure(name: String, message: String) -> void:
    _failures.append("%s: %s" % [name, message])

func _finish() -> void:
    if _failures.is_empty():
        print("All Local Agents tests passed.")
        quit(0)
    else:
        push_error("Test failures detected:")
        for failure in _failures:
            push_error("  - %s" % failure)
        quit(1)
