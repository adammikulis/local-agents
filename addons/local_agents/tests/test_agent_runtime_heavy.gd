@tool
extends SceneTree

func _init() -> void:
    if not Engine.has_singleton("AgentRuntime"):
        push_error("AgentRuntime singleton unavailable. Build the GDExtension before running tests.")
        quit()
        return

    var runtime := Engine.get_singleton("AgentRuntime")
    if runtime == null:
        push_error("AgentRuntime singleton missing.")
        quit()
        return

    var model_path := OS.get_environment("LOCAL_AGENTS_TEST_GGUF")
    if model_path.strip_edges() == "":
        print("Skipping heavy AgentRuntime test. Set LOCAL_AGENTS_TEST_GGUF to a GGUF model path to enable it.")
        quit()
        return

    var resolved_path := _normalize_path(model_path)
    if not FileAccess.file_exists(resolved_path):
        push_error("Heavy test model not found at %s" % resolved_path)
        quit()
        return

    var loaded := bool(runtime.call("load_model", resolved_path, {
        "context_size": 64,
        "embedding": true,
        "max_tokens": 16,
        "n_gpu_layers": 0,
    }))
    if not loaded:
        push_error("Failed to load GGUF model for heavy test")
        quit()
        return

    if not bool(runtime.call("is_model_loaded")):
        push_error("Model did not report as loaded for heavy test")
        runtime.call("unload_model")
        quit()
        return

    var embedding: PackedFloat32Array = runtime.call("embed_text", "Local Agents heavy test", {})
    assert(not embedding.is_empty())

    var response: Dictionary = runtime.call("generate", {
        "history": [
            {"role": "system", "content": "You are verifying Local Agents."},
            {"role": "user", "content": "Reply with a short acknowledgement."},
        ],
        "prompt": "Say ok.",
        "options": {"max_tokens": 8},
    })
    assert(response.get("ok", false))
    assert(String(response.get("text", "")).length() > 0)

    runtime.call("unload_model")

    print("Local Agents heavy runtime test passed")
    quit()

func _normalize_path(path: String) -> String:
    if path.begins_with("res://") or path.begins_with("user://"):
        return ProjectSettings.globalize_path(path)
    return path
