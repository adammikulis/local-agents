@tool
extends RefCounted
class_name LocalAgentsBackstoryMemoryStateOps

static func record_event(svc, event_id: String, event_type: String, summary: String, world_day: int, place_id: String, participant_npc_ids: Array, metadata: Dictionary) -> Dictionary:
    if event_id.strip_edges() == "":
        return svc._error("invalid_event_id", "event_id must be non-empty")
    if event_type.strip_edges() == "":
        return svc._error("invalid_event_type", "event_type must be non-empty")
    if world_day < 0:
        return svc._error("invalid_world_day", "world_day must be >= 0")
    if not svc._ensure_graph():
        return svc._error("graph_unavailable", "NetworkGraph extension unavailable")

    var event_node_id = svc._graph.upsert_node(svc.EVENT_SPACE, svc._event_label(event_id), {
        "type": "event",
        "event_id": event_id,
        "event_type": event_type,
        "summary": summary,
        "world_day": world_day,
        "place_id": place_id,
        "participants": participant_npc_ids.duplicate(true),
        "metadata": metadata.duplicate(true),
        "updated_at": svc._timestamp(),
    })
    if event_node_id == -1:
        return svc._error("upsert_failed", "Failed to upsert event", {"event_id": event_id})

    if place_id.strip_edges() != "":
        var place_node_id = svc._node_id_by_external_id(svc.PLACE_SPACE, "id", place_id)
        if place_node_id != -1:
            svc._graph.add_edge(event_node_id, place_node_id, "OCCURRED_AT", 1.0, {
                "type": "event_place",
                "event_id": event_id,
                "place_id": place_id,
            })

    for participant in participant_npc_ids:
        var npc_id = String(participant)
        var npc_node_id = svc._node_id_by_external_id(svc.NPC_SPACE, "npc_id", npc_id)
        if npc_node_id == -1:
            continue
        svc._graph.add_edge(npc_node_id, event_node_id, "PARTICIPATED_IN", 1.0, {
            "type": "participation",
            "npc_id": npc_id,
            "event_id": event_id,
            "world_day": world_day,
        })
    return svc._ok({"node_id": event_node_id})

static func add_memory(svc, memory_id: String, npc_id: String, summary: String, conversation_id: int, message_id: int, world_day: int, importance: float, confidence: float, tags: Array, metadata: Dictionary) -> Dictionary:
    if memory_id.strip_edges() == "":
        return svc._error("invalid_memory_id", "memory_id must be non-empty")
    if npc_id.strip_edges() == "":
        return svc._error("invalid_npc_id", "npc_id must be non-empty")
    if importance < 0.0 or importance > 1.0:
        return svc._error("invalid_importance", "importance must be between 0 and 1")
    if confidence < 0.0 or confidence > 1.0:
        return svc._error("invalid_confidence", "confidence must be between 0 and 1")
    if world_day < -1:
        return svc._error("invalid_world_day", "world_day must be >= -1")
    var npc_node_id = svc._node_id_by_external_id(svc.NPC_SPACE, "npc_id", npc_id)
    if npc_node_id == -1:
        return svc._error("missing_npc", "NPC must exist before adding memory", {"npc_id": npc_id})

    var memory_node_id = svc._graph.upsert_node(svc.MEMORY_SPACE, svc._memory_label(memory_id), {
        "type": "memory",
        "memory_id": memory_id,
        "npc_id": npc_id,
        "summary": summary,
        "conversation_id": conversation_id,
        "message_id": message_id,
        "world_day": world_day,
        "importance": importance,
        "confidence": confidence,
        "tags": tags.duplicate(true),
        "metadata": metadata.duplicate(true),
        "updated_at": svc._timestamp(),
    })
    if memory_node_id == -1:
        return svc._error("upsert_failed", "Failed to upsert memory", {"memory_id": memory_id})

    svc._graph.add_edge(npc_node_id, memory_node_id, "HAS_MEMORY", confidence, {
        "type": "memory_ref",
        "npc_id": npc_id,
        "memory_id": memory_id,
        "world_day": world_day,
        "importance": importance,
    })

    if message_id != -1:
        var message_node = svc._graph.get_node(message_id)
        if not message_node.is_empty():
            svc._graph.add_edge(message_id, memory_node_id, "SOURCE_MESSAGE", 1.0, {
                "type": "memory_source",
                "message_id": message_id,
                "conversation_id": conversation_id,
            })

    var response := {
        "node_id": memory_node_id,
    }
    var skip_embedding := bool(metadata.get("skip_embedding", false))
    if not skip_embedding:
        var embedding_opts: Dictionary = svc._embedding_options.duplicate(true)
        var meta_embedding_opts = metadata.get("embedding_options", null)
        if meta_embedding_opts is Dictionary:
            for key in meta_embedding_opts.keys():
                embedding_opts[key] = meta_embedding_opts[key]
        var embedding_result: Dictionary = svc._index_memory_embedding_node(memory_node_id, memory_id, npc_id, summary, embedding_opts)
        response["embedding"] = embedding_result
    return svc._ok(response)

static func add_dream_memory(svc, memory_id: String, npc_id: String, summary: String, world_day: int, influence: Dictionary, importance: float, confidence: float, metadata: Dictionary) -> Dictionary:
    var merged_tags: Array = ["dream"]
    var merged_metadata := metadata.duplicate(true)
    merged_metadata["memory_kind"] = "dream"
    merged_metadata["is_dream"] = true
    merged_metadata["is_factual"] = false
    merged_metadata["influence"] = influence.duplicate(true)
    return svc.add_memory(
        memory_id,
        npc_id,
        summary,
        -1,
        -1,
        world_day,
        importance,
        confidence,
        merged_tags,
        merged_metadata
    )

static func add_thought_memory(svc, memory_id: String, npc_id: String, summary: String, world_day: int, source_refs: Array, importance: float, confidence: float, metadata: Dictionary) -> Dictionary:
    var merged_tags: Array = ["thought"]
    var merged_metadata := metadata.duplicate(true)
    merged_metadata["memory_kind"] = "thought"
    merged_metadata["is_dream"] = false
    merged_metadata["is_factual"] = false
    merged_metadata["source_refs"] = source_refs.duplicate(true)
    return svc.add_memory(
        memory_id,
        npc_id,
        summary,
        -1,
        -1,
        world_day,
        importance,
        confidence,
        merged_tags,
        merged_metadata
    )

static func update_quest_state(svc, npc_id: String, quest_id: String, state: String, world_day: int, is_active: bool, metadata: Dictionary) -> Dictionary:
    if npc_id.strip_edges() == "":
        return svc._error("invalid_npc_id", "npc_id must be non-empty")
    if quest_id.strip_edges() == "":
        return svc._error("invalid_quest_id", "quest_id must be non-empty")
    if state.strip_edges() == "":
        return svc._error("invalid_state", "state must be non-empty")
    if world_day < 0:
        return svc._error("invalid_world_day", "world_day must be >= 0")

    var npc_node_id = svc._node_id_by_external_id(svc.NPC_SPACE, "npc_id", npc_id)
    var quest_node_id = svc._node_id_by_external_id(svc.QUEST_SPACE, "id", quest_id)
    if npc_node_id == -1 or quest_node_id == -1:
        return svc._error("missing_node", "NPC and quest must both exist", {"npc_id": npc_id, "quest_id": quest_id})

    var state_label = svc._quest_state_label(npc_id, quest_id, world_day, state)
    var state_node_id = svc._graph.upsert_node(svc.QUEST_STATE_SPACE, state_label, {
        "type": "quest_state",
        "npc_id": npc_id,
        "quest_id": quest_id,
        "state": state,
        "world_day": world_day,
        "is_active": is_active,
        "metadata": metadata.duplicate(true),
        "updated_at": svc._timestamp(),
    })
    if state_node_id == -1:
        return svc._error("upsert_failed", "Failed to upsert quest_state", {"quest_id": quest_id})

    svc._graph.add_edge(npc_node_id, state_node_id, "HAS_QUEST_STATE", 1.0, {
        "npc_id": npc_id,
        "quest_id": quest_id,
        "state": state,
        "world_day": world_day,
    })
    svc._graph.add_edge(quest_node_id, state_node_id, "HAS_QUEST_STATE", 1.0, {
        "npc_id": npc_id,
        "quest_id": quest_id,
        "state": state,
        "world_day": world_day,
    })
    return svc._ok({"node_id": state_node_id})

static func update_dialogue_state(svc, npc_id: String, state_key: String, state_value: Variant, world_day: int, conversation_id: int, metadata: Dictionary) -> Dictionary:
    if npc_id.strip_edges() == "":
        return svc._error("invalid_npc_id", "npc_id must be non-empty")
    if state_key.strip_edges() == "":
        return svc._error("invalid_state_key", "state_key must be non-empty")
    var npc_node_id = svc._node_id_by_external_id(svc.NPC_SPACE, "npc_id", npc_id)
    if npc_node_id == -1:
        return svc._error("missing_npc", "NPC must exist before dialogue state writes", {"npc_id": npc_id})

    var node_id = svc._graph.upsert_node(svc.DIALOGUE_STATE_SPACE, svc._dialogue_state_label(npc_id, state_key), {
        "type": "dialogue_state",
        "npc_id": npc_id,
        "state_key": state_key,
        "state_value": state_value,
        "world_day": world_day,
        "conversation_id": conversation_id,
        "metadata": metadata.duplicate(true),
        "updated_at": svc._timestamp(),
    })
    if node_id == -1:
        return svc._error("upsert_failed", "Failed to upsert dialogue_state", {"state_key": state_key})

    svc._graph.add_edge(npc_node_id, node_id, "HAS_DIALOGUE_STATE", 1.0, {
        "npc_id": npc_id,
        "state_key": state_key,
        "world_day": world_day,
        "conversation_id": conversation_id,
    })
    return svc._ok({"node_id": node_id})

static func ingest_conversation_message_as_memory(svc, npc_id: String, message: Dictionary, memory_id: String, world_day: int, importance: float, confidence: float) -> Dictionary:
    if message.is_empty():
        return svc._error("invalid_message", "message dictionary cannot be empty")
    var resolved_memory_id = memory_id
    if resolved_memory_id.strip_edges() == "":
        var mid = int(message.get("id", -1))
        resolved_memory_id = "msg_%d" % mid
    return svc.add_memory(
        resolved_memory_id,
        npc_id,
        String(message.get("content", "")),
        int(message.get("conversation_id", -1)),
        int(message.get("id", -1)),
        world_day,
        importance,
        confidence,
        [],
        {"source": "conversation_store"}
    )

static func get_backstory_context(svc, npc_id: String, world_day: int, limit: int) -> Dictionary:
    if limit <= 0:
        return svc._error("invalid_limit", "limit must be > 0")
    var npc = svc._node_by_external_id(svc.NPC_SPACE, "npc_id", npc_id)
    if npc.is_empty():
        return svc._error("missing_npc", "NPC not found", {"npc_id": npc_id})

    var relationships = svc._active_relationships_for_npc(int(npc.get("id", -1)), world_day, limit)
    var memories = svc._nodes_for_npc(svc.MEMORY_SPACE, npc_id, world_day, limit)
    var quest_states = svc._nodes_for_npc(svc.QUEST_STATE_SPACE, npc_id, world_day, limit)
    var dialogue_states = svc._nodes_for_npc(svc.DIALOGUE_STATE_SPACE, npc_id, world_day, limit)
    var beliefs_result: Dictionary = svc.get_beliefs_for_npc(npc_id, world_day, limit)
    var beliefs: Array = []
    if bool(beliefs_result.get("ok", false)):
        beliefs = beliefs_result.get("beliefs", [])
    var belief_conflicts_result: Dictionary = svc.get_belief_truth_conflicts(npc_id, world_day, limit)
    var belief_truth_conflicts: Array = []
    if bool(belief_conflicts_result.get("ok", false)):
        belief_truth_conflicts = belief_conflicts_result.get("conflicts", [])
    var truths_result: Dictionary = svc.get_truths_for_subject(npc_id, world_day, limit)
    var truths_for_subject: Array = []
    if bool(truths_result.get("ok", false)):
        truths_for_subject = truths_result.get("truths", [])
    var relationship_states: Array = []
    if world_day >= 0:
        var rel = svc.get_relationships_for_npc(npc_id, world_day, 14, 64)
        if bool(rel.get("ok", false)):
            relationship_states = rel.get("relationships", [])

    return svc._ok({
        "npc": npc.get("data", {}).duplicate(true),
        "relationships": relationships,
        "relationship_states": relationship_states,
        "memories": memories,
        "quest_states": quest_states,
        "dialogue_states": dialogue_states,
        "beliefs": beliefs,
        "belief_truth_conflicts": belief_truth_conflicts,
        "truths_for_subject": truths_for_subject,
    })

static func get_memory_recall_candidates(svc, npc_id: String, world_day: int, limit: int, include_dreams: bool) -> Dictionary:
    if npc_id.strip_edges() == "":
        return svc._error("invalid_npc_id", "npc_id must be non-empty")
    if limit <= 0:
        return svc._error("invalid_limit", "limit must be > 0")
    if not svc._ensure_graph():
        return svc._error("graph_unavailable", "NetworkGraph extension unavailable")
    var rows = svc._graph.list_nodes_by_metadata(svc.MEMORY_SPACE, "npc_id", npc_id, svc.DEFAULT_SCAN_LIMIT, 0)
    var candidates: Array = []
    for row in rows:
        var data: Dictionary = row.get("data", {})
        var row_day := int(data.get("world_day", -1))
        if world_day >= 0 and row_day >= 0 and row_day > world_day:
            continue
        var metadata: Dictionary = data.get("metadata", {})
        var is_dream := bool(metadata.get("is_dream", false))
        if not include_dreams and is_dream:
            continue
        candidates.append({
            "memory_id": String(data.get("memory_id", "")),
            "summary": String(data.get("summary", "")),
            "world_day": row_day,
            "importance": float(data.get("importance", 0.0)),
            "confidence": float(data.get("confidence", 0.0)),
            "is_dream": is_dream,
            "memory_kind": String(metadata.get("memory_kind", "memory")),
            "metadata": metadata.duplicate(true),
        })
    candidates.sort_custom(func(a, b):
        var ia := float(a.get("importance", 0.0))
        var ib := float(b.get("importance", 0.0))
        if ia == ib:
            var da := int(a.get("world_day", -1))
            var db := int(b.get("world_day", -1))
            return da > db
        return ia > ib
    )
    if candidates.size() > limit:
        candidates.resize(limit)
    return svc._ok({
        "npc_id": npc_id,
        "candidates": candidates,
    })

static func index_memory_embedding(svc, memory_id: String, text: String, options: Dictionary) -> Dictionary:
    if memory_id.strip_edges() == "":
        return svc._error("invalid_memory_id", "memory_id must be non-empty")
    if not svc._ensure_graph():
        return svc._error("graph_unavailable", "NetworkGraph extension unavailable")
    var rows = svc._graph.list_nodes_by_metadata(svc.MEMORY_SPACE, "memory_id", memory_id, 1, 0)
    if rows.is_empty():
        return svc._error("missing_memory", "memory_id not found", {"memory_id": memory_id})
    var row: Dictionary = rows[0]
    var node_id := int(row.get("id", -1))
    var data: Dictionary = row.get("data", {})
    var npc_id := String(data.get("npc_id", ""))
    var summary := text.strip_edges()
    if summary == "":
        summary = String(data.get("summary", "")).strip_edges()
    var merged: Dictionary = svc._embedding_options.duplicate(true)
    for key in options.keys():
        merged[key] = options[key]
    return svc._index_memory_embedding_node(node_id, memory_id, npc_id, summary, merged)

static func search_memory_embeddings(svc, npc_id: String, query: String, top_k: int, expand: int, strategy: String, options: Dictionary) -> Dictionary:
    if npc_id.strip_edges() == "":
        return svc._error("invalid_npc_id", "npc_id must be non-empty")
    if query.strip_edges() == "":
        return svc._error("invalid_query", "query must be non-empty")
    if top_k <= 0:
        return svc._error("invalid_top_k", "top_k must be > 0")
    if not svc._ensure_graph():
        return svc._error("graph_unavailable", "NetworkGraph extension unavailable")

    var runtime: Object = svc._agent_runtime()
    if runtime == null or not runtime.has_method("embed_text"):
        return svc._error("runtime_unavailable", "AgentRuntime embedding unavailable")

    var embed_options: Dictionary = svc._embedding_options.duplicate(true)
    for key in options.keys():
        embed_options[key] = options[key]
    var backend_ready = svc._ensure_embedding_backend_ready(embed_options, runtime)
    if not bool(backend_ready.get("ok", false)):
        return svc._error("embedding_backend_unavailable", "embedding backend unavailable", backend_ready)
    var query_vector: PackedFloat32Array = runtime.call("embed_text", query, embed_options)
    if query_vector.is_empty():
        return svc._error("embedding_failed", "query embedding failed")

    var matches: Array = svc._graph.search_embeddings(query_vector, top_k, expand, strategy)
    var memories: Array = []
    for item_variant in matches:
        if not (item_variant is Dictionary):
            continue
        var item: Dictionary = item_variant
        var node_id := int(item.get("node_id", -1))
        if node_id == -1:
            continue
        var node: Dictionary = svc._graph.get_node(node_id)
        if node.is_empty():
            continue
        var data: Dictionary = node.get("data", {})
        if String(data.get("type", "")) != "memory":
            continue
        if String(data.get("npc_id", "")) != npc_id:
            continue
        memories.append({
            "memory_id": String(data.get("memory_id", "")),
            "summary": String(data.get("summary", "")),
            "world_day": int(data.get("world_day", -1)),
            "importance": float(data.get("importance", 0.0)),
            "confidence": float(data.get("confidence", 0.0)),
            "memory_kind": String(data.get("metadata", {}).get("memory_kind", "memory")),
            "metadata": data.get("metadata", {}).duplicate(true),
            "embedding_id": int(item.get("embedding_id", -1)),
            "distance": float(item.get("distance", 1.0)),
            "similarity": float(item.get("similarity", 0.0)),
            "strategy": String(item.get("strategy", strategy)),
        })
    return svc._ok({
        "npc_id": npc_id,
        "query": query,
        "strategy": strategy,
        "results": memories,
    })

static func detect_contradictions(svc, npc_id: String) -> Dictionary:
    var npc = svc._node_by_external_id(svc.NPC_SPACE, "npc_id", npc_id)
    if npc.is_empty():
        return svc._error("missing_npc", "NPC not found", {"npc_id": npc_id})
    var npc_node_id = int(npc.get("id", -1))

    var contradictions: Array = []
    var active_exclusive_memberships = svc._active_exclusive_memberships(npc_node_id)
    if active_exclusive_memberships.size() > 1:
        contradictions.append({
            "code": "exclusive_membership_conflict",
            "message": "NPC has multiple active exclusive memberships",
            "memberships": active_exclusive_memberships,
        })

    var life_state = svc._dialogue_state_value(npc_id, "life_status")
    var death_day = int(svc._dialogue_state_value(npc_id, "death_day", -1))
    if String(life_state) == "dead" and death_day >= 0:
        var post_death_states = svc._post_day_nodes(svc.QUEST_STATE_SPACE, npc_id, death_day)
        if not post_death_states.is_empty():
            contradictions.append({
                "code": "post_death_activity",
                "message": "NPC has quest activity after declared death day",
                "death_day": death_day,
                "rows": post_death_states,
            })
    return svc._ok({
        "npc_id": npc_id,
        "contradictions": contradictions,
    })
