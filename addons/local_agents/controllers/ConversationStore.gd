@tool
extends Node
class_name LocalAgentsConversationStore

const STORE_DIR := "user://local_agents"
const DB_PATH := STORE_DIR + "/network.sqlite3"
const CONVERSATION_SPACE := "conversation"
const MESSAGE_SPACE := "message"

var _graph: NetworkGraph
var _runtime: Object = null
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
    _rng.randomize()
    _ensure_graph()

func list_conversations(limit: int = 256, offset: int = 0) -> Array:
    if not _ensure_graph():
        return []
    var rows: Array = _graph.list_nodes(CONVERSATION_SPACE, limit, offset)
    var items: Array = []
    for row in rows:
        var data: Dictionary = row.get("data", {})
        items.append({
            "id": int(row.get("id", -1)),
            "title": data.get("title", row.get("label", "Conversation")),
            "created_at": int(data.get("created_at", row.get("created_at", 0))),
            "metadata": data.duplicate(true),
        })
    items.sort_custom(func(a, b): return int(a.get("created_at", 0)) < int(b.get("created_at", 0)))
    return items

func create_conversation(title: String) -> Dictionary:
    if not _ensure_graph():
        return {}
    var timestamp := _timestamp()
    var node_id := _graph.upsert_node(CONVERSATION_SPACE, _generate_label("conversation"), {
        "type": "conversation",
        "title": title,
        "created_at": timestamp,
    })
    if node_id == -1:
        push_error("Failed to create conversation node")
        return {}
    return {
        "id": node_id,
        "title": title,
        "created_at": timestamp,
        "metadata": {
            "type": "conversation",
            "title": title,
            "created_at": timestamp,
        },
    }

func rename_conversation(conversation_id: int, title: String) -> void:
    if not _ensure_graph():
        return
    var node := _graph.get_node(conversation_id)
    if node.is_empty():
        return
    var data: Dictionary = node.get("data", {})
    data["title"] = title
    _graph.update_node_data(conversation_id, data)

func delete_conversation(conversation_id: int) -> void:
    if not _ensure_graph():
        return
    _graph.remove_node(conversation_id)

func append_message(conversation_id: int, role: String, content: String, metadata: Dictionary = {}) -> Dictionary:
    if not _ensure_graph():
        return {}
    var conversation := _graph.get_node(conversation_id)
    if conversation.is_empty():
        push_error("Conversation %s not found" % conversation_id)
        return {}
    var order_info := _next_message_context(conversation_id)
    var order := int(order_info.get("next_order", 1))
    var previous_id := int(order_info.get("previous_id", -1))

    var timestamp := _timestamp()
    var payload := {
        "type": "message",
        "conversation_id": conversation_id,
        "role": role,
        "content": content,
        "order": order,
        "created_at": timestamp,
        "metadata": metadata.duplicate(true),
    }
    var label := _generate_label("message")
    var message_id := _graph.upsert_node(MESSAGE_SPACE, label, payload)
    if message_id == -1:
        push_error("Failed to create message node")
        return {}

    _graph.add_edge(conversation_id, message_id, "contains", 1.0, {
        "type": "contains",
        "conversation_id": conversation_id,
        "message_id": message_id,
        "order": order,
    })

    if previous_id != -1:
        _graph.add_edge(previous_id, message_id, "sequence", 1.0, {
            "type": "sequence",
            "conversation_id": conversation_id,
            "from": previous_id,
            "to": message_id,
        })

    _store_embedding(message_id, role, content, conversation_id)
    return _message_from_payload(message_id, payload)

func load_conversation(conversation_id: int) -> Dictionary:
    if not _ensure_graph():
        return {}
    var node := _graph.get_node(conversation_id)
    if node.is_empty():
        return {}
    var data: Dictionary = node.get("data", {})
    var rows := _graph.list_nodes_by_metadata(MESSAGE_SPACE, "conversation_id", conversation_id, 4096, 0)
    var messages: Array = []
    for row in rows:
        messages.append(_message_from_row(row))
    messages.sort_custom(func(a, b): return int(a.get("order", 0)) < int(b.get("order", 0)))
    return {
        "id": int(node.get("id", conversation_id)),
        "title": data.get("title", node.get("label", "Conversation")),
        "messages": messages,
        "metadata": data.duplicate(true),
    }

func search_messages(query: String, top_k: int = 5, expand: int = 32) -> Array:
    if query.strip_edges() == "":
        return []
    if not _ensure_graph():
        return []
    var runtime: Object = _agent_runtime()
    if runtime == null or not runtime.has_method("is_model_loaded"):
        return []
    if not runtime.call("is_model_loaded"):
        return []
    if not runtime.has_method("embed_text"):
        return []
    var embedding := runtime.call("embed_text", query, {"normalize": true})
    if embedding.is_empty():
        return []
    var matches := _graph.search_embeddings(embedding, top_k, expand)
    var results: Array = []
    for item in matches:
        var node_id := int(item.get("node_id", -1))
        if node_id == -1:
            continue
        var message := _graph.get_node(node_id)
        if message.is_empty():
            continue
        var payload := _message_from_row(message)
        payload["similarity"] = float(item.get("similarity", 0.0))
        results.append(payload)
    results.sort_custom(func(a, b): return float(a.get("similarity", 0.0)) > float(b.get("similarity", 0.0)))
    return results

func clear_all() -> void:
    if not _ensure_graph():
        return
    var conversations := _graph.list_nodes(CONVERSATION_SPACE, 65536, 0)
    for row in conversations:
        _graph.remove_node(int(row.get("id", -1)))

func _ensure_graph() -> bool:
    if _graph:
        return true
    if not ClassDB.class_exists("NetworkGraph"):
        push_error("NetworkGraph extension unavailable")
        return false
    _graph = NetworkGraph.new()
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STORE_DIR))
    var ok := _graph.open(ProjectSettings.globalize_path(DB_PATH))
    if not ok:
        push_error("Failed to open NetworkGraph database")
        _graph = null
        return false
    return true

func _next_message_context(conversation_id: int) -> Dictionary:
    var rows := _graph.list_nodes_by_metadata(MESSAGE_SPACE, "conversation_id", conversation_id, 512, 0)
    var max_order := 0
    var last_id := -1
    for row in rows:
        var data: Dictionary = row.get("data", {})
        var order := int(data.get("order", 0))
        if order > max_order:
            max_order = order
            last_id = int(row.get("id", -1))
    return {
        "next_order": max_order + 1,
        "previous_id": last_id,
    }

func _message_from_payload(message_id: int, payload: Dictionary) -> Dictionary:
    return {
        "id": message_id,
        "conversation_id": payload.get("conversation_id", -1),
        "role": payload.get("role", "user"),
        "content": payload.get("content", ""),
        "order": payload.get("order", 0),
        "created_at": payload.get("created_at", 0),
        "metadata": payload.get("metadata", {}).duplicate(true),
    }

func _message_from_row(row: Dictionary) -> Dictionary:
    var data: Dictionary = row.get("data", {})
    return {
        "id": int(row.get("id", -1)),
        "conversation_id": data.get("conversation_id", -1),
        "role": data.get("role", "user"),
        "content": data.get("content", ""),
        "order": data.get("order", 0),
        "created_at": data.get("created_at", row.get("created_at", 0)),
        "metadata": data.get("metadata", {}).duplicate(true),
    }

func _store_embedding(message_id: int, role: String, content: String, conversation_id: int) -> void:
    var runtime: Object = _agent_runtime()
    if runtime == null or not runtime.has_method("is_model_loaded"):
        return
    if not runtime.call("is_model_loaded"):
        return
    if not runtime.has_method("embed_text"):
        return
    var truncated := content
    if truncated.length() > 4096:
        truncated = truncated.substr(0, 4096)
    var vector := runtime.call("embed_text", truncated, {"normalize": true})
    if vector.is_empty():
        return
    _graph.add_embedding(message_id, vector, {
        "type": "chat_message",
        "conversation_id": conversation_id,
        "role": role,
    })

func _generate_label(prefix: String) -> String:
    return "%s_%d_%d" % [prefix, Time.get_unix_time_from_system(), _rng.randi()]

func _timestamp() -> int:
    return int(Time.get_unix_time_from_system())

func _agent_runtime() -> Object:
    if _runtime:
        return _runtime
    if not Engine.has_singleton("AgentRuntime"):
        return null
    _runtime = Engine.get_singleton("AgentRuntime")
    return _runtime
