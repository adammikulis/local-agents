@tool
extends RefCounted

class MockRuntime:
    func is_model_loaded() -> bool:
        return true

    func embed_text(text: String, options := {}) -> PackedFloat32Array:
        var normalized := text.to_lower()
        var score_a := float(normalized.count("assistant"))
        var score_b := float(normalized.length()) / 100.0
        return PackedFloat32Array([score_a, score_b, 1.0])

class MockAgentNode:
    extends Node

    var history: Array = []

    func think(prompt: String, extra_options := {}) -> Dictionary:
        history.append({"role": "user", "content": prompt})
        var reply := "Agent reply: %s" % prompt.strip_edges()
        history.append({"role": "assistant", "content": reply})
        return {"ok": true, "text": reply}

    func add_message(role: String, content: String) -> void:
        history.append({"role": role, "content": content})

    func get_history() -> Array:
        var copy: Array = []
        for entry in history:
            copy.append(entry.duplicate(true))
        return copy

    func clear_history() -> void:
        history.clear()

    func say(_text: String, _options := {}) -> bool:
        return true

    func listen(_options := {}) -> String:
        return ""

    func enqueue_action(_name: String, _params := {}) -> void:
        pass

var _captured_outputs: Array = []

func run_test(tree: SceneTree) -> bool:
    if not ClassDB.class_exists("NetworkGraph"):
        push_error("NetworkGraph unavailable; build the native extension.")
        return false

    var store := LocalAgentsConversationStore.new()
    tree.get_root().add_child(store)
    store._runtime = MockRuntime.new()
    store.clear_all()

    var conversation := store.create_conversation("End to End Chat")
    var conversation_id := int(conversation.get("id", -1))
    var ok := (conversation_id != -1)

    var agent := LocalAgentsAgent.new()
    var agent_node := MockAgentNode.new()
    agent.agent_node = agent_node
    agent.connect("model_output_received", Callable(self, "_on_model_output"))

    var prompt := "Assistant, respond to this message"
    store.append_message(conversation_id, "user", prompt, {})

    var response := agent.think(prompt)
    var reply := String(response.get("text", ""))
    ok = ok and reply != ""
    ok = ok and _captured_outputs.size() == 1

    store.append_message(conversation_id, "assistant", reply, {})

    var loaded := store.load_conversation(conversation_id)
    var messages: Array = loaded.get("messages", [])
    ok = ok and messages.size() == 2
    if messages.size() >= 2:
        ok = ok and messages[1].get("role") == "assistant"
        ok = ok and messages[1].get("content") == reply

    var hits := store.search_messages("assistant", 4, 8)
    ok = ok and hits.size() >= 1

    store.clear_all()
    _cleanup_store(store)

    agent.queue_free()
    store.queue_free()

    if ok:
        print("Local Agents end-to-end conversation test passed")
    return ok

func _on_model_output(text: String) -> void:
    _captured_outputs.append(text)

func _cleanup_store(store: LocalAgentsConversationStore) -> void:
    if store._graph:
        store._graph.close()
    var db_abs := ProjectSettings.globalize_path(store.DB_PATH)
    if FileAccess.file_exists(db_abs):
        DirAccess.remove_absolute(db_abs)
    var dir_abs := ProjectSettings.globalize_path(store.STORE_DIR)
    _clear_directory(dir_abs)

func _clear_directory(path_abs: String) -> void:
    if not DirAccess.dir_exists_absolute(path_abs):
        return
    var dir := DirAccess.open(path_abs)
    if dir == null:
        return
    dir.list_dir_begin()
    var entry := dir.get_next()
    while entry != "":
        if entry == "." or entry == "..":
            entry = dir.get_next()
            continue
        var entry_path := path_abs.path_join(entry)
        if dir.current_is_dir():
            _clear_directory(entry_path)
            DirAccess.remove_absolute(entry_path)
        else:
            DirAccess.remove_absolute(entry_path)
        entry = dir.get_next()
    dir.list_dir_end()
    DirAccess.remove_absolute(path_abs)
