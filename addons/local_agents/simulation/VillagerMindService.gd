extends RefCounted
class_name LocalAgentsVillagerMindService

const LlmRequestProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/LlmRequestProfileResource.gd")

var llm_enabled: bool = true
var _thought_profile = LlmRequestProfileResourceScript.new()
var _dialogue_profile = LlmRequestProfileResourceScript.new()
var _section_limits := {
	"max_prompt_chars": 6000,
	"state_chars": 420,
	"waking_memories": 4,
	"dream_memories": 2,
	"beliefs": 3,
	"conflicts": 2,
	"oral_knowledge": 3,
	"ritual_events": 2,
	"taboo_ids": 6,
}

func _init() -> void:
	_thought_profile.profile_id = "internal_thought"
	_thought_profile.temperature = 0.55
	_thought_profile.top_p = 0.9
	_thought_profile.max_tokens = 120
	_thought_profile.stop = PackedStringArray(["\nVillager:", "\nNarrator hint:"])
	_thought_profile.reset_context = true
	_thought_profile.cache_prompt = false
	_thought_profile.retry_count = 1
	_thought_profile.retry_seed_step = 1

	_dialogue_profile.profile_id = "dialogue_exchange"
	_dialogue_profile.temperature = 0.5
	_dialogue_profile.top_p = 0.92
	_dialogue_profile.max_tokens = 140
	_dialogue_profile.stop = PackedStringArray(["\nNarrator hint:"])
	_dialogue_profile.reset_context = true
	_dialogue_profile.cache_prompt = false
	_dialogue_profile.retry_count = 1
	_dialogue_profile.retry_seed_step = 1

func set_request_profile(task: String, profile_resource: Resource) -> void:
	if profile_resource == null:
		return
	if not profile_resource.has_method("to_dict"):
		return
	var payload: Dictionary = profile_resource.call("to_dict")
	if task == "dialogue_exchange":
		_dialogue_profile.from_dict(payload)
		return
	_thought_profile.from_dict(payload)

func set_contract_limits(limits: Dictionary) -> void:
	for key_variant in limits.keys():
		var key = String(key_variant)
		if not _section_limits.has(key):
			continue
		if key == "max_prompt_chars":
			_section_limits[key] = maxi(600, int(limits.get(key, _section_limits[key])))
		else:
			_section_limits[key] = maxi(0, int(limits.get(key, _section_limits[key])))

func request_profile_id(task: String) -> String:
	return String(_profile_for_task(task).profile_id)

func generate_internal_thought(npc_id: String, villager_state: Dictionary, recall_context: Dictionary, deterministic_seed: int, narrator_hint: String = "") -> Dictionary:
	if npc_id.strip_edges() == "":
		return {"ok": false, "error": "invalid_npc_id"}
	var thought_prompt = _build_thought_prompt(npc_id, villager_state, recall_context, narrator_hint)
	if thought_prompt.length() > int(_section_limits.get("max_prompt_chars", 6000)):
		return {"ok": false, "error": "context_oversize"}
	if not llm_enabled:
		return {"ok": false, "error": "llm_disabled"}
	var trace = {
		"query_keys": [
			"villager_state_snapshot",
			"memory_recall_candidates_waking",
			"memory_recall_candidates_dream",
			"beliefs_for_npc",
			"belief_truth_conflicts",
			"role_household_economic_context",
			"oral_knowledge_context",
		],
		"referenced_ids": [npc_id],
	}
	return _generate_with_runtime(thought_prompt, deterministic_seed, "internal_thought", trace)

func generate_dialogue_exchange(source_npc_id: String, target_npc_id: String, source_state: Dictionary, target_state: Dictionary, source_recall: Dictionary, target_recall: Dictionary, deterministic_seed: int, narrator_hint: String = "") -> Dictionary:
	if source_npc_id.strip_edges() == "" or target_npc_id.strip_edges() == "":
		return {"ok": false, "error": "invalid_npc_id"}
	var dialogue_prompt = _build_dialogue_prompt(source_npc_id, target_npc_id, source_state, target_state, source_recall, target_recall, narrator_hint)
	if dialogue_prompt.length() > int(_section_limits.get("max_prompt_chars", 6000)):
		return {"ok": false, "error": "context_oversize"}
	if not llm_enabled:
		return {"ok": false, "error": "llm_disabled"}
	var trace = {
		"query_keys": [
			"villager_state_snapshot",
			"memory_recall_candidates_waking",
			"memory_recall_candidates_dream",
			"beliefs_for_npc",
			"belief_truth_conflicts",
			"role_household_economic_context",
			"oral_knowledge_context",
		],
		"referenced_ids": [source_npc_id, target_npc_id],
	}
	return _generate_with_runtime(dialogue_prompt, deterministic_seed, "dialogue_exchange", trace)

func select_recall_context(backstory_service: Object, npc_id: String, world_day: int, waking_limit: int = 5, dream_limit: int = 2) -> Dictionary:
	var waking: Array = []
	var dreams: Array = []
	if backstory_service == null:
		return {"waking": waking, "dreams": dreams}
	if not backstory_service.has_method("get_memory_recall_candidates"):
		return {"waking": waking, "dreams": dreams}
	var result: Dictionary = backstory_service.call("get_memory_recall_candidates", npc_id, world_day, waking_limit + dream_limit + 6, true)
	if not bool(result.get("ok", false)):
		return {"waking": waking, "dreams": dreams}
	var rows: Array = _sorted_memory_candidates(result.get("candidates", []))
	for item_variant in rows:
		if not (item_variant is Dictionary):
			continue
		var item: Dictionary = item_variant
		if bool(item.get("is_dream", false)):
			if dreams.size() < dream_limit:
				dreams.append(item.duplicate(true))
			continue
		if waking.size() < waking_limit:
			waking.append(item.duplicate(true))
	return {"waking": waking, "dreams": dreams}

func _generate_with_runtime(prompt: String, deterministic_seed: int, task: String, trace_payload: Dictionary = {}) -> Dictionary:
	if not Engine.has_singleton("AgentRuntime"):
		return {"ok": false, "error": "runtime_missing"}
	var runtime = Engine.get_singleton("AgentRuntime")
	if runtime == null or not runtime.has_method("generate"):
		return {"ok": false, "error": "runtime_generate_unavailable"}
	if runtime.has_method("is_model_loaded") and not runtime.call("is_model_loaded"):
		return {"ok": false, "error": "model_not_loaded"}

	var profile = _profile_for_task(task)
	var used_seed = deterministic_seed
	var text := ""
	var max_attempts = 1 + maxi(0, int(profile.retry_count))
	for attempt in range(max_attempts):
		used_seed = deterministic_seed + attempt * maxi(1, int(profile.retry_seed_step))
		var request = {
			"prompt": prompt,
			"history": [],
			"options": profile.to_runtime_options(used_seed),
		}
		var result: Dictionary = runtime.call("generate", request)
		if not bool(result.get("ok", false)):
			return result
		text = String(result.get("text", "")).strip_edges()
		if text != "":
			break
	if text == "":
		return {"ok": false, "error": "empty_generation"}

	var trace := trace_payload.duplicate(true)
	trace["profile_id"] = String(profile.profile_id)
	trace["seed"] = used_seed
	trace["sampler_params"] = profile.to_runtime_options(used_seed)
	return {
		"ok": true,
		"text": text,
		"seed": used_seed,
		"synthetic": false,
		"trace": trace,
	}

func _build_thought_prompt(npc_id: String, villager_state: Dictionary, recall_context: Dictionary, narrator_hint: String) -> String:
	var context = _assemble_prompt_context(villager_state, recall_context)
	var trimmed_hint = _truncate_text(narrator_hint, 180)
	return """
You are generating INTERNAL THOUGHT for one villager.
Rules:
- First-person internal thought, 1-3 sentences.
- Distinguish dream memories as symbolic or uncertain.
- Do not treat dream memories as confirmed facts.
- Keep thought grounded in waking memories first.
Villager: %s
Context contract: %s
Narrator hint: %s
""" % [
		npc_id,
		JSON.stringify(context, "", false, true),
		trimmed_hint,
	]

func _build_dialogue_prompt(source_npc_id: String, target_npc_id: String, source_state: Dictionary, target_state: Dictionary, source_recall: Dictionary, target_recall: Dictionary, narrator_hint: String) -> String:
	var source_ctx = _assemble_prompt_context(source_state, source_recall)
	var target_ctx = _assemble_prompt_context(target_state, target_recall)
	var trimmed_hint = _truncate_text(narrator_hint, 180)
	return """
Generate a short villager dialogue exchange.
Rules:
- 2 lines exactly: first %s then %s.
- Keep grounded in waking memories and current state.
- Dream memories may influence tone but must be framed as uncertain impressions.
- No omniscient narration.
%s context: %s
%s context: %s
Narrator hint: %s
""" % [
		source_npc_id,
		target_npc_id,
		source_npc_id,
		JSON.stringify(source_ctx, "", false, true),
		target_npc_id,
		JSON.stringify(target_ctx, "", false, true),
		trimmed_hint,
	]

func _assemble_prompt_context(state: Dictionary, recall_context: Dictionary) -> Dictionary:
	var belief_context: Dictionary = state.get("belief_context", {})
	var culture_context: Dictionary = state.get("culture_context", {})
	var section_order = [
		"villager_state",
		"waking_memories",
		"dream_memories",
		"beliefs",
		"belief_truth_conflicts",
		"role_household_economic_context",
		"oral_knowledge_ritual_taboo_context",
	]
	return {
		"schema_version": 1,
		"section_order": section_order,
		"villager_state": _compact_state_basics(state),
		"waking_memories": _compact_memories_for_prompt(recall_context.get("waking", []), int(_section_limits.get("waking_memories", 4))),
		"dream_memories": _compact_memories_for_prompt(recall_context.get("dreams", []), int(_section_limits.get("dream_memories", 2))),
		"beliefs": _compact_claim_rows_for_prompt(belief_context.get("beliefs", []), int(_section_limits.get("beliefs", 3))),
		"belief_truth_conflicts": _compact_conflict_rows_for_prompt(belief_context.get("conflicts", []), int(_section_limits.get("conflicts", 2))),
		"role_household_economic_context": _compact_role_context(state),
		"oral_knowledge_ritual_taboo_context": _compact_culture_context(culture_context),
	}

func _compact_state_basics(state: Dictionary) -> Dictionary:
	var compact = {
		"mood": String(state.get("mood", "neutral")),
		"morale": snappedf(float(state.get("morale", 0.5)), 0.01),
		"fear": snappedf(float(state.get("fear", 0.0)), 0.01),
		"energy": snappedf(float(state.get("energy", 1.0)), 0.01),
		"hunger": snappedf(float(state.get("hunger", 0.0)), 0.01),
	}
	var serialized = JSON.stringify(compact, "", false, true)
	if serialized.length() <= int(_section_limits.get("state_chars", 420)):
		return compact
	compact.erase("hunger")
	return compact

func _compact_role_context(state: Dictionary) -> Dictionary:
	return {
		"role": String(state.get("role", "")),
		"household_id": String(state.get("household_id", "")),
		"inventory": {
			"food": snappedf(float(state.get("food", 0.0)), 0.01),
			"water": snappedf(float(state.get("water", 0.0)), 0.01),
			"tools": snappedf(float(state.get("tools", 0.0)), 0.01),
			"currency": snappedf(float(state.get("currency", 0.0)), 0.01),
		},
	}

func _compact_culture_context(culture_context: Dictionary) -> Dictionary:
	var oral = _compact_oral_rows(culture_context.get("oral_knowledge", []), int(_section_limits.get("oral_knowledge", 3)))
	var rituals = _compact_ritual_rows(culture_context.get("ritual_events", []), int(_section_limits.get("ritual_events", 2)))
	var taboo_ids: Array = culture_context.get("taboo_ids", [])
	var clean_taboos: Array = []
	for taboo_variant in taboo_ids:
		if clean_taboos.size() >= int(_section_limits.get("taboo_ids", 6)):
			break
		var taboo = String(taboo_variant).strip_edges()
		if taboo == "":
			continue
		clean_taboos.append(taboo)
	return {
		"oral_knowledge": oral,
		"ritual_events": rituals,
		"taboo_ids": clean_taboos,
	}

func _compact_oral_rows(rows: Array, max_items: int) -> Array:
	var sorted = rows.duplicate(true)
	sorted.sort_custom(func(a, b):
		var da = a as Dictionary
		var db = b as Dictionary
		var ca = float(da.get("confidence", 0.0))
		var cb = float(db.get("confidence", 0.0))
		if !is_equal_approx(ca, cb):
			return ca > cb
		var wa = int(da.get("world_day", -1))
		var wb = int(db.get("world_day", -1))
		if wa != wb:
			return wa > wb
		return String(da.get("knowledge_id", "")) < String(db.get("knowledge_id", ""))
	)
	var out: Array = []
	for row_variant in sorted:
		if out.size() >= max_items:
			break
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		out.append({
			"knowledge_id": String(row.get("knowledge_id", "")),
			"category": String(row.get("category", "")),
			"confidence": snappedf(float(row.get("confidence", 0.0)), 0.01),
		})
	return out

func _compact_ritual_rows(rows: Array, max_items: int) -> Array:
	var sorted = rows.duplicate(true)
	sorted.sort_custom(func(a, b):
		var da = a as Dictionary
		var db = b as Dictionary
		var wa = int(da.get("world_day", -1))
		var wb = int(db.get("world_day", -1))
		if wa != wb:
			return wa > wb
		return String(da.get("ritual_id", "")) < String(db.get("ritual_id", ""))
	)
	var out: Array = []
	for row_variant in sorted:
		if out.size() >= max_items:
			break
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		out.append({
			"ritual_id": String(row.get("ritual_id", "")),
			"site_id": String(row.get("site_id", "")),
			"world_day": int(row.get("world_day", -1)),
		})
	return out

func _truncate_text(text: String, max_chars: int) -> String:
	var clean = text.strip_edges()
	if clean.length() <= max_chars:
		return clean
	return clean.substr(0, max_chars)

func _compact_memories_for_prompt(rows: Array, max_items: int) -> Array:
	var sorted = _sorted_memory_candidates(rows)
	var out: Array = []
	for item_variant in sorted:
		if out.size() >= max_items:
			break
		if not (item_variant is Dictionary):
			continue
		var item: Dictionary = item_variant
		out.append({
			"memory_id": String(item.get("memory_id", "")),
			"kind": String(item.get("memory_kind", "memory")),
			"world_day": int(item.get("world_day", -1)),
			"summary": _truncate_text(String(item.get("summary", "")), 140),
		})
	return out

func _sorted_memory_candidates(rows: Array) -> Array:
	var out = rows.duplicate(true)
	out.sort_custom(func(a, b):
		var da = a as Dictionary
		var db = b as Dictionary
		var ia = float(da.get("importance", 0.0))
		var ib = float(db.get("importance", 0.0))
		if !is_equal_approx(ia, ib):
			return ia > ib
		var wa = int(da.get("world_day", -1))
		var wb = int(db.get("world_day", -1))
		if wa != wb:
			return wa > wb
		return String(da.get("memory_id", "")) < String(db.get("memory_id", ""))
	)
	return out

func _compact_claim_rows_for_prompt(rows: Array, max_items: int) -> Array:
	var sorted = rows.duplicate(true)
	sorted.sort_custom(func(a, b):
		var da = a as Dictionary
		var db = b as Dictionary
		var ca = float(da.get("confidence", 0.0))
		var cb = float(db.get("confidence", 0.0))
		if !is_equal_approx(ca, cb):
			return ca > cb
		var wa = int(da.get("world_day", -1))
		var wb = int(db.get("world_day", -1))
		if wa != wb:
			return wa > wb
		return String(da.get("claim_key", "")) < String(db.get("claim_key", ""))
	)
	var out: Array = []
	for item_variant in sorted:
		if out.size() >= max_items:
			break
		if not (item_variant is Dictionary):
			continue
		var item: Dictionary = item_variant
		out.append({
			"claim_key": String(item.get("claim_key", "")),
			"subject_id": String(item.get("subject_id", "")),
			"predicate": String(item.get("predicate", "")),
			"object": _truncate_text(String(item.get("object_value", "")), 80),
			"confidence": snappedf(float(item.get("confidence", 0.0)), 0.01),
		})
	return out

func _compact_conflict_rows_for_prompt(rows: Array, max_items: int) -> Array:
	var sorted = rows.duplicate(true)
	sorted.sort_custom(func(a, b):
		var da = a as Dictionary
		var db = b as Dictionary
		var ba = da.get("belief", {}) as Dictionary
		var bb = db.get("belief", {}) as Dictionary
		var ca = float(ba.get("confidence", 0.0))
		var cb = float(bb.get("confidence", 0.0))
		if !is_equal_approx(ca, cb):
			return ca > cb
		return String(da.get("claim_key", "")) < String(db.get("claim_key", ""))
	)
	var out: Array = []
	for item_variant in sorted:
		if out.size() >= max_items:
			break
		if not (item_variant is Dictionary):
			continue
		var item: Dictionary = item_variant
		var belief: Dictionary = item.get("belief", {})
		var truth: Dictionary = item.get("truth", {})
		out.append({
			"claim_key": String(item.get("claim_key", "")),
			"believed": _truncate_text(String(belief.get("object_value", "")), 80),
			"true": _truncate_text(String(truth.get("object_value", "")), 80),
		})
	return out

func _profile_for_task(task: String):
	if task == "dialogue_exchange":
		return _dialogue_profile
	return _thought_profile
