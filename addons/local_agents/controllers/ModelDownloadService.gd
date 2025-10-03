@tool
extends RefCounted
class_name LocalAgentsModelDownloadService

const DEFAULT_MODEL := {
    "id": "qwen2_5_3b_q4km",
    "label": "Qwen2.5 3B Instruct Q4_K_M",
    "url": "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf",
    "folder": "qwen3-4b-instruct",
    "filename": "qwen2.5-3b-instruct-q4_k_m.gguf",
    "skip_existing": true,
}

func get_default_model() -> Dictionary:
    return DEFAULT_MODEL.duplicate(true)

func create_request(overrides: Dictionary = {}) -> Dictionary:
    var config := get_default_model()
    for key in overrides.keys():
        config[key] = overrides[key]

    if not config.has("url") or not config.has("filename"):
        return {}

    var local_dir := "res://addons/local_agents/models/%s" % config.get("folder", "models")
    var absolute_dir := ProjectSettings.globalize_path(local_dir)
    var output_path := "%s/%s" % [absolute_dir, config["filename"]]

    var request := {
        "url": config["url"],
        "output_path": output_path,
        "label": config.get("label", config["filename"]),
        "force": overrides.get("force", false),
        "skip_existing": overrides.get("skip_existing", config.get("skip_existing", true))
    }

    if overrides.has("headers"):
        request["headers"] = overrides["headers"]
    if overrides.has("bearer_token"):
        request["bearer_token"] = overrides["bearer_token"]
    if overrides.has("timeout_seconds"):
        request["timeout_seconds"] = overrides["timeout_seconds"]

    return request
