@tool
extends Node
class_name LocalAgentsBackstoryGraphService

const ExtensionLoader = preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const RuntimePaths = preload("res://addons/local_agents/runtime/RuntimePaths.gd")
const LlamaServerManager = preload("res://addons/local_agents/runtime/LlamaServerManager.gd")
const BackstoryCypherPlaybookScript = preload("res://addons/local_agents/graph/BackstoryCypherPlaybook.gd")
const BackstoryRelationshipOpsScript = preload("res://addons/local_agents/graph/BackstoryRelationshipOps.gd")
const BackstoryKnowledgeOpsScript = preload("res://addons/local_agents/graph/BackstoryKnowledgeOps.gd")
const BackstoryMemoryStateOpsScript = preload("res://addons/local_agents/graph/BackstoryMemoryStateOps.gd")
const BackstoryEmbeddingOpsScript = preload("res://addons/local_agents/graph/BackstoryEmbeddingOps.gd")
const BackstoryGraphQueryOpsScript = preload("res://addons/local_agents/graph/BackstoryGraphQueryOps.gd")
const BackstoryRelationshipStateOpsScript = preload("res://addons/local_agents/graph/BackstoryRelationshipStateOps.gd")
const BackstoryClaimOpsScript = preload("res://addons/local_agents/graph/BackstoryClaimOps.gd")
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
    return BackstoryRelationshipOpsScript.add_relationship(self, source_npc_id, target_entity_id, relationship_type, from_day, to_day, confidence, source, exclusive, metadata)

func update_relationship_profile(source_npc_id: String, target_npc_id: String, world_day: int, tags: Dictionary = {}, metadata: Dictionary = {}) -> Dictionary:
    return BackstoryRelationshipOpsScript.update_relationship_profile(self, source_npc_id, target_npc_id, world_day, tags, metadata)

func record_relationship_interaction(source_npc_id: String, target_npc_id: String, world_day: int, valence_delta: float, trust_delta: float = 0.0, respect_delta: float = 0.0, summary: String = "", metadata: Dictionary = {}) -> Dictionary:
    return BackstoryRelationshipOpsScript.record_relationship_interaction(self, source_npc_id, target_npc_id, world_day, valence_delta, trust_delta, respect_delta, summary, metadata)

func get_relationship_state(source_npc_id: String, target_npc_id: String, world_day: int, recent_window_days: int = 14, recent_limit: int = 64) -> Dictionary:
    return BackstoryRelationshipOpsScript.get_relationship_state(self, source_npc_id, target_npc_id, world_day, recent_window_days, recent_limit)

func get_relationships_for_npc(npc_id: String, world_day: int, recent_window_days: int = 14, recent_limit: int = 64) -> Dictionary:
    return BackstoryRelationshipOpsScript.get_relationships_for_npc(self, npc_id, world_day, recent_window_days, recent_limit)

func record_event(event_id: String, event_type: String, summary: String, world_day: int, place_id: String = "", participant_npc_ids: Array = [], metadata: Dictionary = {}) -> Dictionary:
    return BackstoryMemoryStateOpsScript.record_event(self, event_id, event_type, summary, world_day, place_id, participant_npc_ids, metadata)

func add_memory(memory_id: String, npc_id: String, summary: String, conversation_id: int = -1, message_id: int = -1, world_day: int = -1, importance: float = 0.5, confidence: float = 1.0, tags: Array = [], metadata: Dictionary = {}) -> Dictionary:
    return BackstoryMemoryStateOpsScript.add_memory(self, memory_id, npc_id, summary, conversation_id, message_id, world_day, importance, confidence, tags, metadata)

func add_dream_memory(memory_id: String, npc_id: String, summary: String, world_day: int, influence: Dictionary = {}, importance: float = 0.5, confidence: float = 0.8, metadata: Dictionary = {}) -> Dictionary:
    return BackstoryMemoryStateOpsScript.add_dream_memory(self, memory_id, npc_id, summary, world_day, influence, importance, confidence, metadata)

func record_oral_knowledge(knowledge_id: String, npc_id: String, category: String, content: String, confidence: float = 0.8, motifs: Array = [], world_day: int = -1, metadata: Dictionary = {}) -> Dictionary:
    return BackstoryKnowledgeOpsScript.record_oral_knowledge(self, knowledge_id, npc_id, category, content, confidence, motifs, world_day, metadata)

func link_oral_knowledge_lineage(source_knowledge_id: String, derived_knowledge_id: String, speaker_npc_id: String = "", listener_npc_id: String = "", transmission_hops: int = 1, world_day: int = -1) -> Dictionary:
    return BackstoryKnowledgeOpsScript.link_oral_knowledge_lineage(self, source_knowledge_id, derived_knowledge_id, speaker_npc_id, listener_npc_id, transmission_hops, world_day)

func get_oral_knowledge_for_npc(npc_id: String, world_day: int = -1, limit: int = 32) -> Dictionary:
    return BackstoryKnowledgeOpsScript.get_oral_knowledge_for_npc(self, npc_id, world_day, limit)

func get_oral_lineage(knowledge_id: String, limit: int = 32) -> Dictionary:
    return BackstoryKnowledgeOpsScript.get_oral_lineage(self, knowledge_id, limit)

func upsert_sacred_site(site_id: String, site_type: String, position: Dictionary = {}, radius: float = 1.0, taboo_ids: Array = [], world_day: int = -1, metadata: Dictionary = {}) -> Dictionary:
    return BackstoryKnowledgeOpsScript.upsert_sacred_site(self, site_id, site_type, position, radius, taboo_ids, world_day, metadata)

func get_sacred_site(site_id: String) -> Dictionary:
    return BackstoryKnowledgeOpsScript.get_sacred_site(self, site_id)

func record_ritual_event(ritual_id: String, site_id: String, world_day: int, participants: Array, effects: Dictionary = {}, metadata: Dictionary = {}) -> Dictionary:
    return BackstoryKnowledgeOpsScript.record_ritual_event(self, ritual_id, site_id, world_day, participants, effects, metadata)

func get_ritual_history_for_site(site_id: String, world_day: int = -1, limit: int = 32) -> Dictionary:
    return BackstoryKnowledgeOpsScript.get_ritual_history_for_site(self, site_id, world_day, limit)

func add_thought_memory(memory_id: String, npc_id: String, summary: String, world_day: int, source_refs: Array = [], importance: float = 0.45, confidence: float = 0.7, metadata: Dictionary = {}) -> Dictionary:
    return BackstoryMemoryStateOpsScript.add_thought_memory(self, memory_id, npc_id, summary, world_day, source_refs, importance, confidence, metadata)

func upsert_world_truth(truth_id: String, subject_id: String, predicate: String, object_value: Variant, world_day: int = -1, confidence: float = 1.0, metadata: Dictionary = {}) -> Dictionary:
    return BackstoryKnowledgeOpsScript.upsert_world_truth(self, truth_id, subject_id, predicate, object_value, world_day, confidence, metadata)

func upsert_npc_belief(belief_id: String, npc_id: String, subject_id: String, predicate: String, object_value: Variant, world_day: int = -1, confidence: float = 0.7, metadata: Dictionary = {}) -> Dictionary:
    return BackstoryKnowledgeOpsScript.upsert_npc_belief(self, belief_id, npc_id, subject_id, predicate, object_value, world_day, confidence, metadata)

func get_truths_for_subject(subject_id: String, world_day: int = -1, limit: int = 32) -> Dictionary:
    return BackstoryKnowledgeOpsScript.get_truths_for_subject(self, subject_id, world_day, limit)

func get_beliefs_for_npc(npc_id: String, world_day: int = -1, limit: int = 32) -> Dictionary:
    return BackstoryKnowledgeOpsScript.get_beliefs_for_npc(self, npc_id, world_day, limit)

func get_belief_truth_conflicts(npc_id: String, world_day: int = -1, limit: int = 32) -> Dictionary:
    return BackstoryKnowledgeOpsScript.get_belief_truth_conflicts(self, npc_id, world_day, limit)

func update_quest_state(npc_id: String, quest_id: String, state: String, world_day: int, is_active: bool = true, metadata: Dictionary = {}) -> Dictionary:
    return BackstoryMemoryStateOpsScript.update_quest_state(self, npc_id, quest_id, state, world_day, is_active, metadata)

func update_dialogue_state(npc_id: String, state_key: String, state_value: Variant, world_day: int = -1, conversation_id: int = -1, metadata: Dictionary = {}) -> Dictionary:
    return BackstoryMemoryStateOpsScript.update_dialogue_state(self, npc_id, state_key, state_value, world_day, conversation_id, metadata)

func ingest_conversation_message_as_memory(npc_id: String, message: Dictionary, memory_id: String = "", world_day: int = -1, importance: float = 0.5, confidence: float = 0.8) -> Dictionary:
    return BackstoryMemoryStateOpsScript.ingest_conversation_message_as_memory(self, npc_id, message, memory_id, world_day, importance, confidence)

func get_backstory_context(npc_id: String, world_day: int = -1, limit: int = 32) -> Dictionary:
    return BackstoryMemoryStateOpsScript.get_backstory_context(self, npc_id, world_day, limit)

func get_memory_recall_candidates(npc_id: String, world_day: int = -1, limit: int = 8, include_dreams: bool = true) -> Dictionary:
    return BackstoryMemoryStateOpsScript.get_memory_recall_candidates(self, npc_id, world_day, limit, include_dreams)

func index_memory_embedding(memory_id: String, text: String = "", options: Dictionary = {}) -> Dictionary:
    return BackstoryMemoryStateOpsScript.index_memory_embedding(self, memory_id, text, options)

func search_memory_embeddings(npc_id: String, query: String, top_k: int = 8, expand: int = 32, strategy: String = "cosine", options: Dictionary = {}) -> Dictionary:
    return BackstoryMemoryStateOpsScript.search_memory_embeddings(self, npc_id, query, top_k, expand, strategy, options)

func detect_contradictions(npc_id: String) -> Dictionary:
    return BackstoryMemoryStateOpsScript.detect_contradictions(self, npc_id)

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
    return BackstoryEmbeddingOpsScript.index_memory_embedding_node(self, node_id, memory_id, npc_id, summary, embed_options)

func _resolved_database_path() -> String:
    if _database_path_override != "":
        return _database_path_override
    return DB_PATH

func _ensure_embedding_backend_ready(embed_options: Dictionary, runtime: Object) -> Dictionary:
    return BackstoryEmbeddingOpsScript.ensure_embedding_backend_ready(self, embed_options, runtime)

func _resolve_embedding_model_path(embed_options: Dictionary, runtime: Object) -> String:
    return BackstoryEmbeddingOpsScript.resolve_embedding_model_path(embed_options, runtime)

func _node_by_external_id(space: String, key: String, value: Variant) -> Dictionary:
    return BackstoryGraphQueryOpsScript.node_by_external_id(self, space, key, value)

func _node_id_by_external_id(space: String, key: String, value: Variant) -> int:
    return BackstoryGraphQueryOpsScript.node_id_by_external_id(self, space, key, value)

func _nodes_for_npc(space: String, npc_id: String, world_day: int, limit: int) -> Array:
    return BackstoryGraphQueryOpsScript.nodes_for_npc(self, space, npc_id, world_day, limit)

func _active_relationships_for_npc(npc_node_id: int, world_day: int, limit: int) -> Array:
    return BackstoryGraphQueryOpsScript.active_relationships_for_npc(self, npc_node_id, world_day, limit)

func _active_exclusive_memberships(npc_node_id: int) -> Array:
    return BackstoryGraphQueryOpsScript.active_exclusive_memberships(self, npc_node_id)

func _recent_relationship_stats(source_npc_id: String, target_npc_id: String, world_day: int, recent_window_days: int, recent_limit: int) -> Dictionary:
    return BackstoryRelationshipStateOpsScript.recent_relationship_stats(self, source_npc_id, target_npc_id, world_day, recent_window_days, recent_limit)

func _recompute_long_term_from_recent(source_npc_id: String, target_npc_id: String, world_day: int, recent_window_days: int = 14, recent_weight: float = 0.85) -> Dictionary:
    return BackstoryRelationshipStateOpsScript.recompute_long_term_from_recent(self, source_npc_id, target_npc_id, world_day, recent_window_days, recent_weight)

func _normalize_long_term(long_term: Dictionary) -> Dictionary:
    return BackstoryRelationshipStateOpsScript.normalize_long_term(long_term)

func _normalize_relationship_tags(tags: Dictionary) -> Dictionary:
    return BackstoryRelationshipStateOpsScript.normalize_relationship_tags(tags)

func _relationship_key(source_npc_id: String, target_npc_id: String) -> String:
    return BackstoryRelationshipStateOpsScript.relationship_key(source_npc_id, target_npc_id)

func _claim_key(subject_id: String, predicate: String) -> String:
    return BackstoryClaimOpsScript.claim_key(subject_id, predicate)

func _normalize_claim_value(value: Variant) -> String:
    return BackstoryClaimOpsScript.normalize_claim_value(value)

func _latest_truth_for_claim(claim_key: String, world_day: int = -1) -> Dictionary:
    return BackstoryClaimOpsScript.latest_truth_for_claim(self, claim_key, world_day)

func _resolve_relationship_target(relationship_type: String, target_entity_id: String) -> Dictionary:
    return BackstoryGraphQueryOpsScript.resolve_relationship_target(self, relationship_type, target_entity_id)

func _dialogue_state_value(npc_id: String, state_key: String, fallback: Variant = null) -> Variant:
    return BackstoryGraphQueryOpsScript.dialogue_state_value(self, npc_id, state_key, fallback)

func _post_day_nodes(space: String, npc_id: String, day: int) -> Array:
    return BackstoryGraphQueryOpsScript.post_day_nodes(self, space, npc_id, day)

func _oral_knowledge_seed_id(npc_id: String, category: String, world_day: int) -> String:
    return BackstoryClaimOpsScript.oral_knowledge_seed_id(npc_id, category, world_day)

func _lineage_edge_exists(source_node_id: int, target_node_id: int) -> bool:
    return BackstoryGraphQueryOpsScript.lineage_edge_exists(self, source_node_id, target_node_id)

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
