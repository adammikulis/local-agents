@tool
extends RefCounted

const TestModelHelper := preload("res://addons/local_agents/tests/test_model_helper.gd")
const LlamaServerManager := preload("res://addons/local_agents/runtime/LlamaServerManager.gd")

func run_test(_tree: SceneTree) -> bool:
    if not Engine.has_singleton("AgentRuntime"):
        push_error("AgentRuntime unavailable for llama-server embeddings e2e test")
        return false
    var runtime := Engine.get_singleton("AgentRuntime")
    if runtime == null or not runtime.has_method("embed_text"):
        push_error("AgentRuntime.embed_text unavailable")
        return false

    var helper := TestModelHelper.new()
    var model_path := helper.ensure_local_model()
    if model_path.strip_edges() == "":
        push_error("llama-server embeddings e2e test requires a local model")
        return false

    var manager = LlamaServerManager.new()
    var boot: Dictionary = manager.ensure_running({
        "server_base_url": "http://127.0.0.1:18081",
        "server_start_timeout_ms": 45000,
        "server_ready_timeout_ms": 2000,
        "server_autostart": true,
        "server_shutdown_on_exit": true,
    }, model_path, "")
    if not bool(boot.get("ok", false)):
        push_error("Failed to start llama-server for embedding test: %s" % JSON.stringify(boot, "", false, true))
        return false

    var embedding: PackedFloat32Array = runtime.call("embed_text", "EmbeddingGemma is running.", {
        "backend": "llama_server",
        "server_base_url": "http://127.0.0.1:18081",
        "server_model": "local-agents",
        "normalize": true,
    })
    var ok := not embedding.is_empty()
    if ok:
        ok = ok and embedding.size() >= 64

    var stopped: Dictionary = manager.stop_managed()
    ok = ok and bool(stopped.get("ok", false))
    if not ok:
        push_error("llama-server embeddings e2e test failed")
        return false
    print("llama-server embeddings e2e test passed")
    return true
