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
        print("Skipping heavy AgentRuntime test. Set LOCAL_AGENTS_TEST_GGUF or install llama-cli.")
        return true
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
    var embedding: PackedFloat32Array = runtime.call("embed_text", "Local Agents heavy test", {})
    ok = ok and not embedding.is_empty()

    var response: Dictionary = runtime.call("generate", {
        "history": [
            {"role": "system", "content": "You are verifying Local Agents."},
            {"role": "user", "content": "Reply with a short acknowledgement."},
        ],
        "prompt": "Say ok.",
        "options": {"max_tokens": 8},
    })
    ok = ok and response.get("ok", false)
    ok = ok and String(response.get("text", "")).length() > 0

    runtime.call("unload_model")
    if ok:
        print("Local Agents heavy runtime test passed")
    return ok

func _normalize_path(path: String) -> String:
    if path.begins_with("res://") or path.begins_with("user://"):
        return ProjectSettings.globalize_path(path)
    return path
