extends RefCounted
class_name LocalAgentsNarratorDirector

const DEFAULT_PROMPT = "You are a simulation narrator. Provide concise direction for the town and villagers based on current state."
const LlmRequestProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/LlmRequestProfileResource.gd")

var enabled: bool = true
var temperature: float = 0.2
var max_tokens: int = 160
var _request_profile = LlmRequestProfileResourceScript.new()

func _init() -> void:
	_request_profile.profile_id = "narrator_direction"
	_request_profile.temperature = temperature
	_request_profile.max_tokens = max_tokens
	_request_profile.top_p = 0.9
	_request_profile.stop = PackedStringArray(["\n\nUser:", "\n\nVillager:"])
	_request_profile.reset_context = true
	_request_profile.cache_prompt = false
	_request_profile.retry_count = 1
	_request_profile.retry_seed_step = 1

func set_request_profile(profile_resource: Resource) -> void:
	if profile_resource == null:
		return
	if profile_resource.has_method("to_dict"):
		_request_profile.from_dict(profile_resource.call("to_dict"))

func request_profile_id() -> String:
	return String(_request_profile.profile_id)

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
        "options": _request_profile.to_runtime_options(deterministic_seed),
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
        "trace": {
            "query_keys": ["world_snapshot"],
            "referenced_ids": [],
            "profile_id": String(_request_profile.profile_id),
            "seed": deterministic_seed,
            "sampler_params": _request_profile.to_runtime_options(deterministic_seed),
        },
    }
