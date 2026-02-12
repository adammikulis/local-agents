extends RefCounted
class_name LocalAgentsCulturalCycleSystem

var _oral_last_item: Dictionary = {}
var _confidence_by_topic: Dictionary = {}
var _last_driver_digest: Dictionary = {}
var llm_enabled: bool = true

func export_state() -> Dictionary:
	return {
		"oral_last_item": _oral_last_item.duplicate(true),
		"confidence_by_topic": _confidence_by_topic.duplicate(true),
		"last_driver_digest": _last_driver_digest.duplicate(true),
	}

func import_state(payload: Dictionary) -> void:
	_oral_last_item = payload.get("oral_last_item", {}).duplicate(true)
	_confidence_by_topic = payload.get("confidence_by_topic", {}).duplicate(true)
	_last_driver_digest = payload.get("last_driver_digest", {}).duplicate(true)

func step(tick: int, context: Dictionary) -> Dictionary:
	var oral_events: Array = []
	var ritual_events: Array = []
	var drivers: Array = []
	var graph = context.get("graph_service", null)
	if graph == null:
		return {"oral_events": oral_events, "ritual_events": ritual_events, "drivers": drivers}

	var rng = context.get("rng", null)
	var world_id = String(context.get("world_id", "world_main"))
	var branch_id = String(context.get("branch_id", "main"))
	var household_members: Dictionary = context.get("household_members", {})
	var npc_ids: Array = context.get("npc_ids", [])
	var sacred_site_id = String(context.get("sacred_site_id", ""))
	var context_snapshot: Dictionary = context.get("culture_context", {})
	var context_cues: Dictionary = context.get("context_cues", {})
	var deterministic_seed = int(context.get("deterministic_seed", 1))
	drivers = _synthesize_cultural_drivers(tick, world_id, branch_id, context_snapshot, context_cues, deterministic_seed)

	if tick > 0 and tick % 24 == 18:
		_decay_confidence()
		oral_events = _run_oral_schedule(tick, graph, rng, world_id, branch_id, household_members, context_snapshot, context_cues, drivers)
	if sacred_site_id != "" and tick > 0 and tick % 72 == 30:
		ritual_events = _run_ritual_schedule(tick, graph, rng, world_id, branch_id, sacred_site_id, npc_ids, drivers)
	_last_driver_digest = _driver_digest(drivers)
	return {"oral_events": oral_events, "ritual_events": ritual_events, "drivers": drivers}

func _run_oral_schedule(tick: int, graph, rng, world_id: String, branch_id: String, household_members: Dictionary, context_snapshot: Dictionary, context_cues: Dictionary, drivers: Array) -> Array:
	var rows: Array = []
	var world_day = int(tick / 24)
	var household_ids = household_members.keys()
	household_ids.sort()
	for household_id_variant in household_ids:
		var household_id = String(household_id_variant)
		var members: Array = household_members.get(household_id, [])
		if members.size() < 2:
			continue
		members.sort()
		var speaker_id = String(members[0])
		var listener_index = 1 + rng.randi_range("oral_listener", household_id, branch_id, tick, 0, members.size() - 2)
		var listener_id = String(members[listener_index])
		var household_context: Dictionary = _household_context_for(household_id, context_snapshot)
		var topic_weights = _topic_weights_for_household(household_id, household_context, context_cues, drivers)
		var topic = _select_weighted_topic(topic_weights, rng, household_id, branch_id, tick)
		if topic == "":
			topic = "belonging_oath"
		var signal_strength = rng.randomf("oral_signal", household_id + ":" + topic, branch_id, tick)
		var topic_salience = _topic_salience(topic, household_id, drivers)
		var topic_gain_loss = _topic_gain_loss(topic, household_id, drivers)
		var confidence = clampf(0.58 + signal_strength * 0.22 + float(_confidence_by_topic.get(topic, 0.0)) * 0.18 + topic_salience * 0.24, 0.2, 0.99)
		_confidence_by_topic[topic] = clampf(float(_confidence_by_topic.get(topic, 0.5)) * 0.82 + confidence * 0.18, 0.0, 1.0)
		var item_id = "ok:%s:%s:%s:%s:%d" % [world_id, branch_id, household_id, topic, world_day]
		var content = _topic_content(topic, household_id, household_context, drivers)
		var write = graph.record_oral_knowledge(
			item_id,
			listener_id,
			topic,
			content,
			confidence,
			[topic],
			world_day,
			{
				"source_kind": "oral_transfer",
				"source_id": "household:%s" % household_id,
				"speaker_npc_id": speaker_id,
				"transmission_hops": 1,
			}
		)
		if not bool(write.get("ok", false)):
			continue
		var lineage_key = "%s|%s" % [household_id, topic]
		var previous_id = String(_oral_last_item.get(lineage_key, ""))
		if previous_id != "" and previous_id != item_id:
			graph.link_oral_knowledge_lineage(previous_id, item_id, speaker_id, listener_id, 1, world_day)
		_oral_last_item[lineage_key] = item_id
		rows.append({
			"household_id": household_id,
			"speaker_npc_id": speaker_id,
			"listener_npc_id": listener_id,
			"knowledge_id": item_id,
			"topic": topic,
			"confidence": confidence,
			"salience": topic_salience,
			"gain_loss": topic_gain_loss,
			"metadata": {
				"salience": topic_salience,
				"gain_loss": topic_gain_loss,
			},
		})
	return rows

func _run_ritual_schedule(tick: int, graph, rng, world_id: String, branch_id: String, sacred_site_id: String, npc_ids: Array, drivers: Array) -> Array:
	if npc_ids.is_empty():
		return []
	var participants = npc_ids.duplicate()
	participants.sort()
	if participants.size() > 4:
		participants.resize(4)
	var world_day = int(tick / 24)
	var ritual_id = "ritual:%s:%s:%d" % [world_id, branch_id, world_day]
	var ambient = rng.randomf("ritual_cohesion", sacred_site_id, branch_id, tick)
	var driver_intensity = _ritual_driver_intensity(drivers)
	var ritual_gain_loss = _ritual_gain_loss(drivers)
	var cohesion = clampf(0.34 + ambient * 0.28 + driver_intensity * 0.38, 0.2, 0.99)
	var dominant = _dominant_driver_label(drivers)
	var write = graph.record_ritual_event(
		ritual_id,
		sacred_site_id,
		world_day,
		participants,
		{
			"cohesion": cohesion,
			"tick": tick,
			"driver": dominant,
			"salience": driver_intensity,
			"gain_loss": ritual_gain_loss,
		},
		{"source_kind": "ritual_cycle"}
	)
	if not bool(write.get("ok", false)):
		return []
	return [{
		"ritual_id": ritual_id,
		"site_id": sacred_site_id,
		"world_day": world_day,
		"participants": participants,
		"cohesion": cohesion,
		"driver": dominant,
		"salience": driver_intensity,
		"gain_loss": ritual_gain_loss,
		"metadata": {
			"salience": driver_intensity,
			"gain_loss": ritual_gain_loss,
		},
	}]

func _decay_confidence() -> void:
	var keys = _confidence_by_topic.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	for key in keys:
		var topic = String(key)
		_confidence_by_topic[topic] = clampf(float(_confidence_by_topic.get(topic, 0.0)) * 0.96, 0.0, 1.0)

func _topic_content(topic: String, household_id: String, household_context: Dictionary, drivers: Array) -> String:
	var driver_hint = _dominant_driver_label(drivers)
	var biome = String(household_context.get("biome", "plains"))
	match topic:
		"water_route_reliability":
			return "Follow the reliable channel near %s before midday." % household_id
		"safe_foraging_zones":
			return "Gather roots along the safer slope edges around %s." % household_id
		"seasonal_weather_cues":
			return "Low morning haze means stronger valley winds by dusk."
		"toolcraft_recipe":
			return "Harden stone flakes in brief hearth heat before binding."
		"ritual_obligation":
			return "Bring clean water first before the spring-circle rite."
		"belonging_oath":
			return "Who keeps hearth and stores in %s belongs to its future." % household_id
		"kinship_continuity":
			return "Keep names and duties remembered so %s remains one body." % household_id
		"ownership_boundary":
			return "Mark what %s guards and what is shared, then keep the boundary." % household_id
		"bone_craft_memory":
			return "Bone from hard-won meat in %s is kept, carved, and taught." % household_id
		_:
			return "Remember %s paths in the %s; hold to %s." % [household_id, biome, driver_hint]

func _household_context_for(household_id: String, context_snapshot: Dictionary) -> Dictionary:
	var households: Array = context_snapshot.get("households", [])
	for row_variant in households:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		if String(row.get("household_id", "")) == household_id:
			return row
	return {}

func _topic_weights_for_household(household_id: String, household_context: Dictionary, context_cues: Dictionary, drivers: Array) -> Dictionary:
	var weights: Dictionary = {
		"water_route_reliability": 0.6,
		"safe_foraging_zones": 0.6,
		"seasonal_weather_cues": 0.55,
		"toolcraft_recipe": 0.52,
		"ritual_obligation": 0.48,
		"belonging_oath": 0.64,
		"kinship_continuity": 0.57,
		"ownership_boundary": 0.59,
		"bone_craft_memory": 0.49,
	}
	var water_reliability = clampf(float(household_context.get("water_reliability", 0.5)), 0.0, 1.0)
	var food = maxf(0.0, float(household_context.get("food", 0.0)))
	var structures = maxi(0, int(household_context.get("active_structures", 0)))
	var belonging_index = clampf(float(household_context.get("belonging_index", 0.5)), 0.0, 3.0)
	weights["water_route_reliability"] = float(weights["water_route_reliability"]) + (1.0 - water_reliability) * 0.8
	weights["safe_foraging_zones"] = float(weights["safe_foraging_zones"]) + (0.9 - clampf(food / 4.0, 0.0, 0.9)) * 0.55
	weights["ownership_boundary"] = float(weights["ownership_boundary"]) + clampf(float(structures) * 0.14, 0.0, 0.5)
	weights["belonging_oath"] = float(weights["belonging_oath"]) + clampf(belonging_index * 0.18, 0.0, 0.5)
	weights["kinship_continuity"] = float(weights["kinship_continuity"]) + clampf(belonging_index * 0.12, 0.0, 0.32)
	_apply_context_cues_to_topic_weights(weights, context_cues)

	for driver_variant in drivers:
		if not (driver_variant is Dictionary):
			continue
		var driver = driver_variant as Dictionary
		var scope = String(driver.get("scope", "settlement"))
		var owner_id = String(driver.get("owner_id", ""))
		if scope == "household" and owner_id != "" and owner_id != household_id:
			continue
		var salience = clampf(float(driver.get("salience", 0.0)), 0.0, 1.0)
		var gain_loss = clampf(float(driver.get("gain_loss", 0.0)), -1.0, 1.0)
		var tags: Array = driver.get("tags", [])
		var topic = String(driver.get("topic", ""))
		if topic != "" and weights.has(topic):
			weights[topic] = float(weights[topic]) + salience * 0.8 + absf(gain_loss) * 0.35
		for tag_variant in tags:
			var tag = String(tag_variant)
			match tag:
				"belonging":
					weights["belonging_oath"] = float(weights["belonging_oath"]) + salience * 0.65
					weights["kinship_continuity"] = float(weights["kinship_continuity"]) + salience * 0.44
				"ownership":
					weights["ownership_boundary"] = float(weights["ownership_boundary"]) + salience * 0.7
				"water":
					weights["water_route_reliability"] = float(weights["water_route_reliability"]) + salience * 0.68
				"food":
					weights["safe_foraging_zones"] = float(weights["safe_foraging_zones"]) + salience * 0.58
				"bone":
					weights["bone_craft_memory"] = float(weights["bone_craft_memory"]) + salience * 0.74
				"ritual":
					weights["ritual_obligation"] = float(weights["ritual_obligation"]) + salience * 0.48
				"weather":
					weights["seasonal_weather_cues"] = float(weights["seasonal_weather_cues"]) + salience * 0.52
				_:
					pass
	return weights

func _apply_context_cues_to_topic_weights(weights: Dictionary, context_cues: Dictionary) -> void:
	var oral_topic_drivers: Dictionary = context_cues.get("oral_topic_drivers", {})
	var keys = oral_topic_drivers.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	for key_variant in keys:
		var topic = String(key_variant)
		if not weights.has(topic):
			continue
		var cue_variant = oral_topic_drivers.get(topic, null)
		if not (cue_variant is Dictionary):
			continue
		var cue = cue_variant as Dictionary
		var salience = clampf(float(cue.get("salience", 0.0)), 0.0, 1.0)
		var gain_loss = clampf(float(cue.get("gain_loss", 0.0)), -1.0, 1.0)
		weights[topic] = float(weights[topic]) + salience * 1.2 + absf(gain_loss) * 0.55

func _select_weighted_topic(topic_weights: Dictionary, rng, household_id: String, branch_id: String, tick: int) -> String:
	var entries: Array = []
	var total = 0.0
	var keys = topic_weights.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	for key_variant in keys:
		var topic = String(key_variant)
		var weight = maxf(0.0001, float(topic_weights.get(topic, 0.0)))
		total += weight
		entries.append({"topic": topic, "edge": total})
	if entries.is_empty() or total <= 0.0:
		return ""
	var needle = rng.randomf("oral_topic_weighted", household_id, branch_id, tick) * total
	for row_variant in entries:
		var row = row_variant as Dictionary
		if needle <= float(row.get("edge", 0.0)):
			return String(row.get("topic", ""))
	return String((entries[entries.size() - 1] as Dictionary).get("topic", ""))

func _topic_salience(topic: String, household_id: String, drivers: Array) -> float:
	var best = 0.0
	for driver_variant in drivers:
		if not (driver_variant is Dictionary):
			continue
		var row = driver_variant as Dictionary
		var scope = String(row.get("scope", "settlement"))
		var owner_id = String(row.get("owner_id", ""))
		if scope == "household" and owner_id != "" and owner_id != household_id:
			continue
		var salience = clampf(float(row.get("salience", 0.0)), 0.0, 1.0)
		if String(row.get("topic", "")) == topic:
			best = maxf(best, salience)
			continue
		var tags: Array = row.get("tags", [])
		for tag_variant in tags:
			var tag = String(tag_variant)
			if _tag_matches_topic(tag, topic):
				best = maxf(best, salience * 0.92)
	return best

func _tag_matches_topic(tag: String, topic: String) -> bool:
	match topic:
		"water_route_reliability":
			return tag == "water"
		"safe_foraging_zones":
			return tag == "food"
		"seasonal_weather_cues":
			return tag == "weather"
		"toolcraft_recipe":
			return tag == "craft"
		"ritual_obligation":
			return tag == "ritual"
		"belonging_oath":
			return tag == "belonging"
		"kinship_continuity":
			return tag == "kinship"
		"ownership_boundary":
			return tag == "ownership"
		"bone_craft_memory":
			return tag == "bone"
		_:
			return false

func _ritual_driver_intensity(drivers: Array) -> float:
	if drivers.is_empty():
		return 0.0
	var total = 0.0
	var count = 0
	for row_variant in drivers:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var salience = clampf(float(row.get("salience", 0.0)), 0.0, 1.0)
		var gain_loss = absf(clampf(float(row.get("gain_loss", 0.0)), -1.0, 1.0))
		total += salience * 0.7 + gain_loss * 0.3
		count += 1
	if count <= 0:
		return 0.0
	return clampf(total / float(count), 0.0, 1.0)

func _ritual_gain_loss(drivers: Array) -> float:
	if drivers.is_empty():
		return 0.0
	var total = 0.0
	var weight_total = 0.0
	for row_variant in drivers:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var salience = clampf(float(row.get("salience", 0.0)), 0.0, 1.0)
		var gain_loss = clampf(float(row.get("gain_loss", 0.0)), -1.0, 1.0)
		var weight = maxf(0.05, salience)
		total += gain_loss * weight
		weight_total += weight
	if weight_total <= 0.0:
		return 0.0
	return clampf(total / weight_total, -1.0, 1.0)

func _dominant_driver_label(drivers: Array) -> String:
	var winner = ""
	var best = -1.0
	for row_variant in drivers:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var salience = clampf(float(row.get("salience", 0.0)), 0.0, 1.0)
		var gain_loss = absf(clampf(float(row.get("gain_loss", 0.0)), -1.0, 1.0))
		var score = salience * 0.72 + gain_loss * 0.28
		if score > best:
			best = score
			winner = String(row.get("label", "shared_duty"))
	return winner if winner != "" else "shared_duty"

func _topic_gain_loss(topic: String, household_id: String, drivers: Array) -> float:
	var total = 0.0
	var weight_total = 0.0
	for driver_variant in drivers:
		if not (driver_variant is Dictionary):
			continue
		var row = driver_variant as Dictionary
		var scope = String(row.get("scope", "settlement"))
		var owner_id = String(row.get("owner_id", ""))
		if scope == "household" and owner_id != "" and owner_id != household_id:
			continue
		var salience = clampf(float(row.get("salience", 0.0)), 0.0, 1.0)
		var gain_loss = clampf(float(row.get("gain_loss", 0.0)), -1.0, 1.0)
		var is_match = String(row.get("topic", "")) == topic
		if not is_match:
			var tags: Array = row.get("tags", [])
			for tag_variant in tags:
				if _tag_matches_topic(String(tag_variant), topic):
					is_match = true
					break
		if not is_match:
			continue
		var weight = maxf(0.05, salience)
		total += gain_loss * weight
		weight_total += weight
	if weight_total <= 0.0:
		return 0.0
	return clampf(total / weight_total, -1.0, 1.0)

func _driver_digest(drivers: Array) -> Dictionary:
	var dominant = _dominant_driver_label(drivers)
	var intensity = _ritual_driver_intensity(drivers)
	return {
		"dominant": dominant,
		"intensity": intensity,
		"count": drivers.size(),
	}

func _synthesize_cultural_drivers(tick: int, world_id: String, branch_id: String, context_snapshot: Dictionary, context_cues: Dictionary, deterministic_seed: int) -> Array:
	var synthesized: Dictionary = {}
	if llm_enabled:
		var prompt = _build_driver_prompt(world_id, branch_id, tick, context_snapshot)
		var runtime_result = _generate_driver_payload(prompt, deterministic_seed)
		if bool(runtime_result.get("ok", false)):
			synthesized = runtime_result
	var rows: Array = synthesized.get("drivers", [])
	if rows.is_empty():
		rows = _heuristic_driver_payload(context_snapshot)
	rows = _merge_with_context_cue_drivers(rows, context_cues)
	return _sanitize_drivers(rows)

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
	var compact = _compact_context_for_prompt(context_snapshot)
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

func _generate_driver_payload(prompt: String, deterministic_seed: int) -> Dictionary:
	if not Engine.has_singleton("AgentRuntime"):
		return {"ok": false, "error": "runtime_missing"}
	var runtime = Engine.get_singleton("AgentRuntime")
	if runtime == null or not runtime.has_method("generate"):
		return {"ok": false, "error": "runtime_generate_unavailable"}
	if runtime.has_method("is_model_loaded") and not runtime.call("is_model_loaded"):
		return {"ok": false, "error": "model_not_loaded"}

	var request = {
		"prompt": prompt,
		"history": [],
		"options": {
			"temperature": 0.35,
			"max_tokens": 420,
			"seed": deterministic_seed,
			"reset_context": true,
			"cache_prompt": false,
		},
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
	return parsed as Dictionary

func _parse_json_anywhere(text: String):
	var parsed = JSON.parse_string(text)
	if parsed != null:
		return parsed
	var first = text.find("{")
	var last = text.rfind("}")
	if first == -1 or last <= first:
		return null
	var fragment = text.substr(first, last - first + 1)
	return JSON.parse_string(fragment)

func _compact_context_for_prompt(context_snapshot: Dictionary) -> Dictionary:
	var households: Array = context_snapshot.get("households", [])
	var compact_households: Array = []
	for row_variant in households:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		compact_households.append({
			"household_id": String(row.get("household_id", "")),
			"member_count": int(row.get("member_count", 0)),
			"belonging_index": snappedf(float(row.get("belonging_index", 0.0)), 0.01),
			"active_structures": int(row.get("active_structures", 0)),
			"food": snappedf(float(row.get("food", 0.0)), 0.01),
			"water": snappedf(float(row.get("water", 0.0)), 0.01),
			"currency": snappedf(float(row.get("currency", 0.0)), 0.01),
			"biome": String(row.get("biome", "plains")),
			"temperature": snappedf(float(row.get("temperature", 0.5)), 0.01),
			"water_reliability": snappedf(float(row.get("water_reliability", 0.5)), 0.01),
		})
	if compact_households.size() > 8:
		compact_households.resize(8)

	var recent_events: Array = context_snapshot.get("recent_events", [])
	var compact_events: Array = []
	for row_variant in recent_events:
		if compact_events.size() >= 20:
			break
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		compact_events.append({
			"event_type": String(row.get("event_type", "")),
			"scope": String(row.get("scope", "")),
			"owner_id": String(row.get("owner_id", "")),
			"kind": String(row.get("kind", "")),
			"magnitude": snappedf(float(row.get("magnitude", 0.0)), 0.01),
		})
	var living_entities: Array = context_snapshot.get("living_entities", [])
	var compact_entities: Array = []
	for row_variant in living_entities:
		if compact_entities.size() >= 24:
			break
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		compact_entities.append({
			"entity_id": String(row.get("entity_id", "")),
			"display_kind": String(row.get("display_kind", "")),
			"taxonomy_path": row.get("taxonomy_path", []),
			"ownership_weight": snappedf(float(row.get("ownership_weight", 0.0)), 0.01),
			"belonging_weight": snappedf(float(row.get("belonging_weight", 0.0)), 0.01),
			"gather_tendency": snappedf(float(row.get("gather_tendency", 0.0)), 0.01),
			"mobility": snappedf(float(row.get("mobility", 0.0)), 0.01),
			"tags": row.get("tags", []),
		})

	return {
		"community": context_snapshot.get("community", {}),
		"households": compact_households,
		"living_entities": compact_entities,
		"recent_events": compact_events,
	}

func _heuristic_driver_payload(context_snapshot: Dictionary) -> Array:
	var drivers: Array = []
	var households: Array = context_snapshot.get("households", [])
	var global_water_stress = 0.0
	var global_food_stress = 0.0
	var belonging_pressure = 0.0
	var ownership_pressure = 0.0
	var bone_signal = 0.0
	var animal_collect_pressure = 0.0
	var plant_food_pressure = 0.0
	var living_ownership_pressure = 0.0
	for row_variant in households:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var household_id = String(row.get("household_id", ""))
		var water_reliability = clampf(float(row.get("water_reliability", 0.5)), 0.0, 1.0)
		var food = maxf(0.0, float(row.get("food", 0.0)))
		var belonging = clampf(float(row.get("belonging_index", 0.0)) / 3.0, 0.0, 1.0)
		var structures = maxi(0, int(row.get("active_structures", 0)))
		var bone_density = clampf(float(row.get("bone_signal", 0.0)), 0.0, 1.0)
		global_water_stress += (1.0 - water_reliability)
		global_food_stress += clampf((2.4 - food) / 2.4, 0.0, 1.0)
		belonging_pressure += belonging
		ownership_pressure += clampf(float(structures) * 0.25 + belonging * 0.25, 0.0, 1.0)
		bone_signal += bone_density
		if household_id != "":
			drivers.append({
				"label": "household_continuity",
				"topic": "kinship_continuity",
				"gain_loss": belonging * 2.0 - 1.0,
				"salience": clampf(0.3 + absf((belonging * 2.0 - 1.0)) * 0.6, 0.0, 1.0),
				"scope": "household",
				"owner_id": household_id,
				"tags": ["belonging", "kinship"],
				"summary": "Household continuity signal",
			})
	if households.size() > 0:
		var inv_count = float(households.size())
		global_water_stress /= inv_count
		global_food_stress /= inv_count
		belonging_pressure /= inv_count
		ownership_pressure /= inv_count
		bone_signal /= inv_count
	var living_entities: Array = context_snapshot.get("living_entities", [])
	var entity_count = 0
	for entity_variant in living_entities:
		if not (entity_variant is Dictionary):
			continue
		var row = entity_variant as Dictionary
		var gather_tendency = clampf(float(row.get("gather_tendency", 0.0)), 0.0, 1.0)
		var ownership_weight = clampf(float(row.get("ownership_weight", 0.0)), 0.0, 1.0)
		var taxonomy: Array = row.get("taxonomy_path", [])
		var taxonomy_key = ""
		if not taxonomy.is_empty():
			var parts: Array = []
			for token_variant in taxonomy:
				parts.append(String(token_variant))
			taxonomy_key = "/".join(PackedStringArray(parts))
		entity_count += 1
		living_ownership_pressure += ownership_weight
		if taxonomy_key.contains("/animal/") and gather_tendency > 0.0:
			animal_collect_pressure += gather_tendency
		if taxonomy_key.contains("/plant/"):
			plant_food_pressure += clampf(float(row.get("belonging_weight", 0.0)), 0.0, 1.0)
	if entity_count > 0:
		animal_collect_pressure /= float(entity_count)
		plant_food_pressure /= float(entity_count)
		living_ownership_pressure /= float(entity_count)
	drivers.append({
		"label": "water_security",
		"topic": "water_route_reliability",
		"gain_loss": 1.0 - global_water_stress * 2.0,
		"salience": clampf(0.35 + global_water_stress * 0.65, 0.0, 1.0),
		"scope": "settlement",
		"owner_id": "",
		"tags": ["water", "ownership"],
		"summary": "Shared water access pressure",
	})
	drivers.append({
		"label": "food_security",
		"topic": "safe_foraging_zones",
		"gain_loss": 1.0 - global_food_stress * 2.0,
		"salience": clampf(0.34 + global_food_stress * 0.66, 0.0, 1.0),
		"scope": "settlement",
		"owner_id": "",
		"tags": ["food", "bone"],
		"summary": "Shared diet pressure",
	})
	drivers.append({
		"label": "belonging_order",
		"topic": "belonging_oath",
		"gain_loss": clampf(belonging_pressure * 2.0 - 1.0 + (living_ownership_pressure - 0.5) * 0.2, -1.0, 1.0),
		"salience": clampf(0.28 + absf(belonging_pressure * 2.0 - 1.0) * 0.62 + living_ownership_pressure * 0.2, 0.0, 1.0),
		"scope": "settlement",
		"owner_id": "",
		"tags": ["belonging", "ownership", "ritual"],
		"summary": "Belonging and ownership norm pressure",
	})
	if animal_collect_pressure > 0.05:
		drivers.append({
			"label": "collecting_patterns",
			"topic": "ownership_boundary",
			"gain_loss": clampf(animal_collect_pressure * 1.4 - 0.5, -1.0, 1.0),
			"salience": clampf(0.2 + animal_collect_pressure * 0.7, 0.0, 1.0),
			"scope": "settlement",
			"owner_id": "",
			"tags": ["ownership", "food"],
			"summary": "Collecting pressure from non-human foragers",
		})
	if plant_food_pressure > 0.05:
		drivers.append({
			"label": "plant_food_dependence",
			"topic": "safe_foraging_zones",
			"gain_loss": clampf(plant_food_pressure * 1.6 - 0.55, -1.0, 1.0),
			"salience": clampf(0.25 + plant_food_pressure * 0.6, 0.0, 1.0),
			"scope": "settlement",
			"owner_id": "",
			"tags": ["food", "belonging"],
			"summary": "Dependence on nearby edible plants",
		})
	if bone_signal > 0.08:
		drivers.append({
			"label": "bone_memory_craft",
			"topic": "bone_craft_memory",
			"gain_loss": clampf(bone_signal * 1.5, -1.0, 1.0),
			"salience": clampf(0.22 + bone_signal * 0.74, 0.0, 1.0),
			"scope": "settlement",
			"owner_id": "",
			"tags": ["bone", "craft", "food"],
			"summary": "Bone-derived continuity memory",
		})
	return drivers

func _sanitize_drivers(rows: Array) -> Array:
	var out: Array = []
	for row_variant in rows:
		if out.size() >= 12:
			break
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var topic = String(row.get("topic", "")).strip_edges()
		if topic == "":
			continue
		var scope = String(row.get("scope", "settlement")).strip_edges()
		if scope != "household":
			scope = "settlement"
		var gain_loss = clampf(float(row.get("gain_loss", 0.0)), -1.0, 1.0)
		var salience = clampf(float(row.get("salience", 0.0)), 0.0, 1.0)
		var tags: Array = row.get("tags", [])
		var clean_tags: Array = []
		for tag_variant in tags:
			var tag = String(tag_variant).strip_edges()
			if tag == "":
				continue
			if not clean_tags.has(tag):
				clean_tags.append(tag)
		out.append({
			"label": String(row.get("label", "cultural_shift")).strip_edges(),
			"topic": topic,
			"gain_loss": gain_loss,
			"salience": salience,
			"scope": scope,
			"owner_id": String(row.get("owner_id", "")).strip_edges(),
			"tags": clean_tags,
			"summary": String(row.get("summary", "")).strip_edges(),
		})
	if out.is_empty():
		out.append({
			"label": "continuity_pressure",
			"topic": "kinship_continuity",
			"gain_loss": 0.0,
			"salience": 0.35,
			"scope": "settlement",
			"owner_id": "",
			"tags": ["belonging", "ritual"],
			"summary": "Baseline continuity signal",
		})
	return out
