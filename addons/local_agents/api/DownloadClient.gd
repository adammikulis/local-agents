@tool
extends RefCounted
class_name LocalAgentsDownloadClient

static func download_request(request: Dictionary) -> Dictionary:
    var runtime := Engine.get_singleton("AgentRuntime")
    if runtime == null:
        return {"ok": false, "error": "runtime_missing"}
    if not runtime.has_method("download_model"):
        return {"ok": false, "error": "download_model_unavailable"}
    return runtime.call("download_model", request)

static func download_hf(repo: String, file: String, options: Dictionary = {}) -> Dictionary:
    var runtime := Engine.get_singleton("AgentRuntime")
    if runtime == null:
        push_error("AgentRuntime singleton unavailable")
        return {"ok": false, "error": "runtime_missing"}
    var request := options.duplicate(true)
    request["hf_file"] = file
    return runtime.call("download_model_hf", repo, request)

static func ensure_model(repo: String, file: String, options: Dictionary = {}) -> String:
    var response := download_hf(repo, file, options)
    if typeof(response) == TYPE_DICTIONARY and response.get("ok", false) and response.has("path"):
        return response["path"]
    if typeof(response) == TYPE_DICTIONARY and response.has("error"):
        push_warning("Model download failed: %s" % response["error"])
    return ""

static func ensure_request(request: Dictionary) -> String:
    if request.is_empty():
        return ""
    var response := download_request(request)
    if typeof(response) == TYPE_DICTIONARY and response.get("ok", false):
        return String(response.get("path", request.get("output_path", "")))
    if typeof(response) == TYPE_DICTIONARY and response.has("error"):
        push_warning("Model download failed: %s" % response["error"])
    return ""

static func get_cache_directory() -> String:
    var runtime := Engine.get_singleton("AgentRuntime")
    if runtime == null:
        return ""
    return runtime.call("get_model_cache_directory")
