extends RefCounted
class_name LocalAgentsCulturalCycleDriverSynthesizer

const CulturalCycleHelpersScript = preload("res://addons/local_agents/simulation/CulturalCycleHelpers.gd")

func synthesize(system, tick: int, world_id: String, branch_id: String, context_snapshot: Dictionary, context_cues: Dictionary, deterministic_seed: int) -> Dictionary:
	var synthesized: Dictionary = {}
	if bool(system.llm_enabled):
		var prompt = _build_driver_prompt(world_id, branch_id, tick, context_snapshot)
		var runtime_result = _generate_driver_payload(system, prompt, deterministic_seed)
		if bool(runtime_result.get("ok", false)):
			synthesized = runtime_result
	var rows: Array = synthesized.get("drivers", [])
	if rows.is_empty():
		rows = CulturalCycleHelpersScript.heuristic_driver_payload(context_snapshot)
	rows = _merge_with_context_cue_drivers(rows, context_cues)
	var out = CulturalCycleHelpersScript.sanitize_drivers(rows)
	return {
		"drivers": out,
		"trace": synthesized.get("trace", {}),
	}

func _merge_with_context_cue_drivers(rows: Array, context_cues: Dictionary) -> Array:
	var out = rows.duplicate(true)
	var oral_topic_drivers: Dictionary = context_cues.get("oral_topic_drivers", {})
	var keys = oral_topic_drivers.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	for key_variant in keys:
		var topic = String(key_variant).strip_edges()
		if topic == "":
			continue
		var cue_variant = oral_topic_drivers.get(topic, null)
		if not (cue_variant is Dictionary):
			continue
		var cue = cue_variant as Dictionary
		out.append({
			"label": "context_cue_%s" % topic,
			"topic": topic,
			"gain_loss": clampf(float(cue.get("gain_loss", 0.0)), -1.0, 1.0),
			"salience": clampf(float(cue.get("salience", 0.0)), 0.0, 1.0),
			"scope": "settlement",
			"owner_id": "",
			"tags": cue.get("tags", []),
			"summary": String(cue.get("summary", "context cue")).strip_edges(),
		})
	return out

func _build_driver_prompt(world_id: String, branch_id: String, tick: int, context_snapshot: Dictionary) -> String:
	var compact = CulturalCycleHelpersScript.compact_context_for_prompt(context_snapshot)
	return """
You are deriving CULTURAL DRIVERS for a village simulation.
Infer drivers only from the provided state. Do not invent named events.
Model gain/loss and belonging/ownership dynamics:
- Gains include continuity, stored food, stable shelter, social bonds.
- Losses include scarcity, displacement, fragmentation, insecurity.
- More extreme shifts should produce higher salience.
- Property/ownership/belonging must influence resulting drivers.
Return STRICT JSON with this schema:
{
  "drivers": [
    {
      "label": "short_snake_case",
      "topic": "one_of:[water_route_reliability,safe_foraging_zones,seasonal_weather_cues,toolcraft_recipe,ritual_obligation,belonging_oath,kinship_continuity,ownership_boundary,bone_craft_memory]",
      "gain_loss": -1.0_to_1.0,
      "salience": 0.0_to_1.0,
      "scope": "settlement_or_household",
      "owner_id": "household_id_or_empty",
      "tags": ["belonging","ownership","food","water","kinship","weather","bone","ritual","craft"],
      "summary": "brief phrase"
    }
  ]
}
world_id=%s
branch_id=%s
tick=%d
state=%s
""" % [world_id, branch_id, tick, JSON.stringify(compact, "", false, true)]

func _generate_driver_payload(system, prompt: String, deterministic_seed: int) -> Dictionary:
	if not Engine.has_singleton("AgentRuntime"):
		return {"ok": false, "error": "runtime_missing"}
	var runtime = Engine.get_singleton("AgentRuntime")
	if runtime == null or not runtime.has_method("generate"):
		return {"ok": false, "error": "runtime_generate_unavailable"}
	if runtime.has_method("is_model_loaded") and not runtime.call("is_model_loaded"):
		return {"ok": false, "error": "model_not_loaded"}
	var schema := CulturalCycleHelpersScript.driver_json_schema()
	var options = _merged_runtime_options(system, deterministic_seed)
	options["response_format"] = {
		"type": "json_schema",
		"schema": schema,
	}
	options["json_schema"] = schema
	options["output_json"] = true
	var request = {
		"prompt": prompt,
		"history": [],
		"options": options,
	}
	var result: Dictionary = runtime.call("generate", request)
	if not bool(result.get("ok", false)):
		return result
	var text = String(result.get("text", "")).strip_edges()
	if text == "":
		return {"ok": false, "error": "empty_generation"}
	var parsed = _parse_json_anywhere(text)
	if not (parsed is Dictionary):
		return {"ok": false, "error": "json_parse_failed"}
	var payload: Dictionary = parsed as Dictionary
	return {
		"ok": true,
		"drivers": payload.get("drivers", []),
		"trace": {
			"query_keys": ["culture_context_snapshot", "context_cues"],
			"referenced_ids": [],
			"profile_id": String(system._request_profile.profile_id),
			"seed": deterministic_seed,
			"sampler_params": _merged_runtime_options(system, deterministic_seed),
		},
	}

func _merged_runtime_options(system, seed: int) -> Dictionary:
	var merged: Dictionary = system._runtime_options.duplicate(true)
	var profile_options = system._request_profile.to_runtime_options(seed)
	for key_variant in profile_options.keys():
		var key = String(key_variant)
		merged[key] = profile_options[key]
	return merged

func _parse_json_anywhere(text: String):
	var parsed = _try_parse_json(text)
	if parsed != null:
		return parsed
	var first = text.find("{")
	var last = text.rfind("}")
	if first == -1 or last <= first:
		return null
	var fragment = text.substr(first, last - first + 1)
	return _try_parse_json(fragment)

func _try_parse_json(text: String):
	var json := JSON.new()
	var parse_error := json.parse(text)
	if parse_error != OK:
		return null
	return json.data
