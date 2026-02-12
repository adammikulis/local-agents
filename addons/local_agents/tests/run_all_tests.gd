@tool
extends SceneTree

const CORE_TESTS := [
    "res://addons/local_agents/tests/test_smoke_agent.gd",
    "res://addons/local_agents/tests/test_agent_utilities.gd",
    "res://addons/local_agents/tests/test_speech_service_smoke.gd",
    "res://addons/local_agents/tests/test_llama_server_provider.gd",
    "res://addons/local_agents/tests/test_backstory_graph_service.gd",
    "res://addons/local_agents/tests/test_deterministic_simulation.gd",
    "res://addons/local_agents/tests/test_simulation_worldgen_determinism.gd",
    "res://addons/local_agents/tests/test_simulation_water_first_spawn.gd",
    "res://addons/local_agents/tests/test_simulation_path_logistics.gd",
    "res://addons/local_agents/tests/test_simulation_path_decay.gd",
    "res://addons/local_agents/tests/test_path_traversal_profile.gd",
    "res://addons/local_agents/tests/test_wind_field_system.gd",
    "res://addons/local_agents/tests/test_smell_field_system.gd",
    "res://addons/local_agents/tests/test_simulation_dream_labeling.gd",
    "res://addons/local_agents/tests/test_simulation_resource_ledgers.gd",
    "res://addons/local_agents/tests/test_simulation_economy_events.gd",
]

const RUNTIME_TESTS := [
    "res://addons/local_agents/tests/test_simulation_villager_cognition.gd",
    "res://addons/local_agents/tests/test_simulation_no_empty_generation.gd",
    "res://addons/local_agents/tests/test_llama_server_e2e.gd",
    "res://addons/local_agents/tests/test_agent_integration.gd",
    "res://addons/local_agents/tests/test_agent_runtime_heavy.gd",
]

const HEAVY_TEST := "res://addons/local_agents/tests/test_agent_runtime_heavy.gd"
const HEAVY_FLAG := "--include-heavy"
const SKIP_HEAVY_FLAG := "--skip-heavy"
const TestModelHelper := preload("res://addons/local_agents/tests/test_model_helper.gd")
const ExtensionLoader := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")

var _failures: Array[String] = []
var _run_runtime_tests := false
var _model_helper := TestModelHelper.new()

func _init() -> void:
    _run_runtime_tests = _should_run_runtime_tests()
    call_deferred("_run_all")

func _run_all() -> void:
    if not ExtensionLoader.ensure_initialized():
        _record_failure("extension_init", "Runtime extension unavailable: %s" % ExtensionLoader.get_error())
        _finish()
        return
    for script_path in CORE_TESTS:
        _run_case(script_path)
    if _run_runtime_tests:
        var ensured := _model_helper.ensure_local_model()
        if ensured == "":
            _record_failure(HEAVY_TEST, "Failed to auto-download required test model")
            _finish()
            return
        OS.set_environment("LOCAL_AGENTS_TEST_GGUF", ensured)
        for script_path in RUNTIME_TESTS:
            _run_case(script_path)
    else:
        print("Skipping runtime model tests (--skip-heavy set).")
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

func _should_run_runtime_tests() -> bool:
    for arg in OS.get_cmdline_args():
        if arg == SKIP_HEAVY_FLAG:
            return false
    for arg in OS.get_cmdline_args():
        if arg == HEAVY_FLAG:
            return true
    if OS.has_environment("LOCAL_AGENTS_TEST_GGUF"):
        var path := OS.get_environment("LOCAL_AGENTS_TEST_GGUF").strip_edges()
        if path != "":
            return true
    return true

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
