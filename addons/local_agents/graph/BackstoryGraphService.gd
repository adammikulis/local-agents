@tool
extends Node
class_name LocalAgentsBackstoryGraphService

const ExtensionLoader = preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const RuntimePaths = preload("res://addons/local_agents/runtime/RuntimePaths.gd")
const LlamaServerManager = preload("res://addons/local_agents/runtime/LlamaServerManager.gd")
const BackstoryCypherPlaybookScript = preload("res://addons/local_agents/graph/BackstoryCypherPlaybook.gd")
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
const ORAL_KNOWLEDGE_SPACE = "oral_knowledge"
const RITUAL_EVENT_SPACE = "ritual_event"
const SACRED_SITE_SPACE = "sacred_site"

const DEFAULT_SCAN_LIMIT = 4096
const CYPHER_PLAYBOOK_VERSION = "backstory_cypher_playbook_v2"

var _graph: Object = null
var _database_path_override: String = ""
var _embedding_options: Dictionary = {
    "backend": "llama_server",
    "normalize": true,
    "server_embeddings": true,
    "server_pooling": "mean",
    "server_autostart": true,
    "server_shutdown_on_exit": false,
    "server_start_timeout_ms": 45000,
    "server_ready_timeout_ms": 2500,
}
var _embedding_server_manager = LlamaServerManager.new()

func _ready() -> void:
    _ensure_graph()

func _exit_tree() -> void:
    if bool(_embedding_options.get("server_shutdown_on_exit", false)):
        _embedding_server_manager.stop_managed()

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

func record_oral_knowledge(knowledge_id: String, npc_id: String, category: String, content: String, confidence: float = 0.8, motifs: Array = [], world_day: int = -1, metadata: Dictionary = {}) -> Dictionary:
    if npc_id.strip_edges() == "":
        return _error("invalid_npc_id", "npc_id must be non-empty")
    if category.strip_edges() == "":
        return _error("invalid_category", "category must be non-empty")
    if content.strip_edges() == "":
        return _error("invalid_content", "content must be non-empty")
    if confidence < 0.0 or confidence > 1.0:
        return _error("invalid_confidence", "confidence must be between 0 and 1")
    if world_day < -1:
        return _error("invalid_world_day", "world_day must be >= -1")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")

    var npc_node_id = _node_id_by_external_id(NPC_SPACE, "npc_id", npc_id)
    if npc_node_id == -1:
        return _error("missing_npc", "NPC must exist before writing oral knowledge", {"npc_id": npc_id})

    var resolved_id = knowledge_id.strip_edges()
    if resolved_id == "":
        resolved_id = _oral_knowledge_seed_id(npc_id, category, world_day)

    var payload = {
        "type": "oral_knowledge",
        "knowledge_id": resolved_id,
        "npc_id": npc_id,
        "category": category,
        "content": content,
        "confidence": confidence,
        "motifs": motifs.duplicate(true),
        "world_day": world_day,
        "metadata": metadata.duplicate(true),
        "updated_at": _timestamp(),
    }
    var node_id = _graph.upsert_node(ORAL_KNOWLEDGE_SPACE, _oral_knowledge_label(resolved_id), payload)
    if node_id == -1:
        return _error("upsert_failed", "Failed to upsert oral knowledge", {"knowledge_id": resolved_id})

    _graph.add_edge(npc_node_id, node_id, "HAS_ORAL_KNOWLEDGE", confidence, {
        "type": "oral_knowledge_ref",
        "npc_id": npc_id,
        "knowledge_id": resolved_id,
        "world_day": world_day,
        "confidence": confidence,
    })

    return _ok({
        "node_id": node_id,
        "knowledge_id": resolved_id,
    })

func link_oral_knowledge_lineage(source_knowledge_id: String, derived_knowledge_id: String, speaker_npc_id: String = "", listener_npc_id: String = "", transmission_hops: int = 1, world_day: int = -1) -> Dictionary:
    if source_knowledge_id.strip_edges() == "" or derived_knowledge_id.strip_edges() == "":
        return _error("invalid_knowledge_id", "knowledge ids must be non-empty")
    if transmission_hops < 1:
        return _error("invalid_transmission_hops", "transmission_hops must be >= 1")
    if world_day < -1:
        return _error("invalid_world_day", "world_day must be >= -1")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")

    var source_node_id = _node_id_by_external_id(ORAL_KNOWLEDGE_SPACE, "knowledge_id", source_knowledge_id)
    var derived_node_id = _node_id_by_external_id(ORAL_KNOWLEDGE_SPACE, "knowledge_id", derived_knowledge_id)
    if source_node_id == -1 or derived_node_id == -1:
        return _error("missing_knowledge", "Both knowledge nodes must exist", {
            "source": source_knowledge_id,
            "derived": derived_knowledge_id,
        })

    if _lineage_edge_exists(derived_node_id, source_node_id):
        return _ok({
            "source_knowledge_id": source_knowledge_id,
            "derived_knowledge_id": derived_knowledge_id,
            "lineage_exists": true,
        })
    var edge_id = _graph.add_edge(derived_node_id, source_node_id, "DERIVES_FROM", 1.0, {
        "type": "knowledge_lineage",
        "source_knowledge_id": source_knowledge_id,
        "derived_knowledge_id": derived_knowledge_id,
        "speaker_npc_id": speaker_npc_id,
        "listener_npc_id": listener_npc_id,
        "transmission_hops": transmission_hops,
        "world_day": world_day,
    })
    if edge_id == -1:
        return _error("edge_failed", "Failed to link knowledge lineage", {
            "source": source_knowledge_id,
            "derived": derived_knowledge_id,
        })
    return _ok({
        "edge_id": edge_id,
        "source_knowledge_id": source_knowledge_id,
        "derived_knowledge_id": derived_knowledge_id,
    })

func get_oral_knowledge_for_npc(npc_id: String, world_day: int = -1, limit: int = 32) -> Dictionary:
    if npc_id.strip_edges() == "":
        return _error("invalid_npc_id", "npc_id must be non-empty")
    if limit <= 0:
        return _error("invalid_limit", "limit must be > 0")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")

    var rows = _graph.list_nodes_by_metadata(ORAL_KNOWLEDGE_SPACE, "npc_id", npc_id, DEFAULT_SCAN_LIMIT, 0)
    var items: Array = []
    for row in rows:
        var data: Dictionary = row.get("data", {})
        var row_day = int(data.get("world_day", -1))
        if world_day >= 0 and row_day >= 0 and row_day > world_day:
            continue
        items.append(data.duplicate(true))
    items.sort_custom(func(a, b):
        var da: int = int(a.get("world_day", -1))
        var db: int = int(b.get("world_day", -1))
        if da == db:
            return int(a.get("updated_at", 0)) > int(b.get("updated_at", 0))
        return da > db
    )
    if items.size() > limit:
        items.resize(limit)
    return _ok({
        "npc_id": npc_id,
        "oral_knowledge": items,
    })

func get_oral_lineage(knowledge_id: String, limit: int = 32) -> Dictionary:
    if knowledge_id.strip_edges() == "":
        return _error("invalid_knowledge_id", "knowledge_id must be non-empty")
    if limit <= 0:
        return _error("invalid_limit", "limit must be > 0")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")

    var node = _node_by_external_id(ORAL_KNOWLEDGE_SPACE, "knowledge_id", knowledge_id)
    if node.is_empty():
        return _error("missing_knowledge", "oral knowledge not found", {"knowledge_id": knowledge_id})
    var node_id = int(node.get("id", -1))
    var edges = _graph.get_edges(node_id, DEFAULT_SCAN_LIMIT)
    var ancestors: Array = []
    for edge in edges:
        if String(edge.get("kind", "")) != "DERIVES_FROM":
            continue
        var target_id = int(edge.get("target_id", -1))
        if target_id == -1:
            continue
        var target_node = _graph.get_node(target_id)
        if target_node.is_empty():
            continue
        ancestors.append({
            "knowledge": target_node.get("data", {}).duplicate(true),
            "edge": edge.get("data", {}).duplicate(true),
        })
    ancestors.sort_custom(func(a, b):
        return int(a.get("knowledge", {}).get("world_day", -1)) > int(b.get("knowledge", {}).get("world_day", -1))
    )
    if ancestors.size() > limit:
        ancestors.resize(limit)
    return _ok({
        "knowledge_id": knowledge_id,
        "lineage": ancestors,
    })

func upsert_sacred_site(site_id: String, site_type: String, position: Dictionary = {}, radius: float = 1.0, taboo_ids: Array = [], world_day: int = -1, metadata: Dictionary = {}) -> Dictionary:
    if site_id.strip_edges() == "":
        return _error("invalid_site_id", "site_id must be non-empty")
    if site_type.strip_edges() == "":
        return _error("invalid_site_type", "site_type must be non-empty")
    if radius <= 0.0:
        return _error("invalid_radius", "radius must be > 0")
    if world_day < -1:
        return _error("invalid_world_day", "world_day must be >= -1")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")

    var payload = {
        "type": "sacred_site",
        "site_id": site_id,
        "site_type": site_type,
        "position": position.duplicate(true),
        "radius": radius,
        "taboo_ids": taboo_ids.duplicate(true),
        "world_day": world_day,
        "metadata": metadata.duplicate(true),
        "updated_at": _timestamp(),
    }
    var node_id = _graph.upsert_node(SACRED_SITE_SPACE, _sacred_site_label(site_id), payload)
    if node_id == -1:
        return _error("upsert_failed", "Failed to upsert sacred site", {"site_id": site_id})
    return _ok({
        "node_id": node_id,
        "site_id": site_id,
    })

func get_sacred_site(site_id: String) -> Dictionary:
    if site_id.strip_edges() == "":
        return _error("invalid_site_id", "site_id must be non-empty")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")
    var rows = _graph.list_nodes_by_metadata(SACRED_SITE_SPACE, "site_id", site_id, 1, 0)
    if rows.is_empty():
        return _error("missing_site", "sacred site not found", {"site_id": site_id})
    return _ok({
        "site": rows[0].get("data", {}).duplicate(true),
    })

func record_ritual_event(ritual_id: String, site_id: String, world_day: int, participants: Array, effects: Dictionary = {}, metadata: Dictionary = {}) -> Dictionary:
    if ritual_id.strip_edges() == "":
        return _error("invalid_ritual_id", "ritual_id must be non-empty")
    if site_id.strip_edges() == "":
        return _error("invalid_site_id", "site_id must be non-empty")
    if world_day < 0:
        return _error("invalid_world_day", "world_day must be >= 0")
    if participants.is_empty():
        return _error("invalid_participants", "Participants array must be non-empty")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")

    var payload = {
        "type": "ritual_event",
        "ritual_id": ritual_id,
        "site_id": site_id,
        "world_day": world_day,
        "participants": participants.duplicate(true),
        "effects": effects.duplicate(true),
        "metadata": metadata.duplicate(true),
        "updated_at": _timestamp(),
    }
    var node_id = _graph.upsert_node(RITUAL_EVENT_SPACE, _ritual_event_label(ritual_id), payload)
    if node_id == -1:
        return _error("upsert_failed", "Failed to upsert ritual_event", {"ritual_id": ritual_id})

    var site_node_id = _node_id_by_external_id(SACRED_SITE_SPACE, "site_id", site_id)
    if site_node_id != -1:
        _graph.add_edge(node_id, site_node_id, "AT_SITE", 1.0, {
            "type": "ritual_site_ref",
            "ritual_id": ritual_id,
            "site_id": site_id,
        })

    for participant in participants:
        var npc_id = String(participant)
        var npc_node_id = _node_id_by_external_id(NPC_SPACE, "npc_id", npc_id)
        if npc_node_id == -1:
            continue
        _graph.add_edge(npc_node_id, node_id, "PARTICIPATED_IN", 1.0, {
            "type": "participation",
            "npc_id": npc_id,
            "ritual_id": ritual_id,
            "world_day": world_day,
        })

    return _ok({
        "node_id": node_id,
        "ritual_id": ritual_id,
    })

func get_ritual_history_for_site(site_id: String, world_day: int = -1, limit: int = 32) -> Dictionary:
    if site_id.strip_edges() == "":
        return _error("invalid_site_id", "site_id must be non-empty")
    if limit <= 0:
        return _error("invalid_limit", "limit must be > 0")
    if not _ensure_graph():
        return _error("graph_unavailable", "NetworkGraph extension unavailable")

    var rows = _graph.list_nodes_by_metadata(RITUAL_EVENT_SPACE, "site_id", site_id, DEFAULT_SCAN_LIMIT, 0)
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
        "site_id": site_id,
        "ritual_events": items,
    })

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
    var backend_ready = _ensure_embedding_backend_ready(embed_options, runtime)
    if not bool(backend_ready.get("ok", false)):
        return _error("embedding_backend_unavailable", "embedding backend unavailable", backend_ready)
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
    var playbook: Dictionary = BackstoryCypherPlaybookScript.build_playbook(resolved_npc_id, resolved_day, resolved_limit, CYPHER_PLAYBOOK_VERSION)
    return _ok(playbook)

func clear_backstory_space() -> void:
    if not _ensure_graph():
        return
    for space in [NPC_SPACE, FACTION_SPACE, PLACE_SPACE, QUEST_SPACE, EVENT_SPACE, MEMORY_SPACE, QUEST_STATE_SPACE, DIALOGUE_STATE_SPACE, WORLD_TIME_SPACE, RELATIONSHIP_PROFILE_SPACE, RELATIONSHIP_EVENT_SPACE, TRUTH_SPACE, BELIEF_SPACE, ORAL_KNOWLEDGE_SPACE, RITUAL_EVENT_SPACE, SACRED_SITE_SPACE]:
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
    var backend_ready = _ensure_embedding_backend_ready(embed_options, runtime)
    if not bool(backend_ready.get("ok", false)):
        return {
            "ok": false,
            "error": "embedding_backend_unavailable",
            "backend": backend_ready,
        }

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

func _ensure_embedding_backend_ready(embed_options: Dictionary, runtime: Object) -> Dictionary:
    var backend = String(embed_options.get("backend", "")).strip_edges().to_lower()
    if backend == "" or backend == "local":
        return {"ok": true, "backend": backend}
    if backend != "llama_server":
        return {"ok": true, "backend": backend}
    if not bool(embed_options.get("server_autostart", true)):
        return {"ok": true, "backend": backend}

    var resolved_model = _resolve_embedding_model_path(embed_options, runtime)
    if resolved_model == "":
        return {
            "ok": false,
            "error": "embedding_model_missing",
            "backend": backend,
        }
    var runtime_dir = RuntimePaths.normalize_path(String(embed_options.get("runtime_directory", "")))
    var lifecycle = _embedding_server_manager.ensure_running(embed_options, resolved_model, runtime_dir)
    if not bool(lifecycle.get("ok", false)):
        return {
            "ok": false,
            "error": "embedding_server_unavailable",
            "backend": backend,
            "lifecycle": lifecycle,
        }
    return {
        "ok": true,
        "backend": backend,
        "base_url": lifecycle.get("base_url", ""),
        "model_path": resolved_model,
    }

func _resolve_embedding_model_path(embed_options: Dictionary, runtime: Object) -> String:
    var explicit_keys = ["server_model_path", "model_path", "model"]
    for key in explicit_keys:
        var candidate = String(embed_options.get(key, "")).strip_edges()
        if candidate == "":
            continue
        var normalized = RuntimePaths.normalize_path(candidate)
        if normalized != "" and FileAccess.file_exists(normalized):
            return normalized
    if runtime != null and runtime.has_method("get_default_model_path"):
        var runtime_default = String(runtime.call("get_default_model_path")).strip_edges()
        var normalized_runtime_default = RuntimePaths.normalize_path(runtime_default)
        if normalized_runtime_default != "" and FileAccess.file_exists(normalized_runtime_default):
            return normalized_runtime_default
    var fallback = RuntimePaths.resolve_default_model()
    if fallback != "" and FileAccess.file_exists(fallback):
        return fallback
    return ""

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

func _oral_knowledge_seed_id(npc_id: String, category: String, world_day: int) -> String:
    return "%s:%s:%d" % [npc_id, category.strip_edges().to_lower(), max(0, world_day)]

func _lineage_edge_exists(source_node_id: int, target_node_id: int) -> bool:
    var edges = _graph.get_edges(source_node_id, DEFAULT_SCAN_LIMIT)
    for edge in edges:
        if int(edge.get("target_id", -1)) != target_node_id:
            continue
        if String(edge.get("kind", "")) != "DERIVES_FROM":
            continue
        return true
    return false

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

func _oral_knowledge_label(knowledge_id: String) -> String:
    return "oral_knowledge:%s" % knowledge_id

func _sacred_site_label(site_id: String) -> String:
    return "sacred_site:%s" % site_id

func _ritual_event_label(ritual_id: String) -> String:
    return "ritual_event:%s" % ritual_id

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
