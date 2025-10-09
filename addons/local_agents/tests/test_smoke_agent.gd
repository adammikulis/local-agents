@tool
extends SceneTree

func _init() -> void:
    if not ClassDB.class_exists("AgentNode"):
        push_error("AgentNode class unavailable. Build the GDExtension before running tests.")
        quit()
        return

    var agent := LocalAgentsAgent.new()
    agent.name = "SmokeAgent"
    var root := get_root()
    if root:
        root.add_child(agent)

    if not agent.is_node_ready():
        agent._ready()

    assert(agent.agent_node != null)
    assert(agent.agent_node.get_parent() == agent)
    assert(agent.history.is_empty())

    agent.submit_user_message("ping")
    assert(agent.history.size() == 1)
    assert(agent.history[0].get("role") == "user")

    agent.clear_history()
    assert(agent.history.is_empty())

    if root and agent.is_inside_tree():
        root.remove_child(agent)
    agent.queue_free()

    print("Local Agents smoke test passed")
    quit()
