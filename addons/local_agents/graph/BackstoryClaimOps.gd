@tool
extends RefCounted
class_name LocalAgentsBackstoryClaimOps

static func claim_key(subject_id: String, predicate: String) -> String:
    return "%s|%s" % [subject_id.strip_edges().to_lower(), predicate.strip_edges().to_lower()]

static func normalize_claim_value(value: Variant) -> String:
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

static func latest_truth_for_claim(svc, normalized_claim_key: String, world_day: int = -1) -> Dictionary:
    var rows = svc._graph.list_nodes_by_metadata(svc.TRUTH_SPACE, "claim_key", normalized_claim_key, svc.DEFAULT_SCAN_LIMIT, 0)
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

static func oral_knowledge_seed_id(npc_id: String, category: String, world_day: int) -> String:
    return "%s:%s:%d" % [npc_id, category.strip_edges().to_lower(), max(0, world_day)]
