extends RefCounted
class_name LocalAgentsNarratorDirector

const DEFAULT_PROMPT = "You are a simulation narrator. Provide concise direction for the town and villagers based on current state."

var enabled: bool = true
var temperature: float = 0.2
var max_tokens: int = 160

func generate_direction(world_snapshot: Dictionary, deterministic_seed: int, extra_prompt: String = "") -> Dictionary:
    if not enabled:
        return {"ok": false, "error": "narrator_disabled"}
    if not Engine.has_singleton("AgentRuntime"):
        return {"ok": false, "error": "runtime_missing"}
    var runtime = Engine.get_singleton("AgentRuntime")
    if runtime == null or not runtime.has_method("generate"):
        return {"ok": false, "error": "runtime_generate_unavailable"}
    if runtime.has_method("is_model_loaded") and not runtime.call("is_model_loaded"):
        return {"ok": false, "error": "model_not_loaded"}

    var prompt = "%s\n\nState:\n%s" % [DEFAULT_PROMPT, JSON.stringify(world_snapshot, "  ", false, true)]
    if extra_prompt.strip_edges() != "":
        prompt += "\n\nDirective constraints:\n" + extra_prompt.strip_edges()

    var request = {
        "prompt": prompt,
        "history": [],
        "options": {
            "temperature": temperature,
            "max_tokens": max_tokens,
            "seed": deterministic_seed,
            "reset_context": true,
            "cache_prompt": false,
        },
    }
    var result: Dictionary = runtime.call("generate", request)
    if not bool(result.get("ok", false)):
        return result
    return {
        "ok": true,
        "text": String(result.get("text", "")).strip_edges(),
        "source": "local_llm_narrator",
        "kind": "direction",
        "seed": deterministic_seed,
    }
