@tool
extends RefCounted

func run_test(tree: SceneTree) -> bool:
    if not ClassDB.class_exists("AgentNode"):
        push_error("AgentNode unavailable; build the native extension.")
        return false

    var root := tree.get_root()
    var manager := LocalAgentsAgentManager.new()
    manager.name = "AgentManager"
    root.add_child(manager)
    manager._ready()

    var agent := LocalAgentsAgent.new()
    agent.name = "SmokeAgent"
    root.add_child(agent)
    agent._ready()

    var ok := true
    ok = ok and _assert(agent.agent_node != null, "Agent node missing")
    ok = ok and _assert(agent.agent_node.get_parent() == agent, "Agent node parent mismatch")
    ok = ok and _assert(agent.history.is_empty(), "History should start empty")

    agent.submit_user_message("ping")
    ok = ok and _assert(agent.history.size() == 1, "History append failed")
    ok = ok and _assert(agent.history[0].get("role") == "user", "History role mismatch")

    agent.clear_history()
    ok = ok and _assert(agent.history.is_empty(), "History clear failed")

    agent.queue_free()
    manager.queue_free()

    if ok:
        print("Local Agents smoke test passed")
    return ok

func _assert(condition: bool, message: String) -> bool:
    if not condition:
        push_error(message)
    return condition
