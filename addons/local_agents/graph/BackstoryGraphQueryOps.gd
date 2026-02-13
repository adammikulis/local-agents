@tool
extends RefCounted
class_name LocalAgentsBackstoryGraphQueryOps

static func node_by_external_id(svc, space: String, key: String, value: Variant) -> Dictionary:
    if not svc._ensure_graph():
        return {}
    var rows = svc._graph.list_nodes_by_metadata(space, key, value, 1, 0)
    if rows.is_empty():
        return {}
    return rows[0]

static func node_id_by_external_id(svc, space: String, key: String, value: Variant) -> int:
    var row: Dictionary = node_by_external_id(svc, space, key, value)
    return int(row.get("id", -1))

static func nodes_for_npc(svc, space: String, npc_id: String, world_day: int, limit: int) -> Array:
    var rows = svc._graph.list_nodes_by_metadata(space, "npc_id", npc_id, limit * 4, 0)
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

static func active_relationships_for_npc(svc, npc_node_id: int, world_day: int, limit: int) -> Array:
    var edges = svc._graph.get_edges(npc_node_id, svc.DEFAULT_SCAN_LIMIT)
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

static func active_exclusive_memberships(svc, npc_node_id: int) -> Array:
    var edges = svc._graph.get_edges(npc_node_id, svc.DEFAULT_SCAN_LIMIT)
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

static func resolve_relationship_target(svc, relationship_type: String, target_entity_id: String) -> Dictionary:
    var kind = relationship_type.to_upper()
    if kind == "MEMBER_OF":
        var faction_node_id = node_id_by_external_id(svc, svc.FACTION_SPACE, "id", target_entity_id)
        if faction_node_id != -1:
            return {"node_id": faction_node_id, "space": svc.FACTION_SPACE}
    var npc_node_id = node_id_by_external_id(svc, svc.NPC_SPACE, "npc_id", target_entity_id)
    if npc_node_id != -1:
        return {"node_id": npc_node_id, "space": svc.NPC_SPACE}
    var place_node_id = node_id_by_external_id(svc, svc.PLACE_SPACE, "id", target_entity_id)
    if place_node_id != -1:
        return {"node_id": place_node_id, "space": svc.PLACE_SPACE}
    var quest_node_id = node_id_by_external_id(svc, svc.QUEST_SPACE, "id", target_entity_id)
    if quest_node_id != -1:
        return {"node_id": quest_node_id, "space": svc.QUEST_SPACE}
    return {"node_id": -1, "space": ""}

static func dialogue_state_value(svc, npc_id: String, state_key: String, fallback: Variant = null) -> Variant:
    var row: Dictionary = node_by_external_id(svc, svc.DIALOGUE_STATE_SPACE, "state_key", state_key)
    if row.is_empty():
        return fallback
    var data: Dictionary = row.get("data", {})
    if String(data.get("npc_id", "")) != npc_id:
        var rows = svc._graph.list_nodes_by_metadata(svc.DIALOGUE_STATE_SPACE, "npc_id", npc_id, 512, 0)
        for item in rows:
            var item_data: Dictionary = item.get("data", {})
            if String(item_data.get("state_key", "")) == state_key:
                return item_data.get("state_value", fallback)
        return fallback
    return data.get("state_value", fallback)

static func post_day_nodes(svc, space: String, npc_id: String, day: int) -> Array:
    var rows = svc._graph.list_nodes_by_metadata(space, "npc_id", npc_id, 512, 0)
    var result: Array = []
    for row in rows:
        var data: Dictionary = row.get("data", {})
        if int(data.get("world_day", -1)) > day:
            result.append(data.duplicate(true))
    return result

static func lineage_edge_exists(svc, source_node_id: int, target_node_id: int) -> bool:
    var edges = svc._graph.get_edges(source_node_id, svc.DEFAULT_SCAN_LIMIT)
    for edge in edges:
        if int(edge.get("target_id", -1)) != target_node_id:
            continue
        if String(edge.get("kind", "")) != "DERIVES_FROM":
            continue
        return true
    return false
