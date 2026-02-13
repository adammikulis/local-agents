@tool
extends RefCounted
class_name LocalAgentsBackstoryRelationshipOps

static func add_relationship(svc, source_npc_id: String, target_entity_id: String, relationship_type: String, from_day: int, to_day: int, confidence: float, source: String, exclusive: bool, metadata: Dictionary) -> Dictionary:
	if relationship_type.strip_edges() == "":
		return svc._error("invalid_relationship_type", "relationship_type must be non-empty")
	if from_day < 0:
		return svc._error("invalid_from_day", "from_day must be >= 0")
	if to_day >= 0 and to_day < from_day:
		return svc._error("invalid_to_day", "to_day must be >= from_day when provided")
	if confidence < 0.0 or confidence > 1.0:
		return svc._error("invalid_confidence", "confidence must be between 0 and 1")
	var source_node = svc._node_id_by_external_id(svc.NPC_SPACE, "npc_id", source_npc_id)
	var target_info = svc._resolve_relationship_target(relationship_type, target_entity_id)
	var target_node = int(target_info.get("node_id", -1))
	var target_space = String(target_info.get("space", ""))
	if source_node == -1 or target_node == -1:
		return svc._error("missing_node", "Relationship source/target nodes must exist", {"source_npc_id": source_npc_id, "target_entity_id": target_entity_id, "relationship_type": relationship_type})
	var kind = relationship_type.to_upper()
	var edge_id = svc._graph.add_edge(source_node, target_node, kind, confidence, {
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
		return svc._error("edge_failed", "Failed to add relationship", {"relationship_type": kind})
	return svc._ok({"edge_id": edge_id})

static func update_relationship_profile(svc, source_npc_id: String, target_npc_id: String, world_day: int, tags: Dictionary, metadata: Dictionary) -> Dictionary:
	if source_npc_id.strip_edges() == "" or target_npc_id.strip_edges() == "":
		return svc._error("invalid_npc_id", "source_npc_id and target_npc_id must be non-empty")
	if world_day < 0:
		return svc._error("invalid_world_day", "world_day must be >= 0")
	var source_node_id = svc._node_id_by_external_id(svc.NPC_SPACE, "npc_id", source_npc_id)
	var target_node_id = svc._node_id_by_external_id(svc.NPC_SPACE, "npc_id", target_npc_id)
	if source_node_id == -1 or target_node_id == -1:
		return svc._error("missing_npc", "Both NPCs must exist before profile updates", {"source_npc_id": source_npc_id, "target_npc_id": target_npc_id})
	var key = svc._relationship_key(source_npc_id, target_npc_id)
	var existing = svc._graph.list_nodes_by_metadata(svc.RELATIONSHIP_PROFILE_SPACE, "relationship_key", key, 1, 0)
	var existing_data: Dictionary = {}
	if not existing.is_empty():
		existing_data = existing[0].get("data", {}).duplicate(true)
	var normalized_tags = svc._normalize_relationship_tags(existing_data.get("tags", {}))
	for tag_name in tags.keys():
		normalized_tags[String(tag_name)] = bool(tags[tag_name])
	normalized_tags = svc._normalize_relationship_tags(normalized_tags)
	var previous_long_term = svc._normalize_long_term(existing_data.get("long_term", {}))
	var profile_node_id = svc._graph.upsert_node(svc.RELATIONSHIP_PROFILE_SPACE, svc._relationship_profile_label(source_npc_id, target_npc_id), {
		"type": "relationship_profile",
		"relationship_key": key,
		"source_npc_id": source_npc_id,
		"target_npc_id": target_npc_id,
		"tags": normalized_tags,
		"long_term": previous_long_term,
		"world_day": world_day,
		"metadata": metadata.duplicate(true),
		"updated_at": svc._timestamp(),
	})
	if profile_node_id == -1:
		return svc._error("upsert_failed", "Failed to upsert relationship profile", {"relationship_key": key})
	svc._graph.add_edge(source_node_id, profile_node_id, "HAS_RELATIONSHIP_PROFILE", 1.0, {"type": "relationship_profile_ref", "relationship_key": key, "source_npc_id": source_npc_id, "target_npc_id": target_npc_id})
	svc._graph.add_edge(profile_node_id, target_node_id, "TARGETS_NPC", 1.0, {"type": "relationship_profile_target", "relationship_key": key, "source_npc_id": source_npc_id, "target_npc_id": target_npc_id})
	if normalized_tags.get("friend", false):
		svc.add_relationship(source_npc_id, target_npc_id, "FRIEND_OF", world_day, -1, 1.0, "profile", false)
	if normalized_tags.get("enemy", false):
		svc.add_relationship(source_npc_id, target_npc_id, "ENEMY_OF", world_day, -1, 1.0, "profile", false)
	if normalized_tags.get("family", false):
		svc.add_relationship(source_npc_id, target_npc_id, "FAMILY_OF", world_day, -1, 1.0, "profile", false)
	return svc._ok({"node_id": profile_node_id, "relationship_key": key})

static func record_relationship_interaction(svc, source_npc_id: String, target_npc_id: String, world_day: int, valence_delta: float, trust_delta: float, respect_delta: float, summary: String, metadata: Dictionary) -> Dictionary:
	if source_npc_id.strip_edges() == "" or target_npc_id.strip_edges() == "":
		return svc._error("invalid_npc_id", "source_npc_id and target_npc_id must be non-empty")
	if world_day < 0:
		return svc._error("invalid_world_day", "world_day must be >= 0")
	if svc._node_id_by_external_id(svc.NPC_SPACE, "npc_id", source_npc_id) == -1 or svc._node_id_by_external_id(svc.NPC_SPACE, "npc_id", target_npc_id) == -1:
		return svc._error("missing_npc", "Both NPCs must exist before interaction writes", {"source_npc_id": source_npc_id, "target_npc_id": target_npc_id})
	var event_node_id = svc._graph.upsert_node(svc.RELATIONSHIP_EVENT_SPACE, svc._relationship_event_label(source_npc_id, target_npc_id, world_day), {
		"type": "relationship_event",
		"relationship_key": svc._relationship_key(source_npc_id, target_npc_id),
		"source_npc_id": source_npc_id,
		"target_npc_id": target_npc_id,
		"world_day": world_day,
		"valence_delta": clampf(valence_delta, -1.0, 1.0),
		"trust_delta": clampf(trust_delta, -1.0, 1.0),
		"respect_delta": clampf(respect_delta, -1.0, 1.0),
		"summary": summary,
		"metadata": metadata.duplicate(true),
		"updated_at": svc._timestamp(),
	})
	if event_node_id == -1:
		return svc._error("upsert_failed", "Failed to record relationship interaction", {"source_npc_id": source_npc_id, "target_npc_id": target_npc_id})
	var recompute = svc._recompute_long_term_from_recent(source_npc_id, target_npc_id, world_day)
	if not recompute.get("ok", false):
		return recompute
	return svc._ok({"node_id": event_node_id, "relationship_key": svc._relationship_key(source_npc_id, target_npc_id)})

static func get_relationship_state(svc, source_npc_id: String, target_npc_id: String, world_day: int, recent_window_days: int, recent_limit: int) -> Dictionary:
	if source_npc_id.strip_edges() == "" or target_npc_id.strip_edges() == "":
		return svc._error("invalid_npc_id", "source_npc_id and target_npc_id must be non-empty")
	if world_day < 0:
		return svc._error("invalid_world_day", "world_day must be >= 0")
	if recent_window_days < 0:
		return svc._error("invalid_recent_window", "recent_window_days must be >= 0")
	var profile_rows = svc._graph.list_nodes_by_metadata(svc.RELATIONSHIP_PROFILE_SPACE, "relationship_key", svc._relationship_key(source_npc_id, target_npc_id), 1, 0)
	var profile_data: Dictionary = {}
	if not profile_rows.is_empty():
		profile_data = profile_rows[0].get("data", {}).duplicate(true)
	var recent = svc._recent_relationship_stats(source_npc_id, target_npc_id, world_day, recent_window_days, recent_limit)
	var tags = svc._normalize_relationship_tags(profile_data.get("tags", {}))
	var long_term = svc._normalize_long_term(profile_data.get("long_term", {}))
	return svc._ok({"source_npc_id": source_npc_id, "target_npc_id": target_npc_id, "tags": tags, "long_term": long_term, "recent": recent})

static func get_relationships_for_npc(svc, npc_id: String, world_day: int, recent_window_days: int, recent_limit: int) -> Dictionary:
	if npc_id.strip_edges() == "":
		return svc._error("invalid_npc_id", "npc_id must be non-empty")
	if svc._node_id_by_external_id(svc.NPC_SPACE, "npc_id", npc_id) == -1:
		return svc._error("missing_npc", "NPC not found", {"npc_id": npc_id})
	var rows = svc._graph.list_nodes_by_metadata(svc.RELATIONSHIP_PROFILE_SPACE, "source_npc_id", npc_id, svc.DEFAULT_SCAN_LIMIT, 0)
	var output: Array = []
	for row in rows:
		var data: Dictionary = row.get("data", {})
		var target_npc_id = String(data.get("target_npc_id", ""))
		if target_npc_id == "":
			continue
		var state = svc.get_relationship_state(npc_id, target_npc_id, world_day, recent_window_days, recent_limit)
		if bool(state.get("ok", false)):
			output.append(state)
	return svc._ok({"npc_id": npc_id, "relationships": output})
