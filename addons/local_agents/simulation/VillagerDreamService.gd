extends RefCounted
class_name LocalAgentsVillagerDreamService

const DreamInfluenceResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/DreamInfluenceResource.gd")
const LlmRequestProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/LlmRequestProfileResource.gd")

var llm_enabled: bool = true
var _influences: Dictionary = {}
var _request_profile = LlmRequestProfileResourceScript.new()

func _init() -> void:
	_request_profile.profile_id = "dream_generation"
	_request_profile.temperature = 0.7
	_request_profile.top_p = 0.95
	_request_profile.max_tokens = 140
	_request_profile.stop = PackedStringArray(["\nVillager:", "\nNarrator hint:"])
	_request_profile.reset_context = true
	_request_profile.cache_prompt = false
	_request_profile.retry_count = 1
	_request_profile.retry_seed_step = 1

func set_request_profile(profile_resource: Resource) -> void:
	if profile_resource == null:
		return
	if profile_resource.has_method("to_dict"):
		_request_profile.from_dict(profile_resource.call("to_dict"))

func set_dream_influence(npc_id: String, influence: Dictionary) -> void:
	if npc_id.strip_edges() == "":
		return
	var resource = DreamInfluenceResourceScript.new()
	resource.npc_id = npc_id
	resource.from_dict(influence)
	_influences[npc_id] = resource

func get_dream_influence(npc_id: String) -> Dictionary:
	if not _influences.has(npc_id):
		return {}
	var resource = _influences.get(npc_id, null)
	if resource == null:
		return {}
	return resource.to_dict()

func generate_dream_text(npc_id: String, villager_state: Dictionary, deterministic_seed: int, narrator_hint: String = "") -> Dictionary:
	var influence = get_dream_influence(npc_id)
	var mood = String(villager_state.get("mood", "neutral"))
	if not llm_enabled:
		return {"ok": false, "error": "llm_disabled"}

	if not Engine.has_singleton("AgentRuntime"):
		return {"ok": false, "error": "runtime_missing"}

	var runtime = Engine.get_singleton("AgentRuntime")
	if runtime == null or not runtime.has_method("generate"):
		return {"ok": false, "error": "runtime_generate_unavailable"}
	if runtime.has_method("is_model_loaded") and not runtime.call("is_model_loaded"):
		return {"ok": false, "error": "model_not_loaded"}

	var prompt = """
You are generating a dream for one villager.
Rules:
- Mark events as symbolic dream content, not factual events.
- Include emotional tone and one motif from influence guidance.
- Keep to 2-4 sentences.
Villager: %s
Mood: %s
Influence: %s
Narrator hint: %s
""" % [npc_id, mood, JSON.stringify(influence, "", false, true), narrator_hint]

	var request = {
		"prompt": prompt,
		"history": [],
		"options": _request_profile.to_runtime_options(deterministic_seed),
	}
	var result: Dictionary = runtime.call("generate", request)
	if not bool(result.get("ok", false)):
		return result
	var text := String(result.get("text", "")).strip_edges()
	if text != "":
		return {
			"ok": true,
			"text": text,
			"seed": deterministic_seed,
			"synthetic": false,
			"trace": {
				"query_keys": ["dream_influence", "villager_state"],
				"referenced_ids": [npc_id],
				"profile_id": String(_request_profile.profile_id),
				"seed": deterministic_seed,
				"sampler_params": _request_profile.to_runtime_options(deterministic_seed),
			},
		}

	var retry_max = maxi(0, int(_request_profile.retry_count))
	var retry_step = maxi(1, int(_request_profile.retry_seed_step))
	var retry_text := ""
	var used_seed = deterministic_seed
	for attempt in range(retry_max):
		used_seed = deterministic_seed + retry_step * (attempt + 1)
		var retry_request = {
			"prompt": "%s\nRespond with at least two short sentences." % prompt,
			"history": [],
			"options": _request_profile.to_runtime_options(used_seed),
		}
		var retry_result: Dictionary = runtime.call("generate", retry_request)
		if not bool(retry_result.get("ok", false)):
			return retry_result
		retry_text = String(retry_result.get("text", "")).strip_edges()
		if retry_text != "":
			break
	if retry_text == "":
		return {"ok": false, "error": "empty_generation"}
	return {
		"ok": true,
		"text": retry_text,
		"seed": used_seed,
		"synthetic": false,
		"trace": {
			"query_keys": ["dream_influence", "villager_state"],
			"referenced_ids": [npc_id],
			"profile_id": String(_request_profile.profile_id),
			"seed": used_seed,
			"sampler_params": _request_profile.to_runtime_options(used_seed),
		},
	}

func dream_memory_metadata(influence: Dictionary, dream_seed: int) -> Dictionary:
	return {
		"memory_kind": "dream",
		"is_dream": true,
		"influence": influence.duplicate(true),
		"dream_seed": dream_seed,
	}

func compute_dream_effect(dream_text: String) -> Dictionary:
	var text = dream_text.to_lower()
	var morale_delta = 0.0
	var fear_delta = 0.0
	if text.contains("warm") or text.contains("light") or text.contains("festival"):
		morale_delta += 0.1
	if text.contains("storm") or text.contains("shadow") or text.contains("chase"):
		fear_delta += 0.15
		morale_delta -= 0.05
	return {
		"morale_delta": clampf(morale_delta, -0.25, 0.25),
		"fear_delta": clampf(fear_delta, 0.0, 0.5),
	}

func apply_dream_effect(villager_state: Dictionary, effect: Dictionary) -> Dictionary:
	var state = villager_state.duplicate(true)
	var morale = float(state.get("morale", 0.5))
	var fear = float(state.get("fear", 0.0))
	morale = clampf(morale + float(effect.get("morale_delta", 0.0)), 0.0, 1.0)
	fear = clampf(fear + float(effect.get("fear_delta", 0.0)), 0.0, 1.0)
	state["morale"] = morale
	state["fear"] = fear
	state["last_dream_effect"] = effect.duplicate(true)
	return state
