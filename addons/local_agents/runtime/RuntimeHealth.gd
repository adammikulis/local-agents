@tool
extends RefCounted
class_name LocalAgentsRuntimeHealth

static func summarize() -> Dictionary:
    var result := {
        "runtime": "Runtime: unavailable",
        "speech": "Speech: unavailable",
        "model_loaded": false,
    }
    if not Engine.has_singleton("AgentRuntime"):
        return result
    var runtime := Engine.get_singleton("AgentRuntime")
    if runtime == null:
        return result

    var model_loaded := false
    if runtime.has_method("is_model_loaded"):
        model_loaded = bool(runtime.call("is_model_loaded"))
    result["model_loaded"] = model_loaded

    var runtime_ok := false
    var speech_ok := false
    if runtime.has_method("get_runtime_health"):
        var health: Dictionary = runtime.call("get_runtime_health")
        runtime_ok = bool(health.get("runtime_directory_exists", false))
        var missing = health.get("missing_binaries", PackedStringArray())
        if missing is PackedStringArray:
            speech_ok = not missing.has("piper")
        elif missing is Array:
            speech_ok = not missing.has("piper")

    result["runtime"] = "Runtime: loaded" if runtime_ok else "Runtime: missing binaries"
    result["speech"] = "Speech: ready" if speech_ok else "Speech: missing voice runtime"
    if model_loaded:
        result["runtime"] += " | model: loaded"
    return result
