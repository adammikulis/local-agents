@tool
extends SceneTree

var _captured_outputs: Array = []

class MockAgentNode:
    extends Node

    signal message_emitted(role, content)
    signal action_requested(action, params)

    var history: Array = []
    var actions: Array = []

    func think(prompt: String, extra_options := {}) -> Dictionary:
        history.append({"role": "user", "content": prompt})
        var reply := "Echo: %s" % prompt
        history.append({"role": "assistant", "content": reply})
        emit_signal("message_emitted", "assistant", reply)
        return {
            "ok": true,
            "text": reply,
        }

    func add_message(role: String, content: String) -> void:
        history.append({"role": role, "content": content})

    func get_history() -> Array:
        var copy: Array = []
        for entry in history:
            copy.append(entry.duplicate(true))
        return copy

    func clear_history() -> void:
        history.clear()

    func say(text: String, options := {}) -> bool:
        actions.append({
            "action": "say",
            "text": text,
            "options": options.duplicate(true),
        })
        return true

    func listen(options := {}) -> String:
        return "heard"

    func enqueue_action(name: String, params := {}) -> void:
        actions.append({
            "action": name,
            "params": params.duplicate(true),
        })
        emit_signal("action_requested", name, params)

func _init() -> void:
    var agent := LocalAgentsAgent.new()
    var mock := MockAgentNode.new()
    agent.agent_node = mock

    agent.connect("model_output_received", Callable(self, "_on_model_output"))

    var result := agent.think("Hello integration")
    assert(result.get("ok", false))
    var text := String(result.get("text", ""))
    assert(text.begins_with("Echo:"))
    assert(_captured_outputs.size() == 1)

    assert(agent.history.size() == 2)
    assert(agent.history[0].get("role") == "user")
    assert(agent.history[1].get("role") == "assistant")

    var node_history := agent.get_history()
    assert(node_history.size() == 2)
    assert(node_history[0].get("role") == "user")

    agent.clear_history()
    assert(agent.history.is_empty())
    assert(mock.history.is_empty())

    agent.set_history([
        {"role": "user", "content": "ping"},
        {"role": "assistant", "content": "pong"},
    ])
    assert(agent.history.size() == 2)
    assert(mock.history.size() == 2)

    agent.enqueue_action("wave", {"speed": 2})
    assert(mock.actions.size() >= 1)
    assert(mock.actions[mock.actions.size() - 1].get("action") == "wave")

    var say_ok := agent.say("speak", {"volume": 0.5})
    assert(say_ok)
    assert(mock.actions[mock.actions.size() - 1].get("action") == "say")

    var heard := agent.listen({})
    assert(heard == "heard")

    agent.queue_free()

    print("Local Agents integration tests passed")
    quit()

func _on_model_output(text: String) -> void:
    _captured_outputs.append(text)
