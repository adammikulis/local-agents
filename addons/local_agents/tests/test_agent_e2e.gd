@tool
extends RefCounted

class MockRuntime:
    func is_model_loaded() -> bool:
        return true

    func embed_text(text: String, _options := {}) -> PackedFloat32Array:
        var normalized := text.to_lower()
        var assistant_score := float(normalized.count("assistant"))
        var length_score := float(normalized.length()) / 128.0
        return PackedFloat32Array([assistant_score, length_score])

func run_test(tree: SceneTree) -> bool:
    if not ClassDB.class_exists("NetworkGraph"):
        print("Skipping agent E2E test (NetworkGraph unavailable). Build the native extension to enable it.")
        return true

    var store := LocalAgentsConversationStore.new()
    tree.get_root().add_child(store)
    store._runtime = MockRuntime.new()
    store.clear_all()

    var convo := store.create_conversation("Manual E2E")
    if convo.is_empty():
        push_error("Failed to create conversation")
        return false
    var convo_id := int(convo.get("id", -1))
    store.append_message(convo_id, "user", "assistant hello", {})
    store.append_message(convo_id, "assistant", "assistant reply", {})

    var loaded := store.load_conversation(convo_id)
    var messages: Array = loaded.get("messages", [])
    var ok := messages.size() == 2

    var hits := store.search_messages("assistant", 2, 4)
    ok = ok and hits.size() >= 1

    store.clear_all()
    store.queue_free()
    if ok:
        print("Local Agents conversation E2E test passed")
    return ok
