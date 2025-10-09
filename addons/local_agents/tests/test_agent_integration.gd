@tool
extends RefCounted

func run_test(_tree: SceneTree) -> bool:
    if not ClassDB.class_exists("AgentNode"):
        push_error("AgentNode unavailable; build the native extension.")
        return false

    var agent := LocalAgentsAgent.new()
    agent._ready()
    var result := agent.think("Hello integration")
    var ok := result.get("ok", false)
    ok = ok and String(result.get("text", "")).length() > 0

    agent.clear_history()
    ok = ok and agent.history.is_empty()

    agent.submit_user_message("ping")
    ok = ok and agent.history.size() == 1

    agent.clear_history()
    agent.queue_free()
    if ok:
        print("Local Agents integration tests passed")
    return ok
