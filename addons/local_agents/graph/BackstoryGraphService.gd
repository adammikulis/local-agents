@tool
extends Node
class_name LocalAgentsBackstoryGraphService

const ExtensionLoader = preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const STORE_DIR = "user://local_agents"
const DB_PATH = STORE_DIR + "/network.sqlite3"

const NPC_SPACE = "npc"
const FACTION_SPACE = "faction"
const PLACE_SPACE = "place"
const QUEST_SPACE = "quest"
const EVENT_SPACE = "event"
const MEMORY_SPACE = "memory"
const QUEST_STATE_SPACE = "quest_state"
const DIALOGUE_STATE_SPACE = "dialogue_state"
const WORLD_TIME_SPACE = "world_time"
const RELATIONSHIP_PROFILE_SPACE = "relationship_profile"
const RELATIONSHIP_EVENT_SPACE = "relationship_event"
const TRUTH_SPACE = "truth"
const BELIEF_SPACE = "belief"

const DEFAULT_SCAN_LIMIT = 4096
const CYPHER_PLAYBOOK_VERSION = "backstory_cypher_playbook_v1"

var _graph: Object = null
var _database_path_override: String = ""
var _embedding_options: Dictionary = {
    "backend": "llama_server",
    "normalize": true,
    "server_autostart": true,
    "server_shutdown_on_exit": false,
    "server_start_timeout_ms": 30000,
    "server_ready_timeout_ms": 1200,
}

func _ready() -> void:
    _ensure_graph()

func set_database_path(path: String) -> void:
    if _graph != null:
        push_warning("set_database_path called after graph init; ignoring override")
        return
    _database_path_override = path.strip_edges()

func set_embedding_options(options: Dictionary) -> void:
    _embedding_options = options.duplicate(true)

func get_embedding_options() -> Dictionary:
    return _embedding_options.duplicate(true)

func upsert_npc(npc_id: String, display_name: String, traits: Dictionary = {}, metadata: Dictionary = {}) -> Dictionary:
    if npc_id.strip_edges() == "":
        return _error("invalid_npc_id", "npc_id must be non-empty")
    if display_name.strip_edges() == "":
        return _error("invalid_display_name", "display_name must be non-empty")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")

    var payload = {
        "type": "npc",
        "npc_id": npc_id,
        "display_name": display_name,
        "traits": traits.duplicate(true),
        "metadata": metadata.duplicate(true),
        "updated_at": _timestamp(),
    }
    var node_id = _graph.upsert_node(NPC_SPACE, _npc_label(npc_id), payload)
    if node_id == -1:
        return _error("upsert_failed", "Failed to upsert npc", {"npc_id": npc_id})
    return _ok({
        "node_id": node_id,
        "npc_id": npc_id,
    })

func upsert_faction(faction_id: String, name: String, metadata: Dictionary = {}) -> Dictionary:
    return _upsert_basic_entity(FACTION_SPACE, "faction", faction_id, name, metadata)

func upsert_place(place_id: String, name: String, metadata: Dictionary = {}) -> Dictionary:
    return _upsert_basic_entity(PLACE_SPACE, "place", place_id, name, metadata)

func upsert_quest(quest_id: String, title: String, metadata: Dictionary = {}) -> Dictionary:
    return _upsert_basic_entity(QUEST_SPACE, "quest", quest_id, title, metadata)

func set_world_time(day: int, season: String = "", calendar: String = "", metadata: Dictionary = {}) -> Dictionary:
    if day < 0:
        return _error("invalid_world_day", "world day must be >= 0")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")
    var payload = {
        "type": "world_time",
        "world_day": day,
        "season": season,
        "calendar": calendar,
        "metadata": metadata.duplicate(true),
        "updated_at": _timestamp(),
    }
    var node_id = _graph.upsert_node(WORLD_TIME_SPACE, _world_time_label(day), payload)
    if node_id == -1:
        return _error("upsert_failed", "Failed to update world time", {"world_day": day})
    return _ok({
        "node_id": node_id,
        "world_day": day,
    })

func add_relationship(source_npc_id: String, target_entity_id: String, relationship_type: String, from_day: int, to_day: int = -1, confidence: float = 1.0, source: String = "runtime", exclusive: bool = false, metadata: Dictionary = {}) -> Dictionary:
    if relationship_type.strip_edges() == "":
        return _error("invalid_relationship_type", "relationship_type must be non-empty")
    if from_day < 0:
        return _error("invalid_from_day", "from_day must be >= 0")
    if to_day >= 0 and to_day < from_day:
        return _error("invalid_to_day", "to_day must be >= from_day when provided")
    if confidence < 0.0 or confidence > 1.0:
        return _error("invalid_confidence", "confidence must be between 0 and 1")

    var source_node = _node_id_by_external_id(NPC_SPACE, "npc_id", source_npc_id)
    var target_info = _resolve_relationship_target(relationship_type, target_entity_id)
    var target_node = int(target_info.get("node_id", -1))
    var target_space = String(target_info.get("space", ""))
    if source_node == -1 or target_node == -1:
        return _error("missing_node", "Relationship source/target nodes must exist", {
            "source_npc_id": source_npc_id,
            "target_entity_id": target_entity_id,
            "relationship_type": relationship_type,
        })

    var kind = relationship_type.to_upper()
    var edge_id = _graph.add_edge(source_node, target_node, kind, confidence, {
        "type": "relationship",
        "relationship_type": kind,
        "source_npc_id": source_npc_id,
        "target_id": target_entity_id,
        "target_space": target_space,
        "from_day": from_day,
        "to_day": to_day,
        "confidence": confidence,
        "source": source,
        "exclusive": exclusive,
        "metadata": metadata.duplicate(true),
    })
    if edge_id == -1:
        return _error("edge_failed", "Failed to add relationship", {"relationship_type": kind})
    return _ok({"edge_id": edge_id})

func update_relationship_profile(source_npc_id: String, target_npc_id: String, world_day: int, tags: Dictionary = {}, metadata: Dictionary = {}) -> Dictionary:
    if source_npc_id.strip_edges() == "" or target_npc_id.strip_edges() == "":
        return _error("invalid_npc_id", "source_npc_id and target_npc_id must be non-empty")
    if world_day < 0:
        return _error("invalid_world_day", "world_day must be >= 0")
    var source_node_id = _node_id_by_external_id(NPC_SPACE, "npc_id", source_npc_id)
    var target_node_id = _node_id_by_external_id(NPC_SPACE, "npc_id", target_npc_id)
    if source_node_id == -1 or target_node_id == -1:
        return _error("missing_npc", "Both NPCs must exist before profile updates", {
            "source_npc_id": source_npc_id,
            "target_npc_id": target_npc_id,
        })

    var key = _relationship_key(source_npc_id, target_npc_id)
    var existing = _graph.list_nodes_by_metadata(RELATIONSHIP_PROFILE_SPACE, "relationship_key", key, 1, 0)
    var existing_data: Dictionary = {}
    if not existing.is_empty():
        existing_data = existing[0].get("data", {}).duplicate(true)

    var normalized_tags = _normalize_relationship_tags(existing_data.get("tags", {}))
    for tag_name in tags.keys():
        normalized_tags[String(tag_name)] = bool(tags[tag_name])
    normalized_tags = _normalize_relationship_tags(normalized_tags)

    var previous_long_term = _normalize_long_term(existing_data.get("long_term", {}))
    var profile_node_id = _graph.upsert_node(RELATIONSHIP_PROFILE_SPACE, _relationship_profile_label(source_npc_id, target_npc_id), {
        "type": "relationship_profile",
        "relationship_key": key,
        "source_npc_id": source_npc_id,
        "target_npc_id": target_npc_id,
        "tags": normalized_tags,
        "long_term": previous_long_term,
        "world_day": world_day,
        "metadata": metadata.duplicate(true),
        "updated_at": _timestamp(),
    })
    if profile_node_id == -1:
        return _error("upsert_failed", "Failed to upsert relationship profile", {"relationship_key": key})

    _graph.add_edge(source_node_id, profile_node_id, "HAS_RELATIONSHIP_PROFILE", 1.0, {
        "type": "relationship_profile_ref",
        "relationship_key": key,
        "source_npc_id": source_npc_id,
        "target_npc_id": target_npc_id,
    })
    _graph.add_edge(profile_node_id, target_node_id, "TARGETS_NPC", 1.0, {
        "type": "relationship_profile_target",
        "relationship_key": key,
        "source_npc_id": source_npc_id,
        "target_npc_id": target_npc_id,
    })

    if normalized_tags.get("friend", false):
        add_relationship(source_npc_id, target_npc_id, "FRIEND_OF", world_day, -1, 1.0, "profile", false)
    if normalized_tags.get("enemy", false):
        add_relationship(source_npc_id, target_npc_id, "ENEMY_OF", world_day, -1, 1.0, "profile", false)
    if normalized_tags.get("family", false):
        add_relationship(source_npc_id, target_npc_id, "FAMILY_OF", world_day, -1, 1.0, "profile", false)

    return _ok({
        "node_id": profile_node_id,
        "relationship_key": key,
    })

func record_relationship_interaction(source_npc_id: String, target_npc_id: String, world_day: int, valence_delta: float, trust_delta: float = 0.0, respect_delta: float = 0.0, summary: String = "", metadata: Dictionary = {}) -> Dictionary:
    if source_npc_id.strip_edges() == "" or target_npc_id.strip_edges() == "":
        return _error("invalid_npc_id", "source_npc_id and target_npc_id must be non-empty")
    if world_day < 0:
        return _error("invalid_world_day", "world_day must be >= 0")
    if _node_id_by_external_id(NPC_SPACE, "npc_id", source_npc_id) == -1 or _node_id_by_external_id(NPC_SPACE, "npc_id", target_npc_id) == -1:
        return _error("missing_npc", "Both NPCs must exist before interaction writes", {
            "source_npc_id": source_npc_id,
            "target_npc_id": target_npc_id,
        })

    var event_node_id = _graph.upsert_node(RELATIONSHIP_EVENT_SPACE, _relationship_event_label(source_npc_id, target_npc_id, world_day), {
        "type": "relationship_event",
        "relationship_key": _relationship_key(source_npc_id, target_npc_id),
        "source_npc_id": source_npc_id,
        "target_npc_id": target_npc_id,
        "world_day": world_day,
        "valence_delta": clampf(valence_delta, -1.0, 1.0),
        "trust_delta": clampf(trust_delta, -1.0, 1.0),
        "respect_delta": clampf(respect_delta, -1.0, 1.0),
        "summary": summary,
        "metadata": metadata.duplicate(true),
        "updated_at": _timestamp(),
    })
    if event_node_id == -1:
        return _error("upsert_failed", "Failed to record relationship interaction", {
            "source_npc_id": source_npc_id,
            "target_npc_id": target_npc_id,
        })

    var recompute = _recompute_long_term_from_recent(source_npc_id, target_npc_id, world_day)
    if not recompute.get("ok", false):
        return recompute
    return _ok({
        "node_id": event_node_id,
        "relationship_key": _relationship_key(source_npc_id, target_npc_id),
    })

func get_relationship_state(source_npc_id: String, target_npc_id: String, world_day: int, recent_window_days: int = 14, recent_limit: int = 64) -> Dictionary:
    if source_npc_id.strip_edges() == "" or target_npc_id.strip_edges() == "":
        return _error("invalid_npc_id", "source_npc_id and target_npc_id must be non-empty")
    if world_day < 0:
        return _error("invalid_world_day", "world_day must be >= 0")
    if recent_window_days < 0:
        return _error("invalid_recent_window", "recent_window_days must be >= 0")

    var profile_rows = _graph.list_nodes_by_metadata(RELATIONSHIP_PROFILE_SPACE, "relationship_key", _relationship_key(source_npc_id, target_npc_id), 1, 0)
    var profile_data: Dictionary = {}
    if not profile_rows.is_empty():
        profile_data = profile_rows[0].get("data", {}).duplicate(true)

    var recent = _recent_relationship_stats(source_npc_id, target_npc_id, world_day, recent_window_days, recent_limit)
    var tags = _normalize_relationship_tags(profile_data.get("tags", {}))
    var long_term = _normalize_long_term(profile_data.get("long_term", {}))
    return _ok({
        "source_npc_id": source_npc_id,
        "target_npc_id": target_npc_id,
        "tags": tags,
        "long_term": long_term,
        "recent": recent,
    })

func get_relationships_for_npc(npc_id: String, world_day: int, recent_window_days: int = 14, recent_limit: int = 64) -> Dictionary:
    if npc_id.strip_edges() == "":
        return _error("invalid_npc_id", "npc_id must be non-empty")
    if _node_id_by_external_id(NPC_SPACE, "npc_id", npc_id) == -1:
        return _error("missing_npc", "NPC not found", {"npc_id": npc_id})
    var rows = _graph.list_nodes_by_metadata(RELATIONSHIP_PROFILE_SPACE, "source_npc_id", npc_id, DEFAULT_SCAN_LIMIT, 0)
    var output: Array = []
    for row in rows:
        var data: Dictionary = row.get("data", {})
        var target_npc_id = String(data.get("target_npc_id", ""))
        if target_npc_id == "":
            continue
        var state = get_relationship_state(npc_id, target_npc_id, world_day, recent_window_days, recent_limit)
        if bool(state.get("ok", false)):
            output.append(state)
    return _ok({
        "npc_id": npc_id,
        "relationships": output,
    })

func record_event(event_id: String, event_type: String, summary: String, world_day: int, place_id: String = "", participant_npc_ids: Array = [], metadata: Dictionary = {}) -> Dictionary:
    if event_id.strip_edges() == "":
        return _error("invalid_event_id", "event_id must be non-empty")
    if event_type.strip_edges() == "":
        return _error("invalid_event_type", "event_type must be non-empty")
    if world_day < 0:
        return _error("invalid_world_day", "world_day must be >= 0")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")

    var event_node_id = _graph.upsert_node(EVENT_SPACE, _event_label(event_id), {
        "type": "event",
        "event_id": event_id,
        "event_type": event_type,
        "summary": summary,
        "world_day": world_day,
        "place_id": place_id,
        "participants": participant_npc_ids.duplicate(true),
        "metadata": metadata.duplicate(true),
        "updated_at": _timestamp(),
    })
    if event_node_id == -1:
        return _error("upsert_failed", "Failed to upsert event", {"event_id": event_id})

    if place_id.strip_edges() != "":
        var place_node_id = _node_id_by_external_id(PLACE_SPACE, "id", place_id)
        if place_node_id != -1:
            _graph.add_edge(event_node_id, place_node_id, "OCCURRED_AT", 1.0, {
                "type": "event_place",
                "event_id": event_id,
                "place_id": place_id,
            })

    for participant in participant_npc_ids:
        var npc_id = String(participant)
        var npc_node_id = _node_id_by_external_id(NPC_SPACE, "npc_id", npc_id)
        if npc_node_id == -1:
            continue
        _graph.add_edge(npc_node_id, event_node_id, "PARTICIPATED_IN", 1.0, {
            "type": "participation",
            "npc_id": npc_id,
            "event_id": event_id,
            "world_day": world_day,
        })
    return _ok({"node_id": event_node_id})

func add_memory(memory_id: String, npc_id: String, summary: String, conversation_id: int = -1, message_id: int = -1, world_day: int = -1, importance: float = 0.5, confidence: float = 1.0, tags: Array = [], metadata: Dictionary = {}) -> Dictionary:
    if memory_id.strip_edges() == "":
        return _error("invalid_memory_id", "memory_id must be non-empty")
    if npc_id.strip_edges() == "":
        return _error("invalid_npc_id", "npc_id must be non-empty")
    if importance < 0.0 or importance > 1.0:
        return _error("invalid_importance", "importance must be between 0 and 1")
    if confidence < 0.0 or confidence > 1.0:
        return _error("invalid_confidence", "confidence must be between 0 and 1")
    if world_day < -1:
        return _error("invalid_world_day", "world_day must be >= -1")
    var npc_node_id = _node_id_by_external_id(NPC_SPACE, "npc_id", npc_id)
    if npc_node_id == -1:
        return _error("missing_npc", "NPC must exist before adding memory", {"npc_id": npc_id})

    var memory_node_id = _graph.upsert_node(MEMORY_SPACE, _memory_label(memory_id), {
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
        "updated_at": _timestamp(),
    })
    if memory_node_id == -1:
        return _error("upsert_failed", "Failed to upsert memory", {"memory_id": memory_id})

    _graph.add_edge(npc_node_id, memory_node_id, "HAS_MEMORY", confidence, {
        "type": "memory_ref",
        "npc_id": npc_id,
        "memory_id": memory_id,
        "world_day": world_day,
        "importance": importance,
    })

    if message_id != -1:
        var message_node = _graph.get_node(message_id)
        if not message_node.is_empty():
            _graph.add_edge(message_id, memory_node_id, "SOURCE_MESSAGE", 1.0, {
                "type": "memory_source",
                "message_id": message_id,
                "conversation_id": conversation_id,
            })

    var response := {
        "node_id": memory_node_id,
    }
    var skip_embedding := bool(metadata.get("skip_embedding", false))
    if not skip_embedding:
        var embedding_opts: Dictionary = _embedding_options.duplicate(true)
        var meta_embedding_opts = metadata.get("embedding_options", null)
        if meta_embedding_opts is Dictionary:
            for key in meta_embedding_opts.keys():
                embedding_opts[key] = meta_embedding_opts[key]
        var embedding_result: Dictionary = _index_memory_embedding_node(memory_node_id, memory_id, npc_id, summary, embedding_opts)
        response["embedding"] = embedding_result
    return _ok(response)

func add_dream_memory(memory_id: String, npc_id: String, summary: String, world_day: int, influence: Dictionary = {}, importance: float = 0.5, confidence: float = 0.8, metadata: Dictionary = {}) -> Dictionary:
    var merged_tags: Array = ["dream"]
    var merged_metadata := metadata.duplicate(true)
    merged_metadata["memory_kind"] = "dream"
    merged_metadata["is_dream"] = true
    merged_metadata["is_factual"] = false
    merged_metadata["influence"] = influence.duplicate(true)
    return add_memory(
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

func add_thought_memory(memory_id: String, npc_id: String, summary: String, world_day: int, source_refs: Array = [], importance: float = 0.45, confidence: float = 0.7, metadata: Dictionary = {}) -> Dictionary:
    var merged_tags: Array = ["thought"]
    var merged_metadata := metadata.duplicate(true)
    merged_metadata["memory_kind"] = "thought"
    merged_metadata["is_dream"] = false
    merged_metadata["is_factual"] = false
    merged_metadata["source_refs"] = source_refs.duplicate(true)
    return add_memory(
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

func upsert_world_truth(truth_id: String, subject_id: String, predicate: String, object_value: Variant, world_day: int = -1, confidence: float = 1.0, metadata: Dictionary = {}) -> Dictionary:
    if subject_id.strip_edges() == "":
        return _error("invalid_subject_id", "subject_id must be non-empty")
    if predicate.strip_edges() == "":
        return _error("invalid_predicate", "predicate must be non-empty")
    if world_day < -1:
        return _error("invalid_world_day", "world_day must be >= -1")
    if confidence < 0.0 or confidence > 1.0:
        return _error("invalid_confidence", "confidence must be between 0 and 1")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")

    var claim_key = _claim_key(subject_id, predicate)
    var resolved_truth_id = truth_id.strip_edges()
    if resolved_truth_id == "":
        resolved_truth_id = claim_key

    var payload = {
        "type": "truth",
        "truth_id": resolved_truth_id,
        "claim_key": claim_key,
        "subject_id": subject_id,
        "predicate": predicate,
        "object_value": object_value,
        "object_norm": _normalize_claim_value(object_value),
        "world_day": world_day,
        "confidence": confidence,
        "metadata": metadata.duplicate(true),
        "updated_at": _timestamp(),
    }
    var node_id = _graph.upsert_node(TRUTH_SPACE, _truth_label(resolved_truth_id), payload)
    if node_id == -1:
        return _error("upsert_failed", "Failed to upsert world truth", {
            "truth_id": resolved_truth_id,
            "claim_key": claim_key,
        })
    var subject_npc_node_id = _node_id_by_external_id(NPC_SPACE, "npc_id", subject_id)
    if subject_npc_node_id != -1:
        _graph.add_edge(subject_npc_node_id, node_id, "HAS_TRUTH", confidence, {
            "type": "truth_ref",
            "subject_id": subject_id,
            "predicate": predicate,
            "claim_key": claim_key,
        })
    return _ok({
        "node_id": node_id,
        "truth_id": resolved_truth_id,
        "claim_key": claim_key,
    })

func upsert_npc_belief(belief_id: String, npc_id: String, subject_id: String, predicate: String, object_value: Variant, world_day: int = -1, confidence: float = 0.7, metadata: Dictionary = {}) -> Dictionary:
    if npc_id.strip_edges() == "":
        return _error("invalid_npc_id", "npc_id must be non-empty")
    if subject_id.strip_edges() == "":
        return _error("invalid_subject_id", "subject_id must be non-empty")
    if predicate.strip_edges() == "":
        return _error("invalid_predicate", "predicate must be non-empty")
    if world_day < -1:
        return _error("invalid_world_day", "world_day must be >= -1")
    if confidence < 0.0 or confidence > 1.0:
        return _error("invalid_confidence", "confidence must be between 0 and 1")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")
    var npc_node_id = _node_id_by_external_id(NPC_SPACE, "npc_id", npc_id)
    if npc_node_id == -1:
        return _error("missing_npc", "NPC must exist before adding beliefs", {"npc_id": npc_id})

    var claim_key = _claim_key(subject_id, predicate)
    var resolved_belief_id = belief_id.strip_edges()
    if resolved_belief_id == "":
        resolved_belief_id = "%s:%s" % [npc_id, claim_key]

    var payload = {
        "type": "belief",
        "belief_id": resolved_belief_id,
        "npc_id": npc_id,
        "claim_key": claim_key,
        "subject_id": subject_id,
        "predicate": predicate,
        "object_value": object_value,
        "object_norm": _normalize_claim_value(object_value),
        "world_day": world_day,
        "confidence": confidence,
        "metadata": metadata.duplicate(true),
        "updated_at": _timestamp(),
    }
    var node_id = _graph.upsert_node(BELIEF_SPACE, _belief_label(resolved_belief_id), payload)
    if node_id == -1:
        return _error("upsert_failed", "Failed to upsert npc belief", {
            "belief_id": resolved_belief_id,
            "npc_id": npc_id,
            "claim_key": claim_key,
        })

    _graph.add_edge(npc_node_id, node_id, "HAS_BELIEF", confidence, {
        "type": "belief_ref",
        "npc_id": npc_id,
        "belief_id": resolved_belief_id,
        "claim_key": claim_key,
    })
    return _ok({
        "node_id": node_id,
        "belief_id": resolved_belief_id,
        "claim_key": claim_key,
    })

func get_truths_for_subject(subject_id: String, world_day: int = -1, limit: int = 32) -> Dictionary:
    if subject_id.strip_edges() == "":
        return _error("invalid_subject_id", "subject_id must be non-empty")
    if limit <= 0:
        return _error("invalid_limit", "limit must be > 0")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")
    var rows = _graph.list_nodes_by_metadata(TRUTH_SPACE, "subject_id", subject_id, DEFAULT_SCAN_LIMIT, 0)
    var items: Array = []
    for row in rows:
        var data: Dictionary = row.get("data", {})
        var row_day = int(data.get("world_day", -1))
        if world_day >= 0 and row_day >= 0 and row_day > world_day:
            continue
        items.append(data.duplicate(true))
    items.sort_custom(func(a, b):
        var da = int(a.get("world_day", -1))
        var db = int(b.get("world_day", -1))
        if da == db:
            return int(a.get("updated_at", 0)) > int(b.get("updated_at", 0))
        return da > db
    )
    if items.size() > limit:
        items.resize(limit)
    return _ok({
        "subject_id": subject_id,
        "truths": items,
    })

func get_beliefs_for_npc(npc_id: String, world_day: int = -1, limit: int = 32) -> Dictionary:
    if npc_id.strip_edges() == "":
        return _error("invalid_npc_id", "npc_id must be non-empty")
    if limit <= 0:
        return _error("invalid_limit", "limit must be > 0")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")
    var rows = _graph.list_nodes_by_metadata(BELIEF_SPACE, "npc_id", npc_id, DEFAULT_SCAN_LIMIT, 0)
    var items: Array = []
    for row in rows:
        var data: Dictionary = row.get("data", {})
        var row_day = int(data.get("world_day", -1))
        if world_day >= 0 and row_day >= 0 and row_day > world_day:
            continue
        items.append(data.duplicate(true))
    items.sort_custom(func(a, b):
        var da = int(a.get("world_day", -1))
        var db = int(b.get("world_day", -1))
        if da == db:
            return int(a.get("updated_at", 0)) > int(b.get("updated_at", 0))
        return da > db
    )
    if items.size() > limit:
        items.resize(limit)
    return _ok({
        "npc_id": npc_id,
        "beliefs": items,
    })

func get_belief_truth_conflicts(npc_id: String, world_day: int = -1, limit: int = 32) -> Dictionary:
    var beliefs_result: Dictionary = get_beliefs_for_npc(npc_id, world_day, DEFAULT_SCAN_LIMIT)
    if not bool(beliefs_result.get("ok", false)):
        return beliefs_result
    var beliefs: Array = beliefs_result.get("beliefs", [])
    var conflicts: Array = []
    for belief_variant in beliefs:
        if not (belief_variant is Dictionary):
            continue
        var belief: Dictionary = belief_variant
        var claim_key = String(belief.get("claim_key", ""))
        if claim_key == "":
            continue
        var truth = _latest_truth_for_claim(claim_key, world_day)
        if truth.is_empty():
            continue
        if String(belief.get("object_norm", "")) == String(truth.get("object_norm", "")):
            continue
        conflicts.append({
            "npc_id": npc_id,
            "claim_key": claim_key,
            "belief": belief.duplicate(true),
            "truth": truth.duplicate(true),
        })
    conflicts.sort_custom(func(a, b):
        return float(a.get("belief", {}).get("confidence", 0.0)) > float(b.get("belief", {}).get("confidence", 0.0))
    )
    if conflicts.size() > limit:
        conflicts.resize(limit)
    return _ok({
        "npc_id": npc_id,
        "conflicts": conflicts,
    })

func update_quest_state(npc_id: String, quest_id: String, state: String, world_day: int, is_active: bool = true, metadata: Dictionary = {}) -> Dictionary:
    if npc_id.strip_edges() == "":
        return _error("invalid_npc_id", "npc_id must be non-empty")
    if quest_id.strip_edges() == "":
        return _error("invalid_quest_id", "quest_id must be non-empty")
    if state.strip_edges() == "":
        return _error("invalid_state", "state must be non-empty")
    if world_day < 0:
        return _error("invalid_world_day", "world_day must be >= 0")

    var npc_node_id = _node_id_by_external_id(NPC_SPACE, "npc_id", npc_id)
    var quest_node_id = _node_id_by_external_id(QUEST_SPACE, "id", quest_id)
    if npc_node_id == -1 or quest_node_id == -1:
        return _error("missing_node", "NPC and quest must both exist", {"npc_id": npc_id, "quest_id": quest_id})

    var state_label = _quest_state_label(npc_id, quest_id, world_day, state)
    var state_node_id = _graph.upsert_node(QUEST_STATE_SPACE, state_label, {
        "type": "quest_state",
        "npc_id": npc_id,
        "quest_id": quest_id,
        "state": state,
        "world_day": world_day,
        "is_active": is_active,
        "metadata": metadata.duplicate(true),
        "updated_at": _timestamp(),
    })
    if state_node_id == -1:
        return _error("upsert_failed", "Failed to upsert quest_state", {"quest_id": quest_id})

    _graph.add_edge(npc_node_id, state_node_id, "HAS_QUEST_STATE", 1.0, {
        "npc_id": npc_id,
        "quest_id": quest_id,
        "state": state,
        "world_day": world_day,
    })
    _graph.add_edge(quest_node_id, state_node_id, "HAS_QUEST_STATE", 1.0, {
        "npc_id": npc_id,
        "quest_id": quest_id,
        "state": state,
        "world_day": world_day,
    })
    return _ok({"node_id": state_node_id})

func update_dialogue_state(npc_id: String, state_key: String, state_value: Variant, world_day: int = -1, conversation_id: int = -1, metadata: Dictionary = {}) -> Dictionary:
    if npc_id.strip_edges() == "":
        return _error("invalid_npc_id", "npc_id must be non-empty")
    if state_key.strip_edges() == "":
        return _error("invalid_state_key", "state_key must be non-empty")
    var npc_node_id = _node_id_by_external_id(NPC_SPACE, "npc_id", npc_id)
    if npc_node_id == -1:
        return _error("missing_npc", "NPC must exist before dialogue state writes", {"npc_id": npc_id})

    var node_id = _graph.upsert_node(DIALOGUE_STATE_SPACE, _dialogue_state_label(npc_id, state_key), {
        "type": "dialogue_state",
        "npc_id": npc_id,
        "state_key": state_key,
        "state_value": state_value,
        "world_day": world_day,
        "conversation_id": conversation_id,
        "metadata": metadata.duplicate(true),
        "updated_at": _timestamp(),
    })
    if node_id == -1:
        return _error("upsert_failed", "Failed to upsert dialogue_state", {"state_key": state_key})

    _graph.add_edge(npc_node_id, node_id, "HAS_DIALOGUE_STATE", 1.0, {
        "npc_id": npc_id,
        "state_key": state_key,
        "world_day": world_day,
        "conversation_id": conversation_id,
    })
    return _ok({"node_id": node_id})

func ingest_conversation_message_as_memory(npc_id: String, message: Dictionary, memory_id: String = "", world_day: int = -1, importance: float = 0.5, confidence: float = 0.8) -> Dictionary:
    if message.is_empty():
        return _error("invalid_message", "message dictionary cannot be empty")
    var resolved_memory_id = memory_id
    if resolved_memory_id.strip_edges() == "":
        var mid = int(message.get("id", -1))
        resolved_memory_id = "msg_%d" % mid
    return add_memory(
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

func get_backstory_context(npc_id: String, world_day: int = -1, limit: int = 32) -> Dictionary:
    if limit <= 0:
        return _error("invalid_limit", "limit must be > 0")
    var npc = _node_by_external_id(NPC_SPACE, "npc_id", npc_id)
    if npc.is_empty():
        return _error("missing_npc", "NPC not found", {"npc_id": npc_id})

    var relationships = _active_relationships_for_npc(int(npc.get("id", -1)), world_day, limit)
    var memories = _nodes_for_npc(MEMORY_SPACE, npc_id, world_day, limit)
    var quest_states = _nodes_for_npc(QUEST_STATE_SPACE, npc_id, world_day, limit)
    var dialogue_states = _nodes_for_npc(DIALOGUE_STATE_SPACE, npc_id, world_day, limit)
    var beliefs_result: Dictionary = get_beliefs_for_npc(npc_id, world_day, limit)
    var beliefs: Array = []
    if bool(beliefs_result.get("ok", false)):
        beliefs = beliefs_result.get("beliefs", [])
    var belief_conflicts_result: Dictionary = get_belief_truth_conflicts(npc_id, world_day, limit)
    var belief_truth_conflicts: Array = []
    if bool(belief_conflicts_result.get("ok", false)):
        belief_truth_conflicts = belief_conflicts_result.get("conflicts", [])
    var truths_result: Dictionary = get_truths_for_subject(npc_id, world_day, limit)
    var truths_for_subject: Array = []
    if bool(truths_result.get("ok", false)):
        truths_for_subject = truths_result.get("truths", [])
    var relationship_states: Array = []
    if world_day >= 0:
        var rel = get_relationships_for_npc(npc_id, world_day, 14, 64)
        if bool(rel.get("ok", false)):
            relationship_states = rel.get("relationships", [])

    return _ok({
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

func get_memory_recall_candidates(npc_id: String, world_day: int = -1, limit: int = 8, include_dreams: bool = true) -> Dictionary:
    if npc_id.strip_edges() == "":
        return _error("invalid_npc_id", "npc_id must be non-empty")
    if limit <= 0:
        return _error("invalid_limit", "limit must be > 0")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")
    var rows = _graph.list_nodes_by_metadata(MEMORY_SPACE, "npc_id", npc_id, DEFAULT_SCAN_LIMIT, 0)
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
    return _ok({
        "npc_id": npc_id,
        "candidates": candidates,
    })

func index_memory_embedding(memory_id: String, text: String = "", options: Dictionary = {}) -> Dictionary:
    if memory_id.strip_edges() == "":
        return _error("invalid_memory_id", "memory_id must be non-empty")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")
    var rows = _graph.list_nodes_by_metadata(MEMORY_SPACE, "memory_id", memory_id, 1, 0)
    if rows.is_empty():
        return _error("missing_memory", "memory_id not found", {"memory_id": memory_id})
    var row: Dictionary = rows[0]
    var node_id := int(row.get("id", -1))
    var data: Dictionary = row.get("data", {})
    var npc_id := String(data.get("npc_id", ""))
    var summary := text.strip_edges()
    if summary == "":
        summary = String(data.get("summary", "")).strip_edges()
    var merged: Dictionary = _embedding_options.duplicate(true)
    for key in options.keys():
        merged[key] = options[key]
    return _index_memory_embedding_node(node_id, memory_id, npc_id, summary, merged)

func search_memory_embeddings(npc_id: String, query: String, top_k: int = 8, expand: int = 32, strategy: String = "cosine", options: Dictionary = {}) -> Dictionary:
    if npc_id.strip_edges() == "":
        return _error("invalid_npc_id", "npc_id must be non-empty")
    if query.strip_edges() == "":
        return _error("invalid_query", "query must be non-empty")
    if top_k <= 0:
        return _error("invalid_top_k", "top_k must be > 0")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")

    var runtime := _agent_runtime()
    if runtime == null or not runtime.has_method("embed_text"):
        return _error("runtime_unavailable", "AgentRuntime embedding unavailable")

    var embed_options: Dictionary = _embedding_options.duplicate(true)
    for key in options.keys():
        embed_options[key] = options[key]
    var query_vector: PackedFloat32Array = runtime.call("embed_text", query, embed_options)
    if query_vector.is_empty():
        return _error("embedding_failed", "query embedding failed")

    var matches: Array = _graph.search_embeddings(query_vector, top_k, expand, strategy)
    var memories: Array = []
    for item_variant in matches:
        if not (item_variant is Dictionary):
            continue
        var item: Dictionary = item_variant
        var node_id := int(item.get("node_id", -1))
        if node_id == -1:
            continue
        var node: Dictionary = _graph.get_node(node_id)
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
    return _ok({
        "npc_id": npc_id,
        "query": query,
        "strategy": strategy,
        "results": memories,
    })

func detect_contradictions(npc_id: String) -> Dictionary:
    var npc = _node_by_external_id(NPC_SPACE, "npc_id", npc_id)
    if npc.is_empty():
        return _error("missing_npc", "NPC not found", {"npc_id": npc_id})
    var npc_node_id = int(npc.get("id", -1))

    var contradictions: Array = []
    var active_exclusive_memberships = _active_exclusive_memberships(npc_node_id)
    if active_exclusive_memberships.size() > 1:
        contradictions.append({
            "code": "exclusive_membership_conflict",
            "message": "NPC has multiple active exclusive memberships",
            "memberships": active_exclusive_memberships,
        })

    var life_state = _dialogue_state_value(npc_id, "life_status")
    var death_day = int(_dialogue_state_value(npc_id, "death_day", -1))
    if String(life_state) == "dead" and death_day >= 0:
        var post_death_states = _post_day_nodes(QUEST_STATE_SPACE, npc_id, death_day)
        if not post_death_states.is_empty():
            contradictions.append({
                "code": "post_death_activity",
                "message": "NPC has quest activity after declared death day",
                "death_day": death_day,
                "rows": post_death_states,
            })
    return _ok({
        "npc_id": npc_id,
        "contradictions": contradictions,
    })

func get_cypher_playbook(npc_id: String = "", world_day: int = -1, limit: int = 32) -> Dictionary:
    var resolved_npc_id = npc_id if npc_id.strip_edges() != "" else "<npc_id>"
    var resolved_day = world_day if world_day >= 0 else 0
    var resolved_limit = maxi(limit, 1)
    var window_start = maxi(0, resolved_day - 14)

    var common_params = {
        "npc_id": resolved_npc_id,
        "world_day": resolved_day,
        "window_start": window_start,
        "limit": resolved_limit,
    }

    var queries = {
        "upsert_npc": {
            "description": "Create/update one NPC node",
            "params": {
                "npc_id": resolved_npc_id,
                "name": "<name>",
            },
            "cypher": "MERGE (n:NPC {npc_id: $npc_id})\n"
                + "SET n.name = $name,\n"
                + "    n.updated_at = timestamp()\n"
                + "RETURN n;",
        },
        "upsert_memory_and_link": {
            "description": "Create/update memory and attach it to an NPC",
            "params": {
                "npc_id": resolved_npc_id,
                "memory_id": "<memory_id>",
                "summary": "<summary>",
                "importance": 0.8,
                "confidence": 0.9,
                "world_day": resolved_day,
            },
            "cypher": "MATCH (n:NPC {npc_id: $npc_id})\n"
                + "MERGE (m:Memory {memory_id: $memory_id})\n"
                + "SET m.summary = $summary,\n"
                + "    m.importance = $importance,\n"
                + "    m.confidence = $confidence,\n"
                + "    m.world_day = $world_day,\n"
                + "    m.updated_at = timestamp()\n"
                + "MERGE (n)-[r:HAS_MEMORY]->(m)\n"
                + "SET r.confidence = $confidence,\n"
                + "    r.world_day = $world_day\n"
                + "RETURN n, r, m;",
        },
        "relationship_state": {
            "description": "Inspect directional relationship profile + recent event aggregate",
            "params": {
                "source_npc_id": resolved_npc_id,
                "target_npc_id": "<target_npc_id>",
                "window_start": window_start,
                "world_day": resolved_day,
            },
            "cypher": "MATCH (a:NPC {npc_id: $source_npc_id})\n"
                + "MATCH (b:NPC {npc_id: $target_npc_id})\n"
                + "OPTIONAL MATCH (a)-[:HAS_RELATIONSHIP_PROFILE]->(p:RelationshipProfile)-[:TARGETS_NPC]->(b)\n"
                + "OPTIONAL MATCH (e:RelationshipEvent {source_npc_id: $source_npc_id, target_npc_id: $target_npc_id})\n"
                + "WHERE e.world_day >= $window_start AND e.world_day <= $world_day\n"
                + "RETURN p,\n"
                + "       count(e) AS recent_count,\n"
                + "       avg(e.valence_delta) AS recent_valence_avg,\n"
                + "       avg(e.trust_delta) AS recent_trust_avg,\n"
                + "       avg(e.respect_delta) AS recent_respect_avg;",
        },
        "npc_backstory_context": {
            "description": "Fetch relationship, memory, quest state, and dialogue state context for an NPC",
            "params": common_params,
            "cypher": "MATCH (n:NPC {npc_id: $npc_id})\n"
                + "OPTIONAL MATCH (n)-[rel]->(x)\n"
                + "WHERE (\n"
                + "    x:Memory OR\n"
                + "    x:QuestState OR\n"
                + "    x:DialogueState OR\n"
                + "    x:RelationshipProfile OR\n"
                + "    type(rel) IN ['HAS_MEMORY', 'HAS_QUEST_STATE', 'HAS_DIALOGUE_STATE', 'HAS_RELATIONSHIP_PROFILE']\n"
                + ")\n"
                + "RETURN n, rel, x\n"
                + "ORDER BY coalesce(x.world_day, 0) DESC, coalesce(x.updated_at, 0) DESC\n"
                + "LIMIT $limit;",
        },
        "recent_relationship_events": {
            "description": "Inspect recent directional interaction events for an NPC pair",
            "params": {
                "source_npc_id": resolved_npc_id,
                "target_npc_id": "<target_npc_id>",
                "window_start": window_start,
                "world_day": resolved_day,
                "limit": resolved_limit,
            },
            "cypher": "MATCH (e:RelationshipEvent {source_npc_id: $source_npc_id, target_npc_id: $target_npc_id})\n"
                + "WHERE e.world_day >= $window_start AND e.world_day <= $world_day\n"
                + "RETURN e\n"
                + "ORDER BY e.world_day DESC, e.updated_at DESC\n"
                + "LIMIT $limit;",
        },
        "quest_state_timeline": {
            "description": "Show one NPC's quest progression over time",
            "params": common_params,
            "cypher": "MATCH (n:NPC {npc_id: $npc_id})-[:HAS_QUEST_STATE]->(qs:QuestState)\n"
                + "RETURN qs.quest_id AS quest_id,\n"
                + "       qs.state AS state,\n"
                + "       qs.is_active AS is_active,\n"
                + "       qs.world_day AS world_day,\n"
                + "       qs.updated_at AS updated_at\n"
                + "ORDER BY qs.world_day ASC, qs.updated_at ASC\n"
                + "LIMIT $limit;",
        },
        "exclusive_membership_conflicts": {
            "description": "Find NPCs with multiple active exclusive memberships",
            "params": {"limit": resolved_limit},
            "cypher": "MATCH (n:NPC)-[m:MEMBER_OF]->(f:Faction)\n"
                + "WHERE coalesce(m.exclusive, false) = true AND coalesce(m.to_day, -1) = -1\n"
                + "WITH n, collect(f.faction_id) AS factions, count(m) AS cnt\n"
                + "WHERE cnt > 1\n"
                + "RETURN n.npc_id AS npc_id, factions, cnt\n"
                + "ORDER BY cnt DESC\n"
                + "LIMIT $limit;",
        },
        "post_death_activity": {
            "description": "Find quest activity after a declared death day",
            "params": common_params,
            "cypher": "MATCH (n:NPC {npc_id: $npc_id})-[:HAS_DIALOGUE_STATE]->(life:DialogueState {state_key: 'life_status'})\n"
                + "MATCH (n)-[:HAS_DIALOGUE_STATE]->(death:DialogueState {state_key: 'death_day'})\n"
                + "MATCH (n)-[:HAS_QUEST_STATE]->(qs:QuestState)\n"
                + "WHERE life.state_value = 'dead' AND qs.world_day > toInteger(death.state_value)\n"
                + "RETURN n.npc_id AS npc_id,\n"
                + "       toInteger(death.state_value) AS death_day,\n"
                + "       qs.quest_id AS quest_id,\n"
                + "       qs.state AS quest_state,\n"
                + "       qs.world_day AS world_day\n"
                + "ORDER BY qs.world_day ASC\n"
                + "LIMIT $limit;",
        },
        "memory_recall_candidates": {
            "description": "Top memories for prompt grounding",
            "params": common_params,
            "cypher": "MATCH (n:NPC {npc_id: $npc_id})-[:HAS_MEMORY]->(m:Memory)\n"
                + "RETURN m.memory_id AS memory_id,\n"
                + "       m.summary AS summary,\n"
                + "       m.world_day AS world_day,\n"
                + "       m.importance AS importance,\n"
                + "       m.confidence AS confidence\n"
                + "ORDER BY coalesce(m.importance, 0.0) DESC, coalesce(m.world_day, -1) DESC\n"
                + "LIMIT $limit;",
        },
        "truths_for_subject": {
            "description": "Inspect canonical truth claims for an entity (subject)",
            "params": {
                "subject_id": "<subject_id>",
                "world_day": resolved_day,
                "limit": resolved_limit,
            },
            "cypher": "MATCH (t:Truth {subject_id: $subject_id})\n"
                + "WHERE coalesce(t.world_day, -1) <= $world_day OR t.world_day = -1\n"
                + "RETURN t.claim_key AS claim_key,\n"
                + "       t.predicate AS predicate,\n"
                + "       t.object_value AS object_value,\n"
                + "       t.confidence AS confidence,\n"
                + "       t.world_day AS world_day,\n"
                + "       t.updated_at AS updated_at\n"
                + "ORDER BY coalesce(t.world_day, -1) DESC, coalesce(t.updated_at, 0) DESC\n"
                + "LIMIT $limit;",
        },
        "beliefs_for_npc": {
            "description": "Inspect one NPC's beliefs (which may differ from truth)",
            "params": common_params,
            "cypher": "MATCH (n:NPC {npc_id: $npc_id})-[:HAS_BELIEF]->(b:Belief)\n"
                + "WHERE coalesce(b.world_day, -1) <= $world_day OR b.world_day = -1\n"
                + "RETURN b.claim_key AS claim_key,\n"
                + "       b.subject_id AS subject_id,\n"
                + "       b.predicate AS predicate,\n"
                + "       b.object_value AS object_value,\n"
                + "       b.confidence AS confidence,\n"
                + "       b.world_day AS world_day,\n"
                + "       b.updated_at AS updated_at\n"
                + "ORDER BY coalesce(b.world_day, -1) DESC, coalesce(b.updated_at, 0) DESC\n"
                + "LIMIT $limit;",
        },
        "belief_truth_conflicts": {
            "description": "Find where an NPC belief value conflicts with canonical truth for the same claim key",
            "params": common_params,
            "cypher": "MATCH (n:NPC {npc_id: $npc_id})-[:HAS_BELIEF]->(b:Belief)\n"
                + "MATCH (t:Truth {claim_key: b.claim_key})\n"
                + "WHERE (coalesce(b.world_day, -1) <= $world_day OR b.world_day = -1)\n"
                + "  AND (coalesce(t.world_day, -1) <= $world_day OR t.world_day = -1)\n"
                + "  AND coalesce(b.object_norm, toString(b.object_value)) <> coalesce(t.object_norm, toString(t.object_value))\n"
                + "RETURN b.claim_key AS claim_key,\n"
                + "       b.subject_id AS subject_id,\n"
                + "       b.predicate AS predicate,\n"
                + "       b.object_value AS believed_value,\n"
                + "       t.object_value AS true_value,\n"
                + "       b.confidence AS belief_confidence,\n"
                + "       t.confidence AS truth_confidence,\n"
                + "       b.world_day AS belief_day,\n"
                + "       t.world_day AS truth_day\n"
                + "ORDER BY coalesce(b.confidence, 0.0) DESC\n"
                + "LIMIT $limit;",
        },
    }

    return _ok({
        "version": CYPHER_PLAYBOOK_VERSION,
        "params": common_params,
        "queries": queries,
    })

func clear_backstory_space() -> void:
    if not _ensure_graph():
        return
    for space in [NPC_SPACE, FACTION_SPACE, PLACE_SPACE, QUEST_SPACE, EVENT_SPACE, MEMORY_SPACE, QUEST_STATE_SPACE, DIALOGUE_STATE_SPACE, WORLD_TIME_SPACE, RELATIONSHIP_PROFILE_SPACE, RELATIONSHIP_EVENT_SPACE, TRUTH_SPACE, BELIEF_SPACE]:
        var rows = _graph.list_nodes(space, 65536, 0)
        for row in rows:
            _graph.remove_node(int(row.get("id", -1)))

func _upsert_basic_entity(space: String, entity_type: String, entity_id: String, name: String, metadata: Dictionary = {}) -> Dictionary:
    if entity_id.strip_edges() == "":
        return _error("invalid_id", "%s id must be non-empty" % entity_type)
    if name.strip_edges() == "":
        return _error("invalid_name", "%s name must be non-empty" % entity_type)
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")
    var payload = {
        "type": entity_type,
        "id": entity_id,
        "name": name,
        "metadata": metadata.duplicate(true),
        "updated_at": _timestamp(),
    }
    var node_id = _graph.upsert_node(space, "%s:%s" % [entity_type, entity_id], payload)
    if node_id == -1:
        return _error("upsert_failed", "Failed to upsert %s" % entity_type, {"id": entity_id})
    return _ok({
        "node_id": node_id,
        "id": entity_id,
    })

func _ensure_graph() -> bool:
    if _graph:
        return true
    if not ExtensionLoader.ensure_initialized():
        push_error("NetworkGraph extension init failed: %s" % ExtensionLoader.get_error())
        return false
    if not ClassDB.class_exists("NetworkGraph"):
        push_error("NetworkGraph class missing after extension init")
        return false
    _graph = ClassDB.instantiate("NetworkGraph")
    if _graph == null:
        push_error("Failed to instantiate NetworkGraph")
        return false
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STORE_DIR))
    var resolved_path = _resolved_database_path()
    if not _graph.open(ProjectSettings.globalize_path(resolved_path)):
        push_error("Failed to open network graph database for backstory service")
        _graph = null
        return false
    return true

func _index_memory_embedding_node(node_id: int, memory_id: String, npc_id: String, summary: String, embed_options: Dictionary) -> Dictionary:
    if summary.strip_edges() == "":
        return {"ok": false, "error": "empty_memory_summary"}
    var runtime := _agent_runtime()
    if runtime == null or not runtime.has_method("embed_text"):
        return {"ok": false, "error": "runtime_unavailable"}

    var vector: PackedFloat32Array = runtime.call("embed_text", summary, embed_options)
    if vector.is_empty():
        return {"ok": false, "error": "embedding_failed"}

    var embedding_model := String(embed_options.get("server_model", embed_options.get("model", ""))).strip_edges()
    if embedding_model == "" and runtime.has_method("get_default_model_path"):
        var model_path := String(runtime.call("get_default_model_path")).strip_edges()
        if model_path != "":
            embedding_model = model_path.get_file()
    if embedding_model == "":
        embedding_model = "unknown"

    var embedding_id := int(_graph.add_embedding(node_id, vector, {
        "type": "memory",
        "memory_id": memory_id,
        "npc_id": npc_id,
        "source": "backstory_memory",
        "strategy_hint": "cosine",
        "embedding_model": embedding_model,
    }))
    if embedding_id == -1:
        return {"ok": false, "error": "embedding_store_failed"}
    return {
        "ok": true,
        "embedding_id": embedding_id,
    }

func _resolved_database_path() -> String:
    if _database_path_override != "":
        return _database_path_override
    return DB_PATH

func _node_by_external_id(space: String, key: String, value: Variant) -> Dictionary:
    if not _ensure_graph():
        return {}
    var rows = _graph.list_nodes_by_metadata(space, key, value, 1, 0)
    if rows.is_empty():
        return {}
    return rows[0]

func _node_id_by_external_id(space: String, key: String, value: Variant) -> int:
    var row = _node_by_external_id(space, key, value)
    return int(row.get("id", -1))

func _nodes_for_npc(space: String, npc_id: String, world_day: int, limit: int) -> Array:
    var rows = _graph.list_nodes_by_metadata(space, "npc_id", npc_id, limit * 4, 0)
    var items: Array = []
    for row in rows:
        var data: Dictionary = row.get("data", {})
        var row_day = int(data.get("world_day", -1))
        if world_day >= 0 and row_day >= 0 and row_day > world_day:
            continue
        items.append(data.duplicate(true))
    items.sort_custom(func(a, b): return int(a.get("world_day", -1)) > int(b.get("world_day", -1)))
    if items.size() > limit:
        items.resize(limit)
    return items

func _active_relationships_for_npc(npc_node_id: int, world_day: int, limit: int) -> Array:
    var edges = _graph.get_edges(npc_node_id, DEFAULT_SCAN_LIMIT)
    var relationships: Array = []
    for edge in edges:
        if int(edge.get("source_id", -1)) != npc_node_id:
            continue
        var data: Dictionary = edge.get("data", {})
        if data.get("type", "") != "relationship":
            continue
        var from_day = int(data.get("from_day", -1))
        var to_day = int(data.get("to_day", -1))
        if world_day >= 0:
            if from_day >= 0 and from_day > world_day:
                continue
            if to_day >= 0 and to_day < world_day:
                continue
        relationships.append({
            "relationship_type": String(data.get("relationship_type", edge.get("kind", ""))),
            "target_id": String(data.get("target_id", "")),
            "target_space": String(data.get("target_space", "")),
            "from_day": from_day,
            "to_day": to_day,
            "confidence": float(data.get("confidence", edge.get("weight", 0.0))),
            "source": String(data.get("source", "")),
            "exclusive": bool(data.get("exclusive", false)),
            "metadata": data.get("metadata", {}).duplicate(true),
        })
    relationships.sort_custom(func(a, b): return int(a.get("from_day", -1)) > int(b.get("from_day", -1)))
    if relationships.size() > limit:
        relationships.resize(limit)
    return relationships

func _active_exclusive_memberships(npc_node_id: int) -> Array:
    var edges = _graph.get_edges(npc_node_id, DEFAULT_SCAN_LIMIT)
    var active: Array = []
    for edge in edges:
        if int(edge.get("source_id", -1)) != npc_node_id:
            continue
        var kind = String(edge.get("kind", ""))
        if kind != "MEMBER_OF":
            continue
        var data: Dictionary = edge.get("data", {})
        if not bool(data.get("exclusive", false)):
            continue
        if int(data.get("to_day", -1)) != -1:
            continue
        active.append({
            "target_id": String(data.get("target_id", "")),
            "target_space": String(data.get("target_space", "")),
            "kind": kind,
            "from_day": int(data.get("from_day", -1)),
        })
    return active

func _recent_relationship_stats(source_npc_id: String, target_npc_id: String, world_day: int, recent_window_days: int, recent_limit: int) -> Dictionary:
    var rows = _graph.list_nodes_by_metadata(RELATIONSHIP_EVENT_SPACE, "relationship_key", _relationship_key(source_npc_id, target_npc_id), DEFAULT_SCAN_LIMIT, 0)
    var window_start = world_day - recent_window_days
    var selected: Array = []
    for row in rows:
        var data: Dictionary = row.get("data", {})
        var row_day = int(data.get("world_day", -1))
        if row_day < 0:
            continue
        if row_day < window_start or row_day > world_day:
            continue
        selected.append(data.duplicate(true))

    selected.sort_custom(func(a, b): return int(a.get("world_day", -1)) > int(b.get("world_day", -1)))
    if selected.size() > recent_limit:
        selected.resize(recent_limit)

    var valence_sum = 0.0
    var trust_sum = 0.0
    var respect_sum = 0.0
    for item in selected:
        valence_sum += float(item.get("valence_delta", 0.0))
        trust_sum += float(item.get("trust_delta", 0.0))
        respect_sum += float(item.get("respect_delta", 0.0))

    var count = selected.size()
    var valence_avg = 0.0
    var trust_avg = 0.0
    var respect_avg = 0.0
    if count > 0:
        valence_avg = valence_sum / float(count)
        trust_avg = trust_sum / float(count)
        respect_avg = respect_sum / float(count)

    return {
        "window_days": recent_window_days,
        "sample_count": count,
        "valence_sum": clampf(valence_sum, -100.0, 100.0),
        "trust_sum": clampf(trust_sum, -100.0, 100.0),
        "respect_sum": clampf(respect_sum, -100.0, 100.0),
        "valence_avg": clampf(valence_avg, -1.0, 1.0),
        "trust_avg": clampf(trust_avg, -1.0, 1.0),
        "respect_avg": clampf(respect_avg, -1.0, 1.0),
        "events": selected,
    }

func _recompute_long_term_from_recent(source_npc_id: String, target_npc_id: String, world_day: int, recent_window_days: int = 14, recent_weight: float = 0.85) -> Dictionary:
    var upsert = update_relationship_profile(source_npc_id, target_npc_id, world_day, {}, {})
    if not upsert.get("ok", false):
        return upsert

    var recent = _recent_relationship_stats(source_npc_id, target_npc_id, world_day, recent_window_days, 128)
    var existing_rows = _graph.list_nodes_by_metadata(RELATIONSHIP_PROFILE_SPACE, "relationship_key", _relationship_key(source_npc_id, target_npc_id), 1, 0)
    if existing_rows.is_empty():
        return _error("profile_missing", "Relationship profile missing during recompute")
    var profile = existing_rows[0]
    var profile_data: Dictionary = profile.get("data", {}).duplicate(true)
    var long_term = _normalize_long_term(profile_data.get("long_term", {}))

    var recent_valence = float(recent.get("valence_avg", 0.0))
    var recent_trust = float(recent.get("trust_avg", 0.0))
    var recent_respect = float(recent.get("respect_avg", 0.0))
    var carry = 1.0 - clampf(recent_weight, 0.0, 1.0)
    long_term["bond"] = clampf(float(long_term.get("bond", 0.0)) * carry + recent_valence * recent_weight, -1.0, 1.0)
    long_term["trust"] = clampf(float(long_term.get("trust", 0.0)) * carry + recent_trust * recent_weight, -1.0, 1.0)
    long_term["respect"] = clampf(float(long_term.get("respect", 0.0)) * carry + recent_respect * recent_weight, -1.0, 1.0)
    long_term["history_weight"] = clampf(1.0 - recent_weight, 0.0, 1.0)

    profile_data["long_term"] = long_term
    profile_data["world_day"] = world_day
    profile_data["updated_at"] = _timestamp()
    if not _graph.update_node_data(int(profile.get("id", -1)), profile_data):
        return _error("update_failed", "Failed to update relationship profile long-term values")
    return _ok({
        "relationship_key": _relationship_key(source_npc_id, target_npc_id),
        "long_term": long_term,
        "recent": recent,
    })

func _normalize_long_term(long_term: Dictionary) -> Dictionary:
    return {
        "bond": clampf(float(long_term.get("bond", 0.0)), -1.0, 1.0),
        "trust": clampf(float(long_term.get("trust", 0.0)), -1.0, 1.0),
        "respect": clampf(float(long_term.get("respect", 0.0)), -1.0, 1.0),
        "history_weight": clampf(float(long_term.get("history_weight", 0.5)), 0.0, 1.0),
    }

func _normalize_relationship_tags(tags: Dictionary) -> Dictionary:
    return {
        "friend": bool(tags.get("friend", false)),
        "family": bool(tags.get("family", false)),
        "enemy": bool(tags.get("enemy", false)),
    }

func _relationship_key(source_npc_id: String, target_npc_id: String) -> String:
    return "%s->%s" % [source_npc_id, target_npc_id]

func _claim_key(subject_id: String, predicate: String) -> String:
    return "%s|%s" % [subject_id.strip_edges().to_lower(), predicate.strip_edges().to_lower()]

func _normalize_claim_value(value: Variant) -> String:
    if value == null:
        return "null"
    match typeof(value):
        TYPE_STRING:
            return String(value).strip_edges().to_lower()
        TYPE_BOOL:
            if bool(value):
                return "true"
            return "false"
        TYPE_INT, TYPE_FLOAT:
            return String(value)
        _:
            return JSON.stringify(value, "", false, true).strip_edges().to_lower()

func _latest_truth_for_claim(claim_key: String, world_day: int = -1) -> Dictionary:
    var rows = _graph.list_nodes_by_metadata(TRUTH_SPACE, "claim_key", claim_key, DEFAULT_SCAN_LIMIT, 0)
    var best: Dictionary = {}
    var best_day := -2147483648
    var best_updated := -2147483648
    for row in rows:
        var data: Dictionary = row.get("data", {})
        var row_day = int(data.get("world_day", -1))
        if world_day >= 0 and row_day >= 0 and row_day > world_day:
            continue
        var updated = int(data.get("updated_at", 0))
        if best.is_empty() or row_day > best_day or (row_day == best_day and updated > best_updated):
            best = data.duplicate(true)
            best_day = row_day
            best_updated = updated
    return best

func _resolve_relationship_target(relationship_type: String, target_entity_id: String) -> Dictionary:
    var kind = relationship_type.to_upper()
    if kind == "MEMBER_OF":
        var faction_node_id = _node_id_by_external_id(FACTION_SPACE, "id", target_entity_id)
        if faction_node_id != -1:
            return {"node_id": faction_node_id, "space": FACTION_SPACE}
    var npc_node_id = _node_id_by_external_id(NPC_SPACE, "npc_id", target_entity_id)
    if npc_node_id != -1:
        return {"node_id": npc_node_id, "space": NPC_SPACE}
    var place_node_id = _node_id_by_external_id(PLACE_SPACE, "id", target_entity_id)
    if place_node_id != -1:
        return {"node_id": place_node_id, "space": PLACE_SPACE}
    var quest_node_id = _node_id_by_external_id(QUEST_SPACE, "id", target_entity_id)
    if quest_node_id != -1:
        return {"node_id": quest_node_id, "space": QUEST_SPACE}
    return {"node_id": -1, "space": ""}

func _dialogue_state_value(npc_id: String, state_key: String, fallback: Variant = null) -> Variant:
    var row = _node_by_external_id(DIALOGUE_STATE_SPACE, "state_key", state_key)
    if row.is_empty():
        return fallback
    var data: Dictionary = row.get("data", {})
    if String(data.get("npc_id", "")) != npc_id:
        var rows = _graph.list_nodes_by_metadata(DIALOGUE_STATE_SPACE, "npc_id", npc_id, 512, 0)
        for item in rows:
            var item_data: Dictionary = item.get("data", {})
            if String(item_data.get("state_key", "")) == state_key:
                return item_data.get("state_value", fallback)
        return fallback
    return data.get("state_value", fallback)

func _post_day_nodes(space: String, npc_id: String, day: int) -> Array:
    var rows = _graph.list_nodes_by_metadata(space, "npc_id", npc_id, 512, 0)
    var result: Array = []
    for row in rows:
        var data: Dictionary = row.get("data", {})
        if int(data.get("world_day", -1)) > day:
            result.append(data.duplicate(true))
    return result

func _npc_label(npc_id: String) -> String:
    return "npc:%s" % npc_id

func _event_label(event_id: String) -> String:
    return "event:%s" % event_id

func _memory_label(memory_id: String) -> String:
    return "memory:%s" % memory_id

func _quest_state_label(npc_id: String, quest_id: String, world_day: int, state: String) -> String:
    return "quest_state:%s:%s:%d:%s" % [npc_id, quest_id, world_day, state]

func _dialogue_state_label(npc_id: String, state_key: String) -> String:
    return "dialogue_state:%s:%s" % [npc_id, state_key]

func _truth_label(truth_id: String) -> String:
    return "truth:%s" % truth_id

func _belief_label(belief_id: String) -> String:
    return "belief:%s" % belief_id

func _world_time_label(day: int) -> String:
    return "world_time:%d" % day

func _relationship_profile_label(source_npc_id: String, target_npc_id: String) -> String:
    return "relationship_profile:%s:%s" % [source_npc_id, target_npc_id]

func _relationship_event_label(source_npc_id: String, target_npc_id: String, world_day: int) -> String:
    return "relationship_event:%s:%s:%d:%d" % [source_npc_id, target_npc_id, world_day, _timestamp()]

func _ok(data: Dictionary = {}) -> Dictionary:
    var out = {
        "ok": true,
    }
    for key in data.keys():
        out[key] = data[key]
    return out

func _error(code: String, message: String, details: Dictionary = {}) -> Dictionary:
    return {
        "ok": false,
        "error": {
            "code": code,
            "message": message,
            "details": details.duplicate(true),
        },
    }

func _timestamp() -> int:
    return int(Time.get_unix_time_from_system())

func _agent_runtime() -> Object:
    if not Engine.has_singleton("AgentRuntime"):
        return null
    return Engine.get_singleton("AgentRuntime")
