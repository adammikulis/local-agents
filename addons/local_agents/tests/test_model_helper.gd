@tool
extends RefCounted
class_name LocalAgentsTestModelHelper

const MODEL_ID := "qwen3-0_6b-instruct-q4_k_m"
const MODEL_FILENAME := "Qwen3-0.6B-Q4_K_M.gguf"
const DEFAULT_FOLDER := "user://local_agents/models/qwen3-0_6b-instruct"
const MODEL_DOWNLOAD_SERVICE := preload("res://addons/local_agents/controllers/ModelDownloadService.gd")
const DOWNLOAD_CLIENT := preload("res://addons/local_agents/api/DownloadClient.gd")

func ensure_local_model() -> String:
    var existing := find_existing_model()
    if existing != "":
        return existing
    var runtime := _get_runtime()
    if runtime == null:
        push_warning("AgentRuntime unavailable; set LOCAL_AGENTS_TEST_GGUF manually.")
        return ""
    var request := _build_request()
    if request.is_empty():
        push_warning("Unable to build download request for %s" % MODEL_ID)
        return ""
    var result: Dictionary = runtime.call("download_model", request)
    if result.get("ok", false):
        var output_path := String(request.get("output_path", ""))
        if output_path != "" and FileAccess.file_exists(output_path):
            return output_path
    if result.has("error"):
        push_warning("download_model failed: %s" % result.get("error"))
    # Fall back to direct HF download to the resolved directory
    var repo := request.get("hf_repo", request.get("repo_id", ""))
    var file := request.get("hf_file", request.get("filename", MODEL_FILENAME))
    if repo != "" and file != "":
        var options := {
            "dir": request.get("output_path", "").get_base_dir(),
            "offline": false,
            "force": false,
        }
        var hf_result := DOWNLOAD_CLIENT.download_hf(repo, file, options)
        if hf_result.get("ok", false):
            var path := _locate_download_target()
            if path != "":
                return path
    return find_existing_model()

func find_existing_model() -> String:
    var candidates := []
    var env_path := OS.get_environment("LOCAL_AGENTS_TEST_GGUF").strip_edges()
    if env_path != "":
        candidates.append(_normalize_path(env_path))
    candidates.append(_normalize_path(DEFAULT_FOLDER.path_join(MODEL_FILENAME)))
    candidates.append(_locate_download_target())
    candidates.append_array(_scan_hf_cache())
    for path in candidates:
        if path != "" and FileAccess.file_exists(path):
            return path
    return ""

func _build_request() -> Dictionary:
    var service := MODEL_DOWNLOAD_SERVICE.new()
    var request := service.create_request({"skip_existing": false}, MODEL_ID)
    if request.is_empty():
        return {}
    return request

func _locate_download_target() -> String:
    var request := _build_request()
    if request.is_empty():
        return ""
    var output_path := String(request.get("output_path", ""))
    if output_path != "" and FileAccess.file_exists(output_path):
        return output_path
    return output_path

func _scan_hf_cache() -> Array:
    var results: Array = []
    var runtime := _get_runtime()
    if runtime and runtime.has_method("get_model_cache_directory"):
        var cache_dir := String(runtime.call("get_model_cache_directory"))
        if cache_dir != "":
            var candidate := cache_dir.path_join(MODEL_FILENAME)
            if FileAccess.file_exists(candidate):
                results.append(candidate)
    var home := OS.get_environment("HOME")
    if home != "":
        var base := home.path_join(".cache/huggingface/hub")
        var repo_dir := base.path_join("models--ggml-org--Qwen3-0.6B-GGUF")
        var snapshots := repo_dir.path_join("snapshots")
        if DirAccess.dir_exists_absolute(snapshots):
            var dir := DirAccess.open(snapshots)
            if dir:
                dir.list_dir_begin()
                var name := dir.get_next()
                while name != "":
                    if name != "." and name != "..":
                        var candidate := snapshots.path_join(name).path_join(MODEL_FILENAME)
                        if FileAccess.file_exists(candidate):
                            results.append(candidate)
                    name = dir.get_next()
                dir.list_dir_end()
    return results

func _normalize_path(path: String) -> String:
    if path == "":
        return ""
    if path.begins_with("res://") or path.begins_with("user://"):
        return ProjectSettings.globalize_path(path)
    return path

func _get_runtime() -> Object:
    if Engine.has_singleton("AgentRuntime"):
        return Engine.get_singleton("AgentRuntime")
    return null
