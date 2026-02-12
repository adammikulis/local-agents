@tool
extends RefCounted

const AgentScript := preload("res://addons/local_agents/agents/Agent.gd")
const TestModelHelper := preload("res://addons/local_agents/tests/test_model_helper.gd")

func run_test(tree: SceneTree) -> bool:
    if not ClassDB.class_exists("AgentNode"):
        push_error("AgentNode unavailable; build the native extension.")
        return false

    var helper := TestModelHelper.new()
    var model_path := helper.ensure_local_model()
    if model_path.strip_edges() == "":
        push_error("llama-server e2e test requires a local model.")
        return false

    var agent = AgentScript.new()
    tree.get_root().add_child(agent)

    var server_options = helper.apply_runtime_overrides({
        "backend": "llama_server",
        "server_autostart": true,
        "server_shutdown_on_exit": true,
        "server_start_timeout_ms": 45000,
        "server_ready_timeout_ms": 2000,
        "server_base_url": "http://127.0.0.1:18080",
        "server_model_path": model_path,
        "server_model": "local-agents",
        "context_size": 4096,
        "max_tokens": 16,
        "temperature": 0.2,
        "n_gpu_layers": 0,
    })
    var result: Dictionary = agent.think(
        "Reply with exactly one word: ok.",
        server_options
    )

    var ok := bool(result.get("ok", false))
    var text := String(result.get("text", "")).strip_edges()
    ok = ok and text.length() > 0

    var stopped: Dictionary = agent.stop_managed_llama_server()
    ok = ok and bool(stopped.get("ok", false))

    agent.queue_free()
    if not ok:
        push_error("llama-server e2e test failed: %s" % JSON.stringify(result, "", false, true))
        return false
    print("llama-server e2e test passed")
    return true
