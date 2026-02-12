extends RefCounted
class_name LocalAgentsVillagerMindService

var llm_enabled: bool = true

func generate_internal_thought(npc_id: String, villager_state: Dictionary, recall_context: Dictionary, deterministic_seed: int, narrator_hint: String = "") -> Dictionary:
    if npc_id.strip_edges() == "":
        return {"ok": false, "error": "invalid_npc_id"}
    var thought_prompt = _build_thought_prompt(npc_id, villager_state, recall_context, narrator_hint)
    if not llm_enabled:
        return {"ok": false, "error": "llm_disabled"}
    return _generate_with_runtime(thought_prompt, deterministic_seed)

func generate_dialogue_exchange(source_npc_id: String, target_npc_id: String, source_state: Dictionary, target_state: Dictionary, source_recall: Dictionary, target_recall: Dictionary, deterministic_seed: int, narrator_hint: String = "") -> Dictionary:
    if source_npc_id.strip_edges() == "" or target_npc_id.strip_edges() == "":
        return {"ok": false, "error": "invalid_npc_id"}
    var dialogue_prompt = _build_dialogue_prompt(source_npc_id, target_npc_id, source_state, target_state, source_recall, target_recall, narrator_hint)
    if not llm_enabled:
        return {"ok": false, "error": "llm_disabled"}
    return _generate_with_runtime(dialogue_prompt, deterministic_seed)

func select_recall_context(backstory_service: Object, npc_id: String, world_day: int, waking_limit: int = 5, dream_limit: int = 2) -> Dictionary:
    var waking: Array = []
    var dreams: Array = []
    if backstory_service == null:
        return {"waking": waking, "dreams": dreams}
    if not backstory_service.has_method("get_memory_recall_candidates"):
        return {"waking": waking, "dreams": dreams}
    var result: Dictionary = backstory_service.call("get_memory_recall_candidates", npc_id, world_day, waking_limit + dream_limit, true)
    if not bool(result.get("ok", false)):
        return {"waking": waking, "dreams": dreams}
    var rows: Array = result.get("candidates", [])
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

func _generate_with_runtime(prompt: String, deterministic_seed: int) -> Dictionary:
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
            "temperature": 0.55,
            "max_tokens": 120,
            "seed": deterministic_seed,
            "reset_context": true,
            "cache_prompt": false,
        },
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
        }

    var retry_request = {
        "prompt": "%s\nRespond with at least one short sentence." % prompt,
        "history": [],
        "options": {
            "temperature": 0.25,
            "max_tokens": 120,
            "seed": deterministic_seed + 1,
            "reset_context": true,
            "cache_prompt": false,
        },
    }
    var retry_result: Dictionary = runtime.call("generate", retry_request)
    if not bool(retry_result.get("ok", false)):
        return retry_result
    var retry_text := String(retry_result.get("text", "")).strip_edges()
    if retry_text == "":
        return {"ok": false, "error": "empty_generation"}
    return {
        "ok": true,
        "text": retry_text,
        "seed": deterministic_seed + 1,
        "synthetic": false,
    }

func _build_thought_prompt(npc_id: String, villager_state: Dictionary, recall_context: Dictionary, narrator_hint: String) -> String:
    var prompt_state = _compact_state_for_prompt(villager_state)
    var waking = _compact_memories_for_prompt(recall_context.get("waking", []), 4)
    var dreams = _compact_memories_for_prompt(recall_context.get("dreams", []), 2)
    var trimmed_hint = _truncate_text(narrator_hint, 180)
    return """
You are generating INTERNAL THOUGHT for one villager.
Rules:
- First-person internal thought, 1-3 sentences.
- Distinguish dream memories as symbolic or uncertain.
- Do not treat dream memories as confirmed facts.
- Keep thought grounded in waking memories first.
Villager: %s
State: %s
Waking memories: %s
Dream memories: %s
Narrator hint: %s
""" % [
        npc_id,
        JSON.stringify(prompt_state, "", false, true),
        JSON.stringify(waking, "", false, true),
        JSON.stringify(dreams, "", false, true),
        trimmed_hint,
    ]

func _build_dialogue_prompt(source_npc_id: String, target_npc_id: String, source_state: Dictionary, target_state: Dictionary, source_recall: Dictionary, target_recall: Dictionary, narrator_hint: String) -> String:
    var source_prompt_state = _compact_state_for_prompt(source_state)
    var target_prompt_state = _compact_state_for_prompt(target_state)
    var source_waking = _compact_memories_for_prompt(source_recall.get("waking", []), 3)
    var source_dreams = _compact_memories_for_prompt(source_recall.get("dreams", []), 1)
    var target_waking = _compact_memories_for_prompt(target_recall.get("waking", []), 3)
    var target_dreams = _compact_memories_for_prompt(target_recall.get("dreams", []), 1)
    var trimmed_hint = _truncate_text(narrator_hint, 180)
    return """
Generate a short villager dialogue exchange.
Rules:
- 2 lines exactly: first %s then %s.
- Keep grounded in waking memories and current state.
- Dream memories may influence tone but must be framed as uncertain impressions.
- No omniscient narration.
%s state: %s
%s state: %s
%s waking memories: %s
%s dream memories: %s
%s waking memories: %s
%s dream memories: %s
Narrator hint: %s
""" % [
        source_npc_id,
        target_npc_id,
        source_npc_id,
        JSON.stringify(source_prompt_state, "", false, true),
        target_npc_id,
        JSON.stringify(target_prompt_state, "", false, true),
        source_npc_id,
        JSON.stringify(source_waking, "", false, true),
        source_npc_id,
        JSON.stringify(source_dreams, "", false, true),
        target_npc_id,
        JSON.stringify(target_waking, "", false, true),
        target_npc_id,
        JSON.stringify(target_dreams, "", false, true),
        trimmed_hint,
    ]

func _compact_state_for_prompt(state: Dictionary) -> Dictionary:
    var belief_context: Dictionary = state.get("belief_context", {})
    var belief_rows: Array = belief_context.get("beliefs", [])
    var conflict_rows: Array = belief_context.get("conflicts", [])
    return {
        "mood": String(state.get("mood", "neutral")),
        "morale": snappedf(float(state.get("morale", 0.5)), 0.01),
        "fear": snappedf(float(state.get("fear", 0.0)), 0.01),
        "energy": snappedf(float(state.get("energy", 1.0)), 0.01),
        "hunger": snappedf(float(state.get("hunger", 0.0)), 0.01),
        "beliefs": _compact_claim_rows_for_prompt(belief_rows, 3),
        "belief_truth_conflicts": _compact_conflict_rows_for_prompt(conflict_rows, 2),
    }

func _compact_memories_for_prompt(rows: Array, max_items: int) -> Array:
    var out: Array = []
    for item_variant in rows:
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

func _truncate_text(text: String, max_chars: int) -> String:
    var clean = text.strip_edges()
    if clean.length() <= max_chars:
        return clean
    return clean.substr(0, max_chars)

func _compact_claim_rows_for_prompt(rows: Array, max_items: int) -> Array:
    var out: Array = []
    for item_variant in rows:
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
    var out: Array = []
    for item_variant in rows:
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
