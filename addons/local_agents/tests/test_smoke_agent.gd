@tool
extends RefCounted

const AgentManagerScript := preload("res://addons/local_agents/agent_manager/AgentManager.gd")
const AgentScript := preload("res://addons/local_agents/agents/Agent.gd")
const ExtensionLoader := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")

func run_test(tree: SceneTree) -> bool:
    if not ExtensionLoader.ensure_initialized():
        push_error("AgentNode init failed: %s" % ExtensionLoader.get_error())
        return false
    if not ClassDB.class_exists("AgentNode"):
        push_error("AgentNode missing after extension initialization.")
        return false

    var root := tree.get_root()
    var manager := AgentManagerScript.new()
    manager.name = "AgentManager"
    root.add_child(manager)
    manager._ready()

    var agent := AgentScript.new()
    agent.name = "SmokeAgent"
    root.add_child(agent)
    agent._ready()

    var ok := true
    var agent_node = agent.get("agent_node")
    var history = agent.get("history")
    ok = ok and _assert(agent_node != null, "Agent node missing")
    ok = ok and _assert(agent_node.get_parent() == agent, "Agent node parent mismatch")
    ok = ok and _assert(history is Array and history.is_empty(), "History should start empty")

    agent.submit_user_message("ping")
    history = agent.get("history")
    ok = ok and _assert(history is Array and history.size() == 1, "History append failed")
    ok = ok and _assert(history is Array and history[0].get("role") == "user", "History role mismatch")

    agent.clear_history()
    history = agent.get("history")
    ok = ok and _assert(history is Array and history.is_empty(), "History clear failed")

    agent.queue_free()
    manager.queue_free()

    if ok:
        print("Local Agents smoke test passed")
    return ok

func _assert(condition: bool, message: String) -> bool:
    if not condition:
        push_error(message)
    return condition
