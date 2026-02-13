@tool
extends RefCounted
class_name LocalAgentsBackstoryKnowledgeOps

static func record_oral_knowledge(svc, knowledge_id: String, npc_id: String, category: String, content: String, confidence: float, motifs: Array, world_day: int, metadata: Dictionary) -> Dictionary:
    if npc_id.strip_edges() == "":
        return svc._error("invalid_npc_id", "npc_id must be non-empty")
    if category.strip_edges() == "":
        return svc._error("invalid_category", "category must be non-empty")
    if content.strip_edges() == "":
        return svc._error("invalid_content", "content must be non-empty")
    if confidence < 0.0 or confidence > 1.0:
        return svc._error("invalid_confidence", "confidence must be between 0 and 1")
    if world_day < -1:
        return svc._error("invalid_world_day", "world_day must be >= -1")
    if not svc._ensure_graph():
        return svc._error("graph_unavailable", "NetworkGraph extension unavailable")

    var npc_node_id = svc._node_id_by_external_id(svc.NPC_SPACE, "npc_id", npc_id)
    if npc_node_id == -1:
        return svc._error("missing_npc", "NPC must exist before writing oral knowledge", {"npc_id": npc_id})

    var resolved_id = knowledge_id.strip_edges()
    if resolved_id == "":
        resolved_id = svc._oral_knowledge_seed_id(npc_id, category, world_day)

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
        "updated_at": svc._timestamp(),
    }
    var node_id = svc._graph.upsert_node(svc.ORAL_KNOWLEDGE_SPACE, svc._oral_knowledge_label(resolved_id), payload)
    if node_id == -1:
        return svc._error("upsert_failed", "Failed to upsert oral knowledge", {"knowledge_id": resolved_id})

    svc._graph.add_edge(npc_node_id, node_id, "HAS_ORAL_KNOWLEDGE", confidence, {
        "type": "oral_knowledge_ref",
        "npc_id": npc_id,
        "knowledge_id": resolved_id,
        "world_day": world_day,
        "confidence": confidence,
    })

    return svc._ok({
        "node_id": node_id,
        "knowledge_id": resolved_id,
    })

static func link_oral_knowledge_lineage(svc, source_knowledge_id: String, derived_knowledge_id: String, speaker_npc_id: String, listener_npc_id: String, transmission_hops: int, world_day: int) -> Dictionary:
    if source_knowledge_id.strip_edges() == "" or derived_knowledge_id.strip_edges() == "":
        return svc._error("invalid_knowledge_id", "knowledge ids must be non-empty")
    if transmission_hops < 1:
        return svc._error("invalid_transmission_hops", "transmission_hops must be >= 1")
    if world_day < -1:
        return svc._error("invalid_world_day", "world_day must be >= -1")
    if not svc._ensure_graph():
        return svc._error("graph_unavailable", "NetworkGraph extension unavailable")

    var source_node_id = svc._node_id_by_external_id(svc.ORAL_KNOWLEDGE_SPACE, "knowledge_id", source_knowledge_id)
    var derived_node_id = svc._node_id_by_external_id(svc.ORAL_KNOWLEDGE_SPACE, "knowledge_id", derived_knowledge_id)
    if source_node_id == -1 or derived_node_id == -1:
        return svc._error("missing_knowledge", "Both knowledge nodes must exist", {
            "source": source_knowledge_id,
            "derived": derived_knowledge_id,
        })

    if svc._lineage_edge_exists(derived_node_id, source_node_id):
        return svc._ok({
            "source_knowledge_id": source_knowledge_id,
            "derived_knowledge_id": derived_knowledge_id,
            "lineage_exists": true,
        })
    var edge_id = svc._graph.add_edge(derived_node_id, source_node_id, "DERIVES_FROM", 1.0, {
        "type": "knowledge_lineage",
        "source_knowledge_id": source_knowledge_id,
        "derived_knowledge_id": derived_knowledge_id,
        "speaker_npc_id": speaker_npc_id,
        "listener_npc_id": listener_npc_id,
        "transmission_hops": transmission_hops,
        "world_day": world_day,
    })
    if edge_id == -1:
        return svc._error("edge_failed", "Failed to link knowledge lineage", {
            "source": source_knowledge_id,
            "derived": derived_knowledge_id,
        })
    return svc._ok({
        "edge_id": edge_id,
        "source_knowledge_id": source_knowledge_id,
        "derived_knowledge_id": derived_knowledge_id,
    })

static func get_oral_knowledge_for_npc(svc, npc_id: String, world_day: int, limit: int) -> Dictionary:
    if npc_id.strip_edges() == "":
        return svc._error("invalid_npc_id", "npc_id must be non-empty")
    if limit <= 0:
        return svc._error("invalid_limit", "limit must be > 0")
    if not svc._ensure_graph():
        return svc._error("graph_unavailable", "NetworkGraph extension unavailable")

    var rows = svc._graph.list_nodes_by_metadata(svc.ORAL_KNOWLEDGE_SPACE, "npc_id", npc_id, svc.DEFAULT_SCAN_LIMIT, 0)
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
    return svc._ok({
        "npc_id": npc_id,
        "oral_knowledge": items,
    })

static func get_oral_lineage(svc, knowledge_id: String, limit: int) -> Dictionary:
    if knowledge_id.strip_edges() == "":
        return svc._error("invalid_knowledge_id", "knowledge_id must be non-empty")
    if limit <= 0:
        return svc._error("invalid_limit", "limit must be > 0")
    if not svc._ensure_graph():
        return svc._error("graph_unavailable", "NetworkGraph extension unavailable")

    var node = svc._node_by_external_id(svc.ORAL_KNOWLEDGE_SPACE, "knowledge_id", knowledge_id)
    if node.is_empty():
        return svc._error("missing_knowledge", "oral knowledge not found", {"knowledge_id": knowledge_id})
    var node_id = int(node.get("id", -1))
    var edges = svc._graph.get_edges(node_id, svc.DEFAULT_SCAN_LIMIT)
    var ancestors: Array = []
    for edge in edges:
        if String(edge.get("kind", "")) != "DERIVES_FROM":
            continue
        var target_id = int(edge.get("target_id", -1))
        if target_id == -1:
            continue
        var target_node = svc._graph.get_node(target_id)
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
    return svc._ok({
        "knowledge_id": knowledge_id,
        "lineage": ancestors,
    })

static func upsert_sacred_site(svc, site_id: String, site_type: String, position: Dictionary, radius: float, taboo_ids: Array, world_day: int, metadata: Dictionary) -> Dictionary:
    if site_id.strip_edges() == "":
        return svc._error("invalid_site_id", "site_id must be non-empty")
    if site_type.strip_edges() == "":
        return svc._error("invalid_site_type", "site_type must be non-empty")
    if radius <= 0.0:
        return svc._error("invalid_radius", "radius must be > 0")
    if world_day < -1:
        return svc._error("invalid_world_day", "world_day must be >= -1")
    if not svc._ensure_graph():
        return svc._error("graph_unavailable", "NetworkGraph extension unavailable")

    var payload = {
        "type": "sacred_site",
        "site_id": site_id,
        "site_type": site_type,
        "position": position.duplicate(true),
        "radius": radius,
        "taboo_ids": taboo_ids.duplicate(true),
        "world_day": world_day,
        "metadata": metadata.duplicate(true),
        "updated_at": svc._timestamp(),
    }
    var node_id = svc._graph.upsert_node(svc.SACRED_SITE_SPACE, svc._sacred_site_label(site_id), payload)
    if node_id == -1:
        return svc._error("upsert_failed", "Failed to upsert sacred site", {"site_id": site_id})
    return svc._ok({
        "node_id": node_id,
        "site_id": site_id,
    })

static func get_sacred_site(svc, site_id: String) -> Dictionary:
    if site_id.strip_edges() == "":
        return svc._error("invalid_site_id", "site_id must be non-empty")
    if not svc._ensure_graph():
        return svc._error("graph_unavailable", "NetworkGraph extension unavailable")
    var rows = svc._graph.list_nodes_by_metadata(svc.SACRED_SITE_SPACE, "site_id", site_id, 1, 0)
    if rows.is_empty():
        return svc._error("missing_site", "sacred site not found", {"site_id": site_id})
    return svc._ok({
        "site": rows[0].get("data", {}).duplicate(true),
    })

static func record_ritual_event(svc, ritual_id: String, site_id: String, world_day: int, participants: Array, effects: Dictionary, metadata: Dictionary) -> Dictionary:
    if ritual_id.strip_edges() == "":
        return svc._error("invalid_ritual_id", "ritual_id must be non-empty")
    if site_id.strip_edges() == "":
        return svc._error("invalid_site_id", "site_id must be non-empty")
    if world_day < 0:
        return svc._error("invalid_world_day", "world_day must be >= 0")
    if participants.is_empty():
        return svc._error("invalid_participants", "Participants array must be non-empty")
    if not svc._ensure_graph():
        return svc._error("graph_unavailable", "NetworkGraph extension unavailable")

    var payload = {
        "type": "ritual_event",
        "ritual_id": ritual_id,
        "site_id": site_id,
        "world_day": world_day,
        "participants": participants.duplicate(true),
        "effects": effects.duplicate(true),
        "metadata": metadata.duplicate(true),
        "updated_at": svc._timestamp(),
    }
    var node_id = svc._graph.upsert_node(svc.RITUAL_EVENT_SPACE, svc._ritual_event_label(ritual_id), payload)
    if node_id == -1:
        return svc._error("upsert_failed", "Failed to upsert ritual_event", {"ritual_id": ritual_id})

    var site_node_id = svc._node_id_by_external_id(svc.SACRED_SITE_SPACE, "site_id", site_id)
    if site_node_id != -1:
        svc._graph.add_edge(node_id, site_node_id, "AT_SITE", 1.0, {
            "type": "ritual_site_ref",
            "ritual_id": ritual_id,
            "site_id": site_id,
        })

    for participant in participants:
        var npc_id = String(participant)
        var npc_node_id = svc._node_id_by_external_id(svc.NPC_SPACE, "npc_id", npc_id)
        if npc_node_id == -1:
            continue
        svc._graph.add_edge(npc_node_id, node_id, "PARTICIPATED_IN", 1.0, {
            "type": "participation",
            "npc_id": npc_id,
            "ritual_id": ritual_id,
            "world_day": world_day,
        })

    return svc._ok({
        "node_id": node_id,
        "ritual_id": ritual_id,
    })

static func get_ritual_history_for_site(svc, site_id: String, world_day: int, limit: int) -> Dictionary:
    if site_id.strip_edges() == "":
        return svc._error("invalid_site_id", "site_id must be non-empty")
    if limit <= 0:
        return svc._error("invalid_limit", "limit must be > 0")
    if not svc._ensure_graph():
        return svc._error("graph_unavailable", "NetworkGraph extension unavailable")

    var rows = svc._graph.list_nodes_by_metadata(svc.RITUAL_EVENT_SPACE, "site_id", site_id, svc.DEFAULT_SCAN_LIMIT, 0)
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
    return svc._ok({
        "site_id": site_id,
        "ritual_events": items,
    })

static func upsert_world_truth(svc, truth_id: String, subject_id: String, predicate: String, object_value: Variant, world_day: int, confidence: float, metadata: Dictionary) -> Dictionary:
    if subject_id.strip_edges() == "":
        return svc._error("invalid_subject_id", "subject_id must be non-empty")
    if predicate.strip_edges() == "":
        return svc._error("invalid_predicate", "predicate must be non-empty")
    if world_day < -1:
        return svc._error("invalid_world_day", "world_day must be >= -1")
    if confidence < 0.0 or confidence > 1.0:
        return svc._error("invalid_confidence", "confidence must be between 0 and 1")
    if not svc._ensure_graph():
        return svc._error("graph_unavailable", "NetworkGraph extension unavailable")

    var claim_key = svc._claim_key(subject_id, predicate)
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
        "object_norm": svc._normalize_claim_value(object_value),
        "world_day": world_day,
        "confidence": confidence,
        "metadata": metadata.duplicate(true),
        "updated_at": svc._timestamp(),
    }
    var node_id = svc._graph.upsert_node(svc.TRUTH_SPACE, svc._truth_label(resolved_truth_id), payload)
    if node_id == -1:
        return svc._error("upsert_failed", "Failed to upsert world truth", {
            "truth_id": resolved_truth_id,
            "claim_key": claim_key,
        })
    var subject_npc_node_id = svc._node_id_by_external_id(svc.NPC_SPACE, "npc_id", subject_id)
    if subject_npc_node_id != -1:
        svc._graph.add_edge(subject_npc_node_id, node_id, "HAS_TRUTH", confidence, {
            "type": "truth_ref",
            "subject_id": subject_id,
            "predicate": predicate,
            "claim_key": claim_key,
        })
    return svc._ok({
        "node_id": node_id,
        "truth_id": resolved_truth_id,
        "claim_key": claim_key,
    })

static func upsert_npc_belief(svc, belief_id: String, npc_id: String, subject_id: String, predicate: String, object_value: Variant, world_day: int, confidence: float, metadata: Dictionary) -> Dictionary:
    if npc_id.strip_edges() == "":
        return svc._error("invalid_npc_id", "npc_id must be non-empty")
    if subject_id.strip_edges() == "":
        return svc._error("invalid_subject_id", "subject_id must be non-empty")
    if predicate.strip_edges() == "":
        return svc._error("invalid_predicate", "predicate must be non-empty")
    if world_day < -1:
        return svc._error("invalid_world_day", "world_day must be >= -1")
    if confidence < 0.0 or confidence > 1.0:
        return svc._error("invalid_confidence", "confidence must be between 0 and 1")
    if not svc._ensure_graph():
        return svc._error("graph_unavailable", "NetworkGraph extension unavailable")
    var npc_node_id = svc._node_id_by_external_id(svc.NPC_SPACE, "npc_id", npc_id)
    if npc_node_id == -1:
        return svc._error("missing_npc", "NPC must exist before adding beliefs", {"npc_id": npc_id})

    var claim_key = svc._claim_key(subject_id, predicate)
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
        "object_norm": svc._normalize_claim_value(object_value),
        "world_day": world_day,
        "confidence": confidence,
        "metadata": metadata.duplicate(true),
        "updated_at": svc._timestamp(),
    }
    var node_id = svc._graph.upsert_node(svc.BELIEF_SPACE, svc._belief_label(resolved_belief_id), payload)
    if node_id == -1:
        return svc._error("upsert_failed", "Failed to upsert npc belief", {
            "belief_id": resolved_belief_id,
            "npc_id": npc_id,
            "claim_key": claim_key,
        })

    svc._graph.add_edge(npc_node_id, node_id, "HAS_BELIEF", confidence, {
        "type": "belief_ref",
        "npc_id": npc_id,
        "belief_id": resolved_belief_id,
        "claim_key": claim_key,
    })
    return svc._ok({
        "node_id": node_id,
        "belief_id": resolved_belief_id,
        "claim_key": claim_key,
    })

static func get_truths_for_subject(svc, subject_id: String, world_day: int, limit: int) -> Dictionary:
    if subject_id.strip_edges() == "":
        return svc._error("invalid_subject_id", "subject_id must be non-empty")
    if limit <= 0:
        return svc._error("invalid_limit", "limit must be > 0")
    if not svc._ensure_graph():
        return svc._error("graph_unavailable", "NetworkGraph extension unavailable")
    var rows = svc._graph.list_nodes_by_metadata(svc.TRUTH_SPACE, "subject_id", subject_id, svc.DEFAULT_SCAN_LIMIT, 0)
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
    return svc._ok({
        "subject_id": subject_id,
        "truths": items,
    })

static func get_beliefs_for_npc(svc, npc_id: String, world_day: int, limit: int) -> Dictionary:
    if npc_id.strip_edges() == "":
        return svc._error("invalid_npc_id", "npc_id must be non-empty")
    if limit <= 0:
        return svc._error("invalid_limit", "limit must be > 0")
    if not svc._ensure_graph():
        return svc._error("graph_unavailable", "NetworkGraph extension unavailable")
    var rows = svc._graph.list_nodes_by_metadata(svc.BELIEF_SPACE, "npc_id", npc_id, svc.DEFAULT_SCAN_LIMIT, 0)
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
    return svc._ok({
        "npc_id": npc_id,
        "beliefs": items,
    })

static func get_belief_truth_conflicts(svc, npc_id: String, world_day: int, limit: int) -> Dictionary:
    var beliefs_result: Dictionary = svc.get_beliefs_for_npc(npc_id, world_day, svc.DEFAULT_SCAN_LIMIT)
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
        var truth = svc._latest_truth_for_claim(claim_key, world_day)
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
    return svc._ok({
        "npc_id": npc_id,
        "conflicts": conflicts,
    })
