extends RefCounted

class FakeAgent extends LocalAgent:
    var accepts: bool = true

    func _ready() -> void:
        pass

    func think_async(_prompt: String, _options: Dictionary = {}) -> bool:
        return accepts

    func set_history(messages: Array) -> void:
        history = messages

class FakeSession extends RefCounted:
    var selected: int = 1
    var messages: Array = []

    func get_selected_conversation_id() -> int:
        return selected

    func append_message(role: String, content: String) -> void:
        messages.append({"role": role, "content": content})

    func load_conversation(_id: int) -> Dictionary:
        return {"title": "Test", "messages": messages}

    func load_selected_conversation() -> Dictionary:
        return {}

    func get_conversation_title(_id: int) -> String:
        return "Test"

class TestController extends LAChatController:
    func _ready() -> void:
        _conversation_session_service = FakeSession.new()
        _conversation_history_service = preload("res://addons/local_agents/controllers/services/ConversationHistoryService.gd").new()
        _connect_ui()

func run_test(tree: SceneTree) -> bool:
    var packed: PackedScene = load("res://addons/local_agents/controllers/ChatController.tscn")
    var controller: Control = packed.instantiate()
    controller.set_script(TestController)
    tree.root.add_child(controller)
    var agent: FakeAgent = FakeAgent.new()
    tree.root.add_child(agent)
    controller.call("_on_agent_ready", agent)
    var prompt: TextEdit = controller.get_node("%PromptTextEdit")
    var transcript: RichTextLabel = controller.get_node("%ModelOutputRichTextLabel")
    var session: FakeSession = controller.get("_conversation_session_service")
    var ok: bool = _check_embedding_spaces()
    agent.call("_post_think", {"ok": false, "text": "Invalid structured reply", "error": "json_parse_failed"})
    ok = _check(agent.history.is_empty(), "Failed generation entered conversation history") and ok
    prompt.text = "First question"
    controller.call("_on_send_pressed")
    ok = _check(bool(controller.get("_is_generating")), "Request did not start") and ok
    agent.reply_updated.emit("Growing reply")
    ok = _check(transcript.text.ends_with("Growing reply"), "Progress was not presented") and ok
    ok = _check(transcript.text.contains("First question"), "Streaming erased the user prompt") and ok
    controller.call("_on_saved_chat_selected", 2)
    controller.call("_on_saved_chat_deleted", 1)
    ok = _check(session.selected == 1, "Pending request allowed a conversation switch") and ok
    agent.think_completed.emit({"ok": true, "text": "Final reply"})
    ok = _check(session.messages.size() == 2, "Reply was lost or duplicated") and ok
    ok = _check(not bool(controller.get("_is_generating")), "Completion left controls busy") and ok
    ok = _check(transcript.text.contains("First question") and transcript.text.contains("Final reply"), "Completion erased the exchange") and ok
    agent.accepts = false
    prompt.text = "Rejected question"
    controller.call("_on_send_pressed")
    var before: int = session.messages.size()
    agent.think_completed.emit({"ok": true, "text": "Unrelated reply"})
    ok = _check(session.messages.size() == before, "Rejected request accepted an unrelated completion") and ok
    agent.accepts = true
    prompt.text = "Interrupted question"
    controller.call("_on_send_pressed")
    var old_generation: int = int(controller.get("_request_generation"))
    var replacement: FakeAgent = FakeAgent.new()
    tree.root.add_child(replacement)
    controller.call("_on_agent_ready", replacement)
    ok = _check(not bool(controller.get("_is_generating")), "Replacing the agent wedged controls") and ok
    before = session.messages.size()
    agent.think_completed.emit({"ok": true, "text": "Old reply"})
    prompt.text = "New question"
    controller.call("_on_send_pressed")
    before = session.messages.size()
    controller.call("_on_think_completed", {"ok": true, "text": "Stale reply"}, old_generation)
    ok = _check(session.messages.size() == before and bool(controller.get("_is_generating")), "Stale completion resolved a new request") and ok
    replacement.think_completed.emit({"ok": false, "error": "service_failed"})
    var status: Label = controller.get_node("%StatusLabel")
    ok = _check(status.text.contains("service_failed"), "Failure was hidden") and ok
    controller.free()
    agent.free()
    replacement.free()
    if ok:
        print("LLM request ownership tests passed")
    return ok

func _check(condition: bool, message: String) -> bool:
    if not condition:
        push_error(message)
    return condition

func _check_embedding_spaces() -> bool:
    var graph: NetworkGraph = NetworkGraph.new()
    if not graph.open(":memory:"):
        return _check(false, "Could not open embedding fixture")
    var a: int = graph.upsert_node("test", "a", {})
    var b: int = graph.upsert_node("test", "b", {})
    var c: int = graph.upsert_node("test", "c", {})
    var ok: bool = graph.add_embedding(a, PackedFloat32Array([1, 0]), {"embedding_model": "model-a"}) != -1
    ok = graph.add_embedding(b, PackedFloat32Array([1, 0, 0]), {"embedding_model": "model-b"}) != -1 and ok
    ok = graph.add_embedding(c, PackedFloat32Array([1, 0]), {"embedding_model": "model-c"}) != -1 and ok
    for strategy: String in ["vp_tree", "exact"]:
        var matches: Array[Dictionary] = graph.search_embeddings(PackedFloat32Array([1, 0]), 8, 8, strategy, "model-a")
        ok = _check(matches.size() == 1 and int(matches[0].get("node_id", -1)) == a, "Search mixed models with equal dimensions") and ok
        matches = graph.search_embeddings(PackedFloat32Array([1, 0, 0]), 8, 8, strategy, "model-b")
        ok = _check(matches.size() == 1 and int(matches[0].get("node_id", -1)) == b, "Search mixed models with different dimensions") and ok
    graph.close()
    return ok
