@tool
extends RefCounted

const Status: GDScript = preload("res://addons/local_agents/runtime/AgentStatus.gd")
const TestModelHelper: GDScript = preload("res://addons/local_agents/tests/test_model_helper.gd")

func run_test(_tree: SceneTree) -> bool:
    var runtime: Object = Engine.get_singleton("AgentRuntime")

    var model_helper: RefCounted = TestModelHelper.new()
    var model_path: String = String(model_helper.call("ensure_local_model"))
    if model_path.strip_edges() == "":
        push_error("Heavy AgentRuntime test requires a local model. Auto-download failed.")
        return false
    OS.set_environment("LOCAL_AGENTS_TEST_GGUF", model_path)

    var resolved_path: String = _normalize_path(model_path)
    if not FileAccess.file_exists(resolved_path):
        push_error("Heavy test model not found at %s" % resolved_path)
        return false

    var load_options: Dictionary = model_helper.call("apply_runtime_overrides", {
        "context_size": 64,
        "embedding": true,
        "max_tokens": 16,
        "n_gpu_layers": 0,
    })
    var loaded: bool = Status.load_model(resolved_path, load_options)
    if not loaded:
        push_error("Failed to load model for heavy test")
        return false

    var ok: bool = bool(runtime.call("is_model_loaded"))
    var health: Dictionary = runtime.call("get_runtime_health")
    ok = ok and health.has("runtime_directory_exists")
    ok = ok and bool(health.get("model_loaded", false))
    ok = ok and bool(health.get("default_model_exists", false))
    var next_options: Dictionary = load_options.duplicate(true)
    next_options["context_size"] = int(health["context_size"]) * 2
    next_options["batch_size"] = int(health["batch_size"])
    ok = Status.load_model(resolved_path, next_options) and ok
    health = runtime.call("get_runtime_health")
    ok = ok and int(health.get("context_size", -1)) == int(next_options["context_size"])
    ok = ok and int(health.get("batch_size", -1)) == int(next_options["batch_size"])
    ok = ok and Status.resident_model_path() == resolved_path
    next_options["temperature"] = 0.1
    ok = Status.load_model(resolved_path, next_options) and ok
    for invalid_path: Variant in [17, ""]:
        var rejected: Dictionary = runtime.call("generate", {"model_path": invalid_path, "prompt": "Do not generate."})
        ok = not bool(rejected.get("ok", true)) and ok
        ok = String(rejected.get("error", "")) == ("model_path_missing" if invalid_path is String else "invalid_model_path") and ok
    var bound_response: Dictionary = runtime.call("generate", {
        "model_path": resolved_path,
        "prompt": "Reply with one word: ok.",
        "options": next_options,
    })
    ok = bool(bound_response.get("ok", false)) and ok
    health = runtime.call("get_runtime_health")
    ok = ok and int(health.get("context_size", -1)) == int(next_options["context_size"])
    var embedding: PackedFloat32Array = runtime.call("embed_text", "Local Agents heavy test", {})
    if embedding.is_empty():
        push_warning("embed_text returned empty vector; continuing with generation validation")

    var response: Dictionary = runtime.call("generate", {
        "history": [
            {"role": "system", "content": "You are verifying Local Agents."},
            {"role": "user", "content": "Reply with exactly one word: ok."},
        ],
        "prompt": "Reply now.",
        "options": {
            "max_tokens": int(model_helper.call("max_tokens_for_tests", 16)),
            "temperature": 0.2,
        },
    })
    ok = ok and bool(response.get("ok", false))
    var text: String = String(response.get("text", "")).strip_edges()
    ok = ok and text.length() > 0

    var json_response: Dictionary = runtime.call("generate", {
        "prompt": "Return only JSON: {\"status\":\"ok\"}",
        "options": {
            "max_tokens": int(model_helper.call("max_tokens_for_tests", 64)),
            "temperature": 0.1,
            "stop": ["\nuser:"],
            "response_format": {"type": "json_object"},
            "json_schema": {
                "type": "object",
                "required": ["status"],
            },
        },
    })
    var json_ok: bool = bool(json_response.get("ok", false))
    if not json_ok:
        var json_error: String = String(json_response.get("error", ""))
        ok = ok and json_error in ["json_parse_failed", "json_schema_validation_failed"]
    else:
        ok = ok and typeof(json_response.get("json", null)) == TYPE_DICTIONARY
    if json_ok and typeof(json_response.get("json", null)) == TYPE_DICTIONARY:
        var parsed: Dictionary = json_response.get("json", {})
        ok = ok and String(parsed.get("status", "")).strip_edges() != ""

    if not ok:
        push_error("Heavy runtime validation failed: %s | json=%s | health=%s" % [JSON.stringify(response), JSON.stringify(json_response), JSON.stringify(health)])

    runtime.call("unload_model")
    if ok:
        print("Local Agents heavy runtime test passed")
    return ok

func _normalize_path(path: String) -> String:
    if path.begins_with("res://") or path.begins_with("user://"):
        return ProjectSettings.globalize_path(path)
    return path
