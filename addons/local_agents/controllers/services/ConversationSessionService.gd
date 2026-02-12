extends RefCounted
class_name LocalAgentsConversationSessionService

var _conversation_store: Node
var _conversation_index: Array = []
var _selected_conversation_id: int = -1

func ensure_conversation_store(tree: SceneTree, default_store: Script) -> void:
    _conversation_store = tree.root.get_node_or_null("ConversationStore")
    if _conversation_store == null:
        _conversation_store = default_store.new()
        _conversation_store.name = "ConversationStore"
        tree.root.call_deferred("add_child", _conversation_store)
        _conversation_store.owner = null

func get_conversation_store() -> Node:
    return _conversation_store

func get_conversation_index() -> Array:
    return _conversation_index

func get_selected_conversation_id() -> int:
    return _selected_conversation_id

func set_selected_conversation_id(conversation_id: int) -> void:
    _selected_conversation_id = conversation_id

func refresh_conversations() -> Dictionary:
    if not _conversation_store:
        return {
            "index": [],
            "selected_index": -1,
            "selected_id": -1,
        }
    var desired_id := _selected_conversation_id
    _conversation_index = []
    var raw_list: Array = _conversation_store.list_conversations()
    for i in raw_list.size():
        var entry_variant: Variant = raw_list[i]
        var entry: Dictionary = {}
        if entry_variant is Dictionary:
            entry = entry_variant
        if not entry.has("id"):
            entry = entry.duplicate(true)
            entry["id"] = entry.get("conversation_id", i)
        _conversation_index.append(entry)
    _conversation_index.sort_custom(Callable(self, "sort_conversation_index"))

    if _conversation_index.is_empty():
        if _conversation_store.has_method("create_conversation"):
            var created_variant: Variant = _conversation_store.create_conversation("Conversation 1")
            var created: Dictionary = {}
            if created_variant is Dictionary:
                created = created_variant
            if not created.has("id"):
                created = created.duplicate(true)
                created["id"] = created.get("conversation_id", 0)
            _conversation_index = [created]
        else:
            _conversation_index = [{"id": 0, "title": "Conversation"}]

    var selected_index := 0
    if desired_id != -1:
        for idx in _conversation_index.size():
            if _conversation_index[idx].get("id", -1) == desired_id:
                selected_index = idx
                break

    _selected_conversation_id = _conversation_index[selected_index].get("id", selected_index)
    return {
        "index": _conversation_index,
        "selected_index": selected_index,
        "selected_id": _selected_conversation_id,
    }

func select_conversation_by_list_index(index: int) -> int:
    if index < 0 or index >= _conversation_index.size():
        return -1
    _selected_conversation_id = _conversation_index[index].get("id", index)
    return _selected_conversation_id

func create_conversation() -> int:
    if not _conversation_store:
        return -1
    var title := "Conversation %d" % (_conversation_index.size() + 1)
    var convo: Dictionary = {}
    if _conversation_store.has_method("create_conversation"):
        var convo_variant: Variant = _conversation_store.create_conversation(title)
        if convo_variant is Dictionary:
            convo = convo_variant
    _selected_conversation_id = convo.get("id", -1)
    return _selected_conversation_id

func apply_conversation_title(conversation_id: int, new_title: String) -> void:
    if not _conversation_store:
        return
    if _conversation_store.has_method("rename_conversation"):
        _conversation_store.rename_conversation(conversation_id, new_title)
    elif _conversation_store.has_method("append_message"):
        _conversation_store.append_message(conversation_id, "system", "rename:%s" % new_title, {"title": new_title})
    for idx in _conversation_index.size():
        var list_entry_variant: Variant = _conversation_index[idx]
        var list_entry: Dictionary = {}
        if list_entry_variant is Dictionary:
            list_entry = list_entry_variant
        if list_entry.get("id", -1) == conversation_id:
            list_entry["title"] = new_title
            _conversation_index[idx] = list_entry

func delete_selected_conversation() -> Dictionary:
    if _selected_conversation_id == -1 or not _conversation_store:
        return {"ok": false, "error": "No conversation selected"}
    if _conversation_index.size() <= 1:
        return {"ok": false, "error": "Cannot delete the last conversation"}
    if _conversation_store.has_method("delete_conversation"):
        _conversation_store.delete_conversation(_selected_conversation_id)
    return {"ok": true}

func delete_conversation(conversation_id: int) -> void:
    if not _conversation_store:
        return
    if _conversation_store.has_method("delete_conversation"):
        _conversation_store.delete_conversation(conversation_id)

func append_message(role: String, content: String, metadata: Dictionary = {}) -> void:
    if not _conversation_store or _selected_conversation_id == -1:
        return
    if _conversation_store.has_method("append_message"):
        _conversation_store.append_message(_selected_conversation_id, role, content, metadata)

func load_conversation(conversation_id: int) -> Dictionary:
    if not _conversation_store:
        return {}
    return _conversation_store.load_conversation(conversation_id)

func load_selected_conversation() -> Dictionary:
    if _selected_conversation_id == -1:
        return {}
    return load_conversation(_selected_conversation_id)

func get_conversation_title(conversation_id: int) -> String:
    for convo_variant in _conversation_index:
        var convo_entry: Dictionary = {}
        if convo_variant is Dictionary:
            convo_entry = convo_variant
        if convo_entry.get("id", -1) == conversation_id:
            return get_conversation_title_from_entry(convo_entry)
    return "Conversation"

func get_conversation_title_from_entry(entry: Dictionary) -> String:
    if entry.has("title"):
        return entry["title"]
    if entry.has("name"):
        return entry["name"]
    return "Conversation"

func find_list_index_for_conversation_id(conversation_id: int) -> int:
    for idx in _conversation_index.size():
        var convo_entry_variant: Variant = _conversation_index[idx]
        var convo_entry: Dictionary = {}
        if convo_entry_variant is Dictionary:
            convo_entry = convo_entry_variant
        if convo_entry.get("id", -1) == conversation_id:
            return idx
    return -1

func sort_conversation_index(a: Dictionary, b: Dictionary) -> bool:
    return int(a.get("created_at", 0)) < int(b.get("created_at", 0))
