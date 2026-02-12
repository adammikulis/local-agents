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
    "res://addons/local_agents/tests/test_simulation_flowmap_bake.gd",
    "res://addons/local_agents/tests/test_simulation_erosion_delta_tiles.gd",
    "res://addons/local_agents/tests/test_simulation_environment_signal_determinism.gd",
    "res://addons/local_agents/tests/test_freeze_thaw_erosion.gd",
    "res://addons/local_agents/tests/test_solar_albedo_from_rgba.gd",
    "res://addons/local_agents/tests/test_wind_air_column_solar_heating.gd",
    "res://addons/local_agents/tests/test_simulation_voxel_terrain_generation.gd",
    "res://addons/local_agents/tests/test_simulation_water_first_spawn.gd",
    "res://addons/local_agents/tests/test_simulation_branching.gd",
    "res://addons/local_agents/tests/test_simulation_rewind_branch_diff.gd",
    "res://addons/local_agents/tests/test_simulation_path_logistics.gd",
    "res://addons/local_agents/tests/test_simulation_settlement_growth.gd",
    "res://addons/local_agents/tests/test_simulation_oral_tradition.gd",
    "res://addons/local_agents/tests/test_simulation_culture_policy_effects.gd",
    "res://addons/local_agents/tests/test_cultural_driver_json_contract.gd",
    "res://addons/local_agents/tests/test_simulation_cognition_contract.gd",
    "res://addons/local_agents/tests/test_simulation_path_decay.gd",
    "res://addons/local_agents/tests/test_path_traversal_profile.gd",
    "res://addons/local_agents/tests/test_wind_field_system.gd",
    "res://addons/local_agents/tests/test_smell_field_system.gd",
    "res://addons/local_agents/tests/test_ecology_shelter_capabilities.gd",
    "res://addons/local_agents/tests/test_structure_lifecycle_depletion.gd",
    "res://addons/local_agents/tests/test_simulation_dream_labeling.gd",
    "res://addons/local_agents/tests/test_simulation_resource_ledgers.gd",
    "res://addons/local_agents/tests/test_simulation_economy_events.gd",
]
const FAST_CORE_TESTS := [
    "res://addons/local_agents/tests/test_smoke_agent.gd",
    "res://addons/local_agents/tests/test_agent_utilities.gd",
    "res://addons/local_agents/tests/test_simulation_worldgen_determinism.gd",
    "res://addons/local_agents/tests/test_simulation_flowmap_bake.gd",
    "res://addons/local_agents/tests/test_simulation_erosion_delta_tiles.gd",
    "res://addons/local_agents/tests/test_simulation_environment_signal_determinism.gd",
    "res://addons/local_agents/tests/test_freeze_thaw_erosion.gd",
    "res://addons/local_agents/tests/test_solar_albedo_from_rgba.gd",
    "res://addons/local_agents/tests/test_wind_air_column_solar_heating.gd",
    "res://addons/local_agents/tests/test_simulation_voxel_terrain_generation.gd",
    "res://addons/local_agents/tests/test_wind_field_system.gd",
    "res://addons/local_agents/tests/test_smell_field_system.gd",
]

const LONG_TESTS := [
    "res://addons/local_agents/tests/test_simulation_vertical_slice_30day.gd",
]

const RUNTIME_TESTS := [
    "res://addons/local_agents/tests/test_simulation_villager_cognition.gd",
    "res://addons/local_agents/tests/test_simulation_no_empty_generation.gd",
    "res://addons/local_agents/tests/test_simulation_cognition_trace_isolation.gd",
    "res://addons/local_agents/tests/test_llama_server_e2e.gd",
    "res://addons/local_agents/tests/test_agent_integration.gd",
    "res://addons/local_agents/tests/test_agent_runtime_heavy.gd",
]

const HEAVY_TEST := "res://addons/local_agents/tests/test_agent_runtime_heavy.gd"
const HEAVY_FLAG := "--include-heavy"
const SKIP_HEAVY_FLAG := "--skip-heavy"
const INCLUDE_LONG_FLAG := "--include-long"
const FAST_FLAG := "--fast"
const TestModelHelper := preload("res://addons/local_agents/tests/test_model_helper.gd")
const ExtensionLoader := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")

var _failures: Array[String] = []
var _run_runtime_tests := false
var _run_long_tests := false
var _fast_mode := false
var _model_helper := TestModelHelper.new()
var _selected_core_tests: Array[String] = []
var _selected_runtime_tests: Array[String] = []
var _gpu_enabled := false
var _gpu_layers: int = 0
var _override_context_size: int = 0
var _override_max_tokens: int = 0

func _init() -> void:
    _fast_mode = _has_flag(FAST_FLAG)
    _gpu_enabled = _has_flag("--use-gpu")
    _gpu_layers = _int_arg("--gpu-layers=", 0)
    _override_context_size = _int_arg("--context-size=", 0)
    _override_max_tokens = _int_arg("--max-tokens=", 0)
    OS.set_environment("LOCAL_AGENTS_TEST_USE_GPU", "1" if _gpu_enabled else "0")
    if _gpu_layers > 0:
        OS.set_environment("LOCAL_AGENTS_TEST_GPU_LAYERS", str(_gpu_layers))
    if _override_context_size > 0:
        OS.set_environment("LOCAL_AGENTS_TEST_CONTEXT_SIZE", str(_override_context_size))
    if _override_max_tokens > 0:
        OS.set_environment("LOCAL_AGENTS_TEST_MAX_TOKENS", str(_override_max_tokens))
    _run_runtime_tests = _should_run_runtime_tests()
    _run_long_tests = _should_run_long_tests()
    _selected_core_tests = _core_tests_from_args()
    _selected_runtime_tests = _runtime_tests_from_args()
    call_deferred("_run_all")

func _run_all() -> void:
    if not ExtensionLoader.ensure_initialized():
        _record_failure("extension_init", "Runtime extension unavailable: %s" % ExtensionLoader.get_error())
        _finish()
        return
    for script_path in _selected_core_tests:
        _run_case(script_path)
    if _run_long_tests:
        for script_path in LONG_TESTS:
            _run_case(script_path)
    else:
        print("Skipping long deterministic tests (use --include-long).")
    if _run_runtime_tests:
        var ensured := _model_helper.ensure_local_model()
        if ensured == "":
            _record_failure(HEAVY_TEST, "Failed to auto-download required test model")
            _finish()
            return
        OS.set_environment("LOCAL_AGENTS_TEST_GGUF", ensured)
        for script_path in _selected_runtime_tests:
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
    for arg in _all_cmdline_args():
        if arg == SKIP_HEAVY_FLAG:
            return false
    for arg in _all_cmdline_args():
        if arg == HEAVY_FLAG:
            return true
    if _fast_mode:
        return false
    if OS.has_environment("LOCAL_AGENTS_TEST_GGUF"):
        var path := OS.get_environment("LOCAL_AGENTS_TEST_GGUF").strip_edges()
        if path != "":
            return true
    return true

func _should_run_long_tests() -> bool:
    if _fast_mode:
        return false
    for arg in _all_cmdline_args():
        if arg == INCLUDE_LONG_FLAG:
            return true
    return false

func _core_tests_from_args() -> Array[String]:
    var selected = _tests_from_arg("core-tests")
    if selected.is_empty():
        var defaults: Array[String] = []
        var source = FAST_CORE_TESTS if _fast_mode else CORE_TESTS
        for item in source:
            defaults.append(String(item))
        return defaults
    var out: Array[String] = []
    for script_path in selected:
        var resolved = _resolve_token(script_path, CORE_TESTS)
        if resolved == "":
            _record_failure("arg_parse", "Unknown core test in --core-tests filter: %s" % script_path)
            continue
        if not out.has(resolved):
            out.append(resolved)
    return out

func _runtime_tests_from_args() -> Array[String]:
    var selected = _tests_from_arg("runtime-tests")
    if selected.is_empty():
        var defaults: Array[String] = []
        for item in RUNTIME_TESTS:
            defaults.append(String(item))
        return defaults
    var out: Array[String] = []
    for script_path in selected:
        var resolved = _resolve_token(script_path, RUNTIME_TESTS)
        if resolved == "":
            _record_failure("arg_parse", "Unknown runtime test in --runtime-tests filter: %s" % script_path)
            continue
        if not out.has(resolved):
            out.append(resolved)
    return out

func _tests_from_arg(flag_name: String) -> Array[String]:
    var out: Array[String] = []
    for arg in _all_cmdline_args():
        var prefix = "--%s=" % flag_name
        if not arg.begins_with(prefix):
            continue
        var raw = arg.trim_prefix(prefix).strip_edges()
        if raw == "":
            continue
        for token_variant in raw.split(",", false):
            var token = String(token_variant).strip_edges()
            if token != "":
                out.append(token)
    return out

func _resolve_token(token: String, universe: Array) -> String:
    if universe.has(token):
        return token
    for script_path in universe:
        if script_path.ends_with("/%s" % token) or script_path.get_file() == token:
            return script_path
    return ""

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

func _all_cmdline_args() -> PackedStringArray:
    var args := PackedStringArray()
    for arg in OS.get_cmdline_args():
        args.append(arg)
    for arg in OS.get_cmdline_user_args():
        if not args.has(arg):
            args.append(arg)
    return args

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
