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
        push_error("Integration test requires a local model. Auto-download failed.")
        return false

    var agent = AgentScript.new()
    var root := tree.get_root()
    root.add_child(agent)

    var agent_node = agent.get("agent_node")
    if agent_node == null:
        push_error("Agent node failed to initialize")
        agent.queue_free()
        return false
    var loaded := bool(agent_node.call("load_model", model_path, {
        "context_size": 64,
        "embedding": true,
        "max_tokens": 24,
        "n_gpu_layers": 0,
    }))
    if not loaded:
        push_error("Failed to load model for integration test")
        agent.queue_free()
        return false

    var result := agent.call("think", "Reply with exactly one word: ok.", {
        "max_tokens": 16,
        "temperature": 0.2,
    })
    var ok: bool = bool(result.get("ok", false))
    var text := String(result.get("text", "")).strip_edges()
    ok = ok and text.length() > 0

    agent.call("clear_history")
    var history = agent.get("history")
    ok = ok and history is Array and history.is_empty()

    agent.call("submit_user_message", "ping")
    history = agent.get("history")
    ok = ok and history is Array and history.size() == 1

    agent.call("clear_history")
    agent_node.call("unload_model")
    agent.queue_free()
    if ok:
        print("Local Agents integration tests passed")
    return ok
