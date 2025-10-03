@tool
extends SceneTree

class MockRuntime:
    func is_model_loaded() -> bool:
        return true

    func embed_text(text: String, options := {}) -> PackedFloat32Array:
        var normalized := text.to_lower()
        var assistant_score := _substring_count(normalized, "assistant")
        var user_score := _substring_count(normalized, "user")
        var length_score := float(normalized.length()) / 100.0
        return PackedFloat32Array([assistant_score, user_score, length_score])

    func _substring_count(text: String, needle: String) -> float:
        if needle == "":
            return 0.0
        var parts := text.split(needle, false)
        return float(parts.size() - 1)

func _init() -> void:
    if not ClassDB.class_exists("NetworkGraph"):
        push_error("NetworkGraph class unavailable. Build the GDExtension before running tests.")
        quit()
        return

    var store := LocalAgentsConversationStore.new()
    get_root().add_child(store)
    store.set("_runtime", MockRuntime.new())
    store.clear_all()

    var created := store.create_conversation("Test Conversation")
    assert(not created.is_empty())
    var conversation_id := created.get("id", -1)
    assert(conversation_id != -1)

    store.append_message(conversation_id, "user", "user ping", {})
    store.append_message(conversation_id, "assistant", "assistant pong", {})
    store.append_message(conversation_id, "assistant", "assistant follow-up", {})

    var convo := store.load_conversation(conversation_id)
    var messages: Array = convo.get("messages", [])
    assert(messages.size() == 3)
    assert(messages[0].get("role") == "user")
    assert(messages[1].get("order") == 2)

    store.rename_conversation(conversation_id, "Renamed Conversation")
    var conversations := store.list_conversations()
    assert(conversations.size() == 1)
    assert(conversations[0].get("title") == "Renamed Conversation")

    var hits := store.search_messages("assistant", 2, 8)
    assert(hits.size() >= 1)
    assert(hits[0].get("role") == "assistant")

    store.delete_conversation(conversation_id)
    conversations = store.list_conversations()
    assert(conversations.is_empty())

    print("ConversationStore tests passed")
    quit()
