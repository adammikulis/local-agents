@tool
extends RefCounted
class_name LocalAgentsBackstoryEmbeddingOps

const RuntimePaths = preload("res://addons/local_agents/runtime/RuntimePaths.gd")

static func index_memory_embedding_node(svc, node_id: int, memory_id: String, npc_id: String, summary: String, embed_options: Dictionary) -> Dictionary:
    if summary.strip_edges() == "":
        return {"ok": false, "error": "empty_memory_summary"}
    var runtime: Object = svc._agent_runtime()
    if runtime == null or not runtime.has_method("embed_text"):
        return {"ok": false, "error": "runtime_unavailable"}
    var backend_ready: Dictionary = ensure_embedding_backend_ready(svc, embed_options, runtime)
    if not bool(backend_ready.get("ok", false)):
        return {
            "ok": false,
            "error": "embedding_backend_unavailable",
            "backend": backend_ready,
        }

    var vector: PackedFloat32Array = runtime.call("embed_text", summary, embed_options)
    if vector.is_empty():
        return {"ok": false, "error": "embedding_failed"}

    var embedding_model := String(embed_options.get("server_model", embed_options.get("model", ""))).strip_edges()
    if embedding_model == "" and runtime.has_method("get_default_model_path"):
        var model_path := String(runtime.call("get_default_model_path")).strip_edges()
        if model_path != "":
            embedding_model = model_path.get_file()
    if embedding_model == "":
        embedding_model = "unknown"

    var embedding_id := int(svc._graph.add_embedding(node_id, vector, {
        "type": "memory",
        "memory_id": memory_id,
        "npc_id": npc_id,
        "source": "backstory_memory",
        "strategy_hint": "cosine",
        "embedding_model": embedding_model,
    }))
    if embedding_id == -1:
        return {"ok": false, "error": "embedding_store_failed"}
    return {
        "ok": true,
        "embedding_id": embedding_id,
    }

static func ensure_embedding_backend_ready(svc, embed_options: Dictionary, runtime: Object) -> Dictionary:
    var backend = String(embed_options.get("backend", "")).strip_edges().to_lower()
    if backend == "" or backend == "local":
        return {"ok": true, "backend": backend}
    if backend != "llama_server":
        return {"ok": true, "backend": backend}
    if not bool(embed_options.get("server_autostart", true)):
        return {"ok": true, "backend": backend}

    var resolved_model = resolve_embedding_model_path(embed_options, runtime)
    if resolved_model == "":
        return {
            "ok": false,
            "error": "embedding_model_missing",
            "backend": backend,
        }
    var runtime_dir = RuntimePaths.normalize_path(String(embed_options.get("runtime_directory", "")))
    var lifecycle = svc._embedding_server_manager.ensure_running(embed_options, resolved_model, runtime_dir)
    if not bool(lifecycle.get("ok", false)):
        return {
            "ok": false,
            "error": "embedding_server_unavailable",
            "backend": backend,
            "lifecycle": lifecycle,
        }
    return {
        "ok": true,
        "backend": backend,
        "base_url": lifecycle.get("base_url", ""),
        "model_path": resolved_model,
    }

static func resolve_embedding_model_path(embed_options: Dictionary, runtime: Object) -> String:
    var explicit_keys = ["server_model_path", "model_path", "model"]
    for key in explicit_keys:
        var candidate = String(embed_options.get(key, "")).strip_edges()
        if candidate == "":
            continue
        var normalized = RuntimePaths.normalize_path(candidate)
        if normalized != "" and FileAccess.file_exists(normalized):
            return normalized
    if runtime != null and runtime.has_method("get_default_model_path"):
        var runtime_default = String(runtime.call("get_default_model_path")).strip_edges()
        var normalized_runtime_default = RuntimePaths.normalize_path(runtime_default)
        if normalized_runtime_default != "" and FileAccess.file_exists(normalized_runtime_default):
            return normalized_runtime_default
    var fallback = RuntimePaths.resolve_default_model()
    if fallback != "" and FileAccess.file_exists(fallback):
        return fallback
    return ""
