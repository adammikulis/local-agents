@tool
extends RefCounted
class_name LocalAgentsRuntimePaths

const RUNTIMES_BASE := "res://addons/local_agents/gdextensions/localagents/bin/runtimes"
const MODELS_USER_ROOT := "user://local_agents/models"
const MODELS_RES_ROOT := "res://addons/local_agents/models"
const VOICES_RES_ROOT := "res://addons/local_agents/voices"
const DEFAULT_MODEL_SUBPATH := "qwen3-4b-instruct/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"

static func detect_platform_subdir() -> String:
    var os_name := OS.get_name()
    if os_name == "macOS":
        return "macos_arm64" if OS.has_feature("arm64") else "macos_x86_64"
    if os_name == "Windows":
        return "windows_x86_64"
    if os_name == "Linux":
        if OS.has_feature("aarch64") or OS.has_feature("arm64"):
            return "linux_aarch64"
        if OS.has_feature("x86_64"):
            return "linux_x86_64"
        if OS.has_feature("armv7"):
            return "linux_armv7l"
    if os_name == "Android":
        return "android_arm64"
    return ""

static func runtime_dir(preferred: String = "", ensure_exists: bool = false) -> String:
    var scoped := preferred.strip_edges()
    if scoped != "":
        if ensure_exists and not _dir_exists(scoped):
            return ""
        return scoped
    var candidate := "%s/%s" % [RUNTIMES_BASE, detect_platform_subdir()]
    if _dir_exists(candidate):
        return candidate
    if _dir_exists(RUNTIMES_BASE):
        return RUNTIMES_BASE
    return ""

static func runtime_dir_absolute(preferred: String = "") -> String:
    var dir := runtime_dir(preferred)
    if dir == "":
        return ""
    return ProjectSettings.globalize_path(dir) if dir.begins_with("res://") or dir.begins_with("user://") else dir

static func resolve_executable(name: String, preferred_dir: String = "") -> String:
    var base_dir := runtime_dir(preferred_dir, true)
    if base_dir == "":
        return ""
    var candidates := PackedStringArray()
    candidates.append("%s/%s" % [base_dir, name])
    candidates.append("%s/%s%s" % [base_dir, name, _platform_executable_suffix()])
    for path in candidates:
        var normalized := _normalize_path(path)
        if normalized != "" and FileAccess.file_exists(normalized):
            return normalized
    return ""

static func resolve_voice_assets(voice_id: String, voice_root_overrides: Array = []) -> Dictionary:
    var trimmed := voice_id.strip_edges()
    if trimmed.is_empty():
        return {}
    var search_roots := []
    if voice_root_overrides:
        search_roots.append_array(voice_root_overrides)
    search_roots.append(VOICES_RES_ROOT)
    var candidates: Array[String] = []
    if trimmed.begins_with("res://") or trimmed.begins_with("user://") or _looks_absolute(trimmed):
        candidates.append(trimmed)
    else:
        candidates.append("%s/%s" % [VOICES_RES_ROOT, trimmed])
        if not trimmed.ends_with(".onnx"):
            candidates.append("%s/%s/%s-high.onnx" % [VOICES_RES_ROOT, trimmed, trimmed])
            candidates.append("%s/%s/%s.onnx" % [VOICES_RES_ROOT, trimmed, trimmed])
    for candidate in candidates:
        var normalized := _normalize_path(candidate)
        if normalized == "":
            continue
        if FileAccess.file_exists(normalized):
            var config_path := normalized + ".json"
            var result := {
                "model": normalized,
                "config": config_path if FileAccess.file_exists(config_path) else "",
            }
            return result
    for override_root in search_roots:
        var normalized_root := _normalize_path(override_root)
        if normalized_root == "":
            continue
        var direct := "%s/%s" % [normalized_root, trimmed]
        if FileAccess.file_exists(direct):
            var cfg := direct + ".json"
            return {"model": direct, "config": cfg if FileAccess.file_exists(cfg) else ""}
    return {}

static func ensure_models_dir() -> String:
    var abs_path := ProjectSettings.globalize_path(MODELS_USER_ROOT)
    DirAccess.make_dir_recursive_absolute(abs_path)
    return MODELS_USER_ROOT

static func default_model_candidates() -> Array:
    ensure_models_dir()
    return [
        "%s/%s" % [MODELS_USER_ROOT, DEFAULT_MODEL_SUBPATH],
        "%s/%s" % [MODELS_RES_ROOT, DEFAULT_MODEL_SUBPATH],
    ]

static func resolve_default_model() -> String:
    for candidate in default_model_candidates():
        var normalized := _normalize_path(candidate)
        if normalized != "" and FileAccess.file_exists(normalized):
            return normalized
    return ""

static func ensure_tts_output_dir() -> String:
    var rel := "user://local_agents/tts"
    var abs := ProjectSettings.globalize_path(rel)
    DirAccess.make_dir_recursive_absolute(abs)
    return rel

static func make_tts_output_path(prefix: String = "tts") -> String:
    var dir := ensure_tts_output_dir()
    var stamp := Time.get_datetime_string_from_system(true, true).replace(":", "-")
    return "%s/%s-%s.wav" % [dir, prefix, stamp]

static func normalize_path(path: String) -> String:
    return _normalize_path(path)

static func is_absolute_path(path: String) -> bool:
    return _looks_absolute(path)

static func _normalize_path(path: String) -> String:
    if path == "":
        return ""
    if path.begins_with("res://") or path.begins_with("user://"):
        return ProjectSettings.globalize_path(path)
    return path

static func _dir_exists(path: String) -> bool:
    var normalized := _normalize_path(path)
    return DirAccess.dir_exists_absolute(normalized)

static func _looks_absolute(path: String) -> bool:
    if path.begins_with("/"):
        return true
    if path.length() > 1 and path[1] == ":":
        return true
    return false

static func _platform_executable_suffix() -> String:
    return ".exe" if OS.get_name() == "Windows" else ""
