@tool
extends Node
class_name LocalAgentsProjectGraphService

const STORE_DIR := "user://local_agents"
const DB_PATH := STORE_DIR + "/network.sqlite3"
const CODE_SPACE := "code"
const DIRECTORY_SPACE := "code_dir"
const DEFAULT_EXTENSIONS := ["gd", "tscn", "tres", "cs", "gdshader", "cfg"]

var _graph: NetworkGraph
var _runtime: Object = null

func _ready() -> void:
    _ensure_graph()

func rebuild_project_graph(root_path: String = "res://", extensions: Array = DEFAULT_EXTENSIONS) -> void:
    if not _ensure_graph():
        return
    var ext_set := {}
    for ext in extensions:
        ext_set[ext] = true

    _clear_code_space()

    var dir_stack: Array = [root_path]
    var directory_ids := {}

    while not dir_stack.is_empty():
        var path: String = dir_stack.pop_back()
        var dir := DirAccess.open(path)
        if dir == null:
            continue
        dir.list_dir_begin()
        var file_name := dir.get_next()
        while file_name != "":
            if dir.current_is_dir():
                if file_name.begins_with("."):
                    file_name = dir.get_next()
                    continue
                dir_stack.append(path.path_join(file_name))
                file_name = dir.get_next()
                continue
            var extension := file_name.get_extension().to_lower()
            if not ext_set.has(extension):
                file_name = dir.get_next()
                continue
            var resource_path := path.path_join(file_name)
            var content := _read_file(resource_path)
            var metadata := {
                "type": "code",
                "path": resource_path,
                "extension": extension,
                "size": content.length(),
                "hash": hash(content),
            }
            var label := resource_path
            var node_id := _graph.upsert_node(CODE_SPACE, label, metadata)
            if node_id == -1:
                file_name = dir.get_next()
                continue
            var parent_dir := path
            var parent_id := directory_ids.get(parent_dir, -1)
            if parent_id == -1:
                parent_id = _ensure_directory_node(parent_dir, directory_ids)
            if parent_id != -1:
                _graph.add_edge(parent_id, node_id, "contains", 1.0, {
                    "type": "structure",
                    "parent": parent_dir,
                    "child": resource_path,
                })
            _store_code_embedding(node_id, content)
            file_name = dir.get_next()
        dir.list_dir_end()

func search_code(query: String, top_k: int = 5, expand: int = 64) -> Array:
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
    var emb := runtime.call("embed_text", query, {"normalize": true})
    if emb.is_empty():
        return []
    var matches := _graph.search_embeddings(emb, top_k, expand)
    var results: Array = []
    for match in matches:
        if not (match is Dictionary):
            continue
        var match_row: Dictionary = match
        var node_id := int(match_row.get("node_id", -1))
        if node_id == -1:
            continue
        var node_variant = _graph.get_node(node_id)
        if not (node_variant is Dictionary):
            continue
        var node: Dictionary = node_variant
        if node.is_empty():
            continue
        var data_variant = node.get("data", {})
        if not (data_variant is Dictionary):
            continue
        var data: Dictionary = data_variant
        results.append({
            "node_id": node_id,
            "path": data.get("path", ""),
            "extension": data.get("extension", ""),
            "similarity": float(match_row.get("similarity", 0.0)),
        })
    results.sort_custom(_sort_results_by_similarity)
    return results

func list_code_nodes(limit: int = 256, offset: int = 0) -> Array:
    if not _ensure_graph():
        return []
    return _graph.list_nodes(CODE_SPACE, limit, offset)

func _ensure_graph() -> bool:
    if _graph:
        return true
    if not ClassDB.class_exists("NetworkGraph"):
        push_error("NetworkGraph extension unavailable")
        return false
    _graph = NetworkGraph.new()
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STORE_DIR))
    if not _graph.open(ProjectSettings.globalize_path(DB_PATH)):
        push_error("Failed to open network graph database for project graph")
        _graph = null
        return false
    return true

func _ensure_directory_node(path: String, cache: Dictionary) -> int:
    if cache.has(path):
        return cache[path]
    var label := "dir:" + path
    var data := {
        "type": "directory",
        "path": path,
    }
    var node_id := _graph.upsert_node(DIRECTORY_SPACE, label, data)
    if node_id != -1:
        cache[path] = node_id
    return node_id

func _store_code_embedding(node_id: int, content: String) -> void:
    var runtime: Object = _agent_runtime()
    if runtime == null or not runtime.has_method("is_model_loaded"):
        return
    if not runtime.call("is_model_loaded"):
        return
    if not runtime.has_method("embed_text"):
        return
    var slice := content
    if slice.length() > 4000:
        slice = slice.substr(0, 4000)
    var emb := runtime.call("embed_text", slice, {"normalize": true})
    if emb.is_empty():
        return
    var embedding_model := _resolve_embedding_model(runtime)
    var node_variant = _graph.get_node(node_id)
    var node_data: Dictionary = {}
    if node_variant is Dictionary:
        var node: Dictionary = node_variant
        var node_data_variant = node.get("data", {})
        if node_data_variant is Dictionary:
            node_data = node_data_variant
    _graph.add_embedding(node_id, emb, {
        "type": "code_chunk",
        "path": node_data.get("path", ""),
        "embedding_model": embedding_model,
    })

func _clear_code_space() -> void:
    var code_nodes := _graph.list_nodes(CODE_SPACE, 65536, 0)
    for row in code_nodes:
        if not (row is Dictionary):
            continue
        var code_row: Dictionary = row
        _graph.remove_node(int(code_row.get("id", -1)))
    var dir_nodes := _graph.list_nodes(DIRECTORY_SPACE, 65536, 0)
    for row in dir_nodes:
        if not (row is Dictionary):
            continue
        var dir_row: Dictionary = row
        _graph.remove_node(int(dir_row.get("id", -1)))

func _sort_results_by_similarity(a: Dictionary, b: Dictionary) -> bool:
    return float(a.get("similarity", 0.0)) > float(b.get("similarity", 0.0))

func _read_file(path: String) -> String:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return ""
    var content := file.get_as_text()
    file.close()
    return content

func _agent_runtime() -> Object:
    if _runtime:
        return _runtime
    if not Engine.has_singleton("AgentRuntime"):
        return null
    _runtime = Engine.get_singleton("AgentRuntime")
    return _runtime

func _resolve_embedding_model(runtime: Object) -> String:
    if runtime == null:
        return "unknown"
    if runtime.has_method("get_default_model_path"):
        var path := String(runtime.call("get_default_model_path")).strip_edges()
        if path != "":
            return path.get_file()
    return "unknown"
