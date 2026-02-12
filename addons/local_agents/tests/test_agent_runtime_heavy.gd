@tool
extends RefCounted

const TestModelHelper := preload("res://addons/local_agents/tests/test_model_helper.gd")

func run_test(_tree: SceneTree) -> bool:
    if not Engine.has_singleton("AgentRuntime"):
        push_error("AgentRuntime singleton unavailable. Build the GDExtension before running tests.")
        return false

    var runtime := Engine.get_singleton("AgentRuntime")
    if runtime == null:
        push_error("AgentRuntime singleton missing.")
        return false

    var model_helper := TestModelHelper.new()
    var model_path := model_helper.ensure_local_model()
    if model_path.strip_edges() == "":
        push_error("Heavy AgentRuntime test requires a local model. Auto-download failed.")
        return false
    OS.set_environment("LOCAL_AGENTS_TEST_GGUF", model_path)

    var resolved_path := _normalize_path(model_path)
    if not FileAccess.file_exists(resolved_path):
        push_error("Heavy test model not found at %s" % resolved_path)
        return false

    var loaded := bool(runtime.call("load_model", resolved_path, {
        "context_size": 64,
        "embedding": true,
        "max_tokens": 16,
        "n_gpu_layers": 0,
    }))
    if not loaded:
        push_error("Failed to load model for heavy test")
        return false

    var ok := bool(runtime.call("is_model_loaded"))
    var health: Dictionary = runtime.call("get_runtime_health")
    ok = ok and health.has("runtime_directory_exists")
    ok = ok and bool(health.get("model_loaded", false))
    ok = ok and bool(health.get("default_model_exists", false))
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
            "max_tokens": 16,
            "temperature": 0.2,
        },
    })
    ok = ok and bool(response.get("ok", false))
    var text := String(response.get("text", "")).strip_edges()
    ok = ok and text.length() > 0

    var json_response: Dictionary = runtime.call("generate", {
        "prompt": "Return only JSON: {\"status\":\"ok\"}",
        "options": {
            "max_tokens": 64,
            "temperature": 0.1,
            "stop": ["\nuser:"],
            "response_format": {"type": "json_object"},
            "json_schema": {
                "type": "object",
                "required": ["status"],
            },
        },
    })
    var json_ok := bool(json_response.get("ok", false))
    if not json_ok:
        var json_error := String(json_response.get("error", ""))
        ok = ok and json_error in ["json_parse_failed", "json_schema_validation_failed"]
    else:
        ok = ok and typeof(json_response.get("json", null)) == TYPE_DICTIONARY
    if json_ok and typeof(json_response.get("json", null)) == TYPE_DICTIONARY:
        var parsed: Dictionary = json_response.get("json", {})
        ok = ok and String(parsed.get("status", "")).strip_edges() != ""

    if not ok:
        push_error("Heavy generation response invalid: %s | json=%s" % [JSON.stringify(response), JSON.stringify(json_response)])

    runtime.call("unload_model")
    if ok:
        print("Local Agents heavy runtime test passed")
    return ok

func _normalize_path(path: String) -> String:
    if path.begins_with("res://") or path.begins_with("user://"):
        return ProjectSettings.globalize_path(path)
    return path
