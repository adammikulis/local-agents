@tool
extends RefCounted
class_name LocalAgentsModelDownloadService

const CATALOG_PATH := "res://addons/local_agents/models/catalog.json"
const MODELS_ROOT := "res://addons/local_agents/models"
const DEFAULT_MODEL_ID := "qwen3-4b-instruct-q4_k_m"

const FALLBACK_MODEL := {
    "id": DEFAULT_MODEL_ID,
    "label": "Qwen3 4B Instruct (Q4_K_M)",
    "repo_id": "unsloth/Qwen3-4B-Instruct-2507-GGUF",
    "filename": "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
    "folder": "qwen3-4b-instruct",
    "parameters": "4B",
    "quantization": "Q4_K_M",
    "size_bytes": 2497281120,
    "updated_at": "2025-08-20T06:23:07Z",
    "recommended": true
}

var _catalog_cache: Dictionary = {}
var _catalog_loaded := false

func reload_catalog() -> void:
    _catalog_loaded = false
    _catalog_cache = {}

func get_catalog() -> Dictionary:
    if _catalog_loaded:
        return _catalog_cache
    _catalog_loaded = true
    _catalog_cache = {}
    if not FileAccess.file_exists(CATALOG_PATH):
        push_warning("Local Agents model catalog missing: %s" % CATALOG_PATH)
        return _catalog_cache
    var file := FileAccess.open(CATALOG_PATH, FileAccess.READ)
    if file == null:
        push_warning("Unable to open model catalog: %s" % CATALOG_PATH)
        return _catalog_cache
    var text := file.get_as_text()
    var parsed := JSON.parse_string(text)
    if typeof(parsed) == TYPE_DICTIONARY:
        _catalog_cache = parsed
    else:
        push_warning("Model catalog parse error: expected Dictionary, got %s" % typeof(parsed))
    return _catalog_cache

func list_families() -> Array:
    var catalog := get_catalog()
    var families: Array = catalog.get("families", [])
    var result: Array = []
    for family_data in families:
        var family := {
            "id": family_data.get("id", ""),
            "label": family_data.get("label", ""),
            "description": family_data.get("description", ""),
            "models": []
        }
        var models: Array = family_data.get("models", [])
        for model_data in models:
            family["models"].append(_normalize_model(model_data, family))
        family["models"].sort_custom(Callable(self, "_compare_models"))
        result.append(family)
    result.sort_custom(Callable(self, "_compare_families"))
    return result

func list_models_flat() -> Array:
    var flattened: Array = []
    for family in list_families():
        for model in family.get("models", []):
            flattened.append(model)
    flattened.sort_custom(Callable(self, "_compare_models"))
    return flattened

func find_model(model_id: String) -> Dictionary:
    if model_id.is_empty():
        return {}
    for family in list_families():
        for model in family.get("models", []):
            if model.get("id", "") == model_id:
                return model
    return {}

func get_default_model() -> Dictionary:
    for family in list_families():
        for model in family.get("models", []):
            if model.get("recommended", false):
                return model
    var fallback := _normalize_model(FALLBACK_MODEL, {
        "id": "fallback",
        "label": "Fallback"
    })
    return fallback

func create_request(overrides: Dictionary = {}, model_id: String = "") -> Dictionary:
    var target := {}
    if model_id != "":
        target = find_model(model_id)
    elif overrides.has("id"):
        target = find_model(overrides.get("id", ""))
    if target.is_empty():
        target = get_default_model()
    if target.is_empty():
        return {}

    var url := target.get("download_url", "")
    if url.is_empty():
        url = _build_download_url(target)
    var output_path := _resolve_output_path(target)
    if output_path.is_empty():
        push_warning("Unable to resolve output path for %s" % target.get("id", ""))
        return {}

    var request := {
        "url": url,
        "output_path": output_path,
        "label": target.get("label", target.get("filename", "")),
        "force": overrides.get("force", false),
        "skip_existing": overrides.get("skip_existing", true)
    }

    var hf_repo := target.get("hf_repo", target.get("repo_id", ""))
    if hf_repo != "":
        request["hf_repo"] = hf_repo
    var hf_file := target.get("hf_file", target.get("filename", ""))
    if hf_file != "":
        request["hf_file"] = hf_file
    if target.has("hf_tag"):
        request["hf_tag"] = target["hf_tag"]
    if target.has("hf_endpoint"):
        request["hf_endpoint"] = target["hf_endpoint"]

    if overrides.has("headers"):
        request["headers"] = overrides["headers"]
    if overrides.has("bearer_token"):
        request["bearer_token"] = overrides["bearer_token"]
    if overrides.has("timeout_seconds"):
        request["timeout_seconds"] = overrides["timeout_seconds"]

    return request

func format_size(size_bytes: int) -> String:
    if size_bytes <= 0:
        return "Unknown"
    var units := ["B", "KB", "MB", "GB", "TB"]
    var size := float(size_bytes)
    var idx := 0
    while size >= 1024.0 and idx < units.size() - 1:
        size /= 1024.0
        idx += 1
    if idx <= 1:
        return "%d %s" % [int(round(size)), units[idx]]
    return "%.2f %s" % [size, units[idx]]

func _normalize_model(model_data: Dictionary, family: Dictionary) -> Dictionary:
    var normalized := model_data.duplicate(true)
    normalized["family_id"] = family.get("id", "")
    normalized["family_label"] = family.get("label", "")
    normalized["family_description"] = family.get("description", "")
    normalized["download_url"] = _build_download_url(normalized)
    normalized["repo_url"] = _build_repo_url(normalized)
    normalized["size_pretty"] = format_size(int(normalized.get("size_bytes", 0)))
    normalized["updated_timestamp"] = _parse_timestamp(normalized.get("updated_at", ""))
    var repo_id := normalized.get("repo_id", "")
    if normalized.get("hf_repo", "") == "" and repo_id != "":
        normalized["hf_repo"] = repo_id
    var hf_file := normalized.get("hf_file", normalized.get("filename", ""))
    if hf_file != "":
        normalized["hf_file"] = hf_file
    return normalized

func _build_download_url(model: Dictionary) -> String:
    var repo := model.get("repo_id", "")
    var filename := model.get("filename", "")
    if repo.is_empty() or filename.is_empty():
        return ""
    return "https://huggingface.co/%s/resolve/main/%s" % [repo, filename]

func _build_repo_url(model: Dictionary) -> String:
    var repo := model.get("repo_id", "")
    if repo.is_empty():
        return ""
    return "https://huggingface.co/%s" % repo

func _resolve_output_path(model: Dictionary) -> String:
    var folder := model.get("folder", "")
    var filename := model.get("filename", "")
    if filename.is_empty():
        return ""
    var local_dir := MODELS_ROOT
    if not folder.is_empty():
        local_dir = "%s/%s" % [MODELS_ROOT, folder]
    var absolute_dir := ProjectSettings.globalize_path(local_dir)
    var err := DirAccess.make_dir_recursive_absolute(absolute_dir)
    if err != OK and err != ERR_ALREADY_EXISTS:
        push_warning("Unable to ensure model directory %s (error %d)" % [absolute_dir, err])
    return "%s/%s" % [absolute_dir, filename]

func _parse_timestamp(value: String) -> int:
    if value.is_empty():
        return 0
    return int(Time.get_unix_time_from_datetime_string(value))

func _compare_models(a: Dictionary, b: Dictionary) -> bool:
    var a_time := a.get("updated_timestamp", 0)
    var b_time := b.get("updated_timestamp", 0)
    if a_time != b_time:
        return a_time > b_time
    var a_size := int(a.get("size_bytes", 0))
    var b_size := int(b.get("size_bytes", 0))
    if a_size != b_size:
        return a_size > b_size
    return String(a.get("label", "")) < String(b.get("label", ""))

func _compare_families(a: Dictionary, b: Dictionary) -> bool:
    var a_label := String(a.get("label", ""))
    var b_label := String(b.get("label", ""))
    return a_label < b_label
