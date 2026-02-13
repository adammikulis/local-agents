@tool
extends RefCounted
class_name LocalAgentsBackstoryRelationshipStateOps

static func recent_relationship_stats(svc, source_npc_id: String, target_npc_id: String, world_day: int, recent_window_days: int, recent_limit: int) -> Dictionary:
    var rows = svc._graph.list_nodes_by_metadata(svc.RELATIONSHIP_EVENT_SPACE, "relationship_key", relationship_key(source_npc_id, target_npc_id), svc.DEFAULT_SCAN_LIMIT, 0)
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

static func recompute_long_term_from_recent(svc, source_npc_id: String, target_npc_id: String, world_day: int, recent_window_days: int = 14, recent_weight: float = 0.85) -> Dictionary:
    var upsert: Dictionary = svc.update_relationship_profile(source_npc_id, target_npc_id, world_day, {}, {})
    if not bool(upsert.get("ok", false)):
        return upsert

    var recent: Dictionary = recent_relationship_stats(svc, source_npc_id, target_npc_id, world_day, recent_window_days, 128)
    var key = relationship_key(source_npc_id, target_npc_id)
    var existing_rows = svc._graph.list_nodes_by_metadata(svc.RELATIONSHIP_PROFILE_SPACE, "relationship_key", key, 1, 0)
    if existing_rows.is_empty():
        return svc._error("profile_missing", "Relationship profile missing during recompute")
    var profile: Dictionary = existing_rows[0]
    var profile_data: Dictionary = profile.get("data", {}).duplicate(true)
    var long_term: Dictionary = normalize_long_term(profile_data.get("long_term", {}))

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
    profile_data["updated_at"] = svc._timestamp()
    if not svc._graph.update_node_data(int(profile.get("id", -1)), profile_data):
        return svc._error("update_failed", "Failed to update relationship profile long-term values")
    return svc._ok({
        "relationship_key": key,
        "long_term": long_term,
        "recent": recent,
    })

static func normalize_long_term(long_term: Dictionary) -> Dictionary:
    return {
        "bond": clampf(float(long_term.get("bond", 0.0)), -1.0, 1.0),
        "trust": clampf(float(long_term.get("trust", 0.0)), -1.0, 1.0),
        "respect": clampf(float(long_term.get("respect", 0.0)), -1.0, 1.0),
        "history_weight": clampf(float(long_term.get("history_weight", 0.5)), 0.0, 1.0),
    }

static func normalize_relationship_tags(tags: Dictionary) -> Dictionary:
    return {
        "friend": bool(tags.get("friend", false)),
        "family": bool(tags.get("family", false)),
        "enemy": bool(tags.get("enemy", false)),
    }

static func relationship_key(source_npc_id: String, target_npc_id: String) -> String:
    return "%s->%s" % [source_npc_id, target_npc_id]
