@tool
extends RefCounted

const RuntimeSingletonSwap := preload("res://addons/local_agents/tests/runtime_singleton_swap.gd")

class MockRuntime extends Object:
    func is_model_loaded() -> bool:
        return true

    func embed_text(text: String, options := {}) -> PackedFloat32Array:
        var normalized := text.to_lower()
        var assistant_score := _substring_count(normalized, "assistant")
        var user_score := _substring_count(normalized, "user")
        var length_score := float(normalized.length()) / 100.0
        return PackedFloat32Array([assistant_score, user_score, length_score])

    func embed_text_with_model(text: String, options: Dictionary = {}) -> Dictionary:
        return {"ok": true, "vector": embed_text(text, options), "embedding_model": "test-model"}

    func _substring_count(text: String, needle: String) -> float:
        if needle == "":
            return 0.0
        var parts := text.split(needle, false)
        return float(parts.size() - 1)

func run_test(tree: SceneTree) -> bool:
    var swap := RuntimeSingletonSwap.new()
    swap.install(MockRuntime.new())
    var ok := _exercise(tree)
    swap.restore()
    if ok:
        print("ConversationStore tests passed")
    return ok

func _exercise(tree: SceneTree) -> bool:
    var store: LAConversationStore = LAConversationStore.new()
    var graph: NetworkGraph = NetworkGraph.new()
    if not graph.open(":memory:"):
        return _assert(false, "Could not open isolated conversation fixture")
    store.set("_graph", graph)
    tree.get_root().add_child(store)
    store.clear_all()

    var ok := true
    var created := store.create_conversation("Test Conversation")
    ok = ok and _assert(not created.is_empty(), "Conversation creation failed")
    var conversation_id := created.get("id", -1)
    ok = ok and _assert(conversation_id != -1, "Conversation id missing")

    store.append_message(conversation_id, "user", "user ping", {})
    store.append_message(conversation_id, "assistant", "assistant pong", {})
    store.append_message(conversation_id, "assistant", "assistant follow-up", {})

    var convo := store.load_conversation(conversation_id)
    var messages: Array = convo.get("messages", [])
    ok = ok and _assert(messages.size() == 3, "Unexpected message count")
    ok = ok and _assert(messages[0].get("role") == "user", "First role mismatch")

    store.rename_conversation(conversation_id, "Renamed Conversation")
    var conversations := store.list_conversations()
    ok = ok and _assert(conversations.size() == 1, "Conversation list mismatch")
    ok = ok and _assert(conversations[0].get("title") == "Renamed Conversation", "Conversation rename failed")

    var hits := store.search_messages("assistant", 2, 8)
    ok = ok and _assert(hits.size() >= 1, "Search hits missing")

    store.delete_conversation(conversation_id)
    conversations = store.list_conversations()
    ok = ok and _assert(conversations.is_empty(), "Conversation delete failed")

    store.queue_free()
    return ok

func _assert(condition: bool, message: String) -> bool:
    if not condition:
        push_error(message)
    return condition
