@tool
extends RefCounted

const BackstoryGraphService = preload("res://addons/local_agents/graph/BackstoryGraphService.gd")
const ExtensionLoader = preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")

func run_test(tree: SceneTree) -> bool:
    if not ExtensionLoader.ensure_initialized():
        push_error("NetworkGraph init failed: %s" % ExtensionLoader.get_error())
        return false
    if not ClassDB.class_exists("NetworkGraph"):
        push_error("NetworkGraph class missing after extension init.")
        return false

    var service: Node = BackstoryGraphService.new()
    var test_db_path := "user://local_agents/network_backstory_test_%d.sqlite3" % int(Time.get_unix_time_from_system())
    if service.has_method("set_database_path"):
        service.set_database_path(test_db_path)
    var absolute_test_db = ProjectSettings.globalize_path(test_db_path)
    if FileAccess.file_exists(absolute_test_db):
        DirAccess.remove_absolute(absolute_test_db)
    tree.get_root().add_child(service)
    service.clear_backstory_space()

    var ok = true
    ok = ok and _assert(service.upsert_npc("npc_aria", "Aria").get("ok", false), "Failed to create npc_aria")
    ok = ok and _assert(service.upsert_npc("npc_bram", "Bram").get("ok", false), "Failed to create npc_bram")
    ok = ok and _assert(service.upsert_faction("faction_guard", "City Guard").get("ok", false), "Failed to create faction")
    ok = ok and _assert(service.upsert_quest("quest_relic", "Recover the Relic").get("ok", false), "Failed to create quest")

    ok = ok and _assert(service.set_world_time(12, "spring", "imperial").get("ok", false), "Failed to set world time")

    ok = ok and _assert(
        service.add_relationship("npc_aria", "npc_bram", "ALLY_OF", 10, -1, 0.9, "writer", false).get("ok", false),
        "Failed to add relationship"
    )
    ok = ok and _assert(
        service.add_relationship("npc_aria", "faction_guard", "MEMBER_OF", 8, -1, 1.0, "writer", true).get("ok", false),
        "Failed to add first membership"
    )

    ok = ok and _assert(
        service.add_memory("mem_aria_001", "npc_aria", "Aria saw Bram hide the relic shard.", -1, -1, 11, 0.8, 0.9, ["quest"]).get("ok", false),
        "Failed to add memory"
    )
    ok = ok and _assert(service.upsert_npc("npc_child", "Mira").get("ok", false), "Failed to create npc_child")
    ok = ok and _assert(service.upsert_npc("npc_brent", "Brent").get("ok", false), "Failed to create npc_brent")
    ok = ok and _assert(service.upsert_npc("npc_daren", "Daren").get("ok", false), "Failed to create npc_daren")
    ok = ok and _assert(
        service.upsert_world_truth("truth_child_father", "npc_child", "father_of", "npc_brent", 11, 1.0, {"source": "authoritative"}).get("ok", false),
        "Failed to upsert world truth"
    )
    ok = ok and _assert(
        service.upsert_npc_belief("belief_aria_child_father", "npc_aria", "npc_child", "father_of", "npc_daren", 12, 0.85, {"source": "rumor"}).get("ok", false),
        "Failed to upsert npc belief"
    )
    var aria_beliefs: Dictionary = service.get_beliefs_for_npc("npc_aria", 12, 8)
    ok = ok and _assert(aria_beliefs.get("ok", false), "Failed to fetch beliefs")
    ok = ok and _assert(aria_beliefs.get("beliefs", []).size() >= 1, "Beliefs missing")
    var child_truths: Dictionary = service.get_truths_for_subject("npc_child", 12, 8)
    ok = ok and _assert(child_truths.get("ok", false), "Failed to fetch truths")
    ok = ok and _assert(child_truths.get("truths", []).size() >= 1, "Truths missing")
    var belief_conflicts: Dictionary = service.get_belief_truth_conflicts("npc_aria", 12, 8)
    ok = ok and _assert(belief_conflicts.get("ok", false), "Failed to fetch belief-truth conflicts")
    ok = ok and _assert(belief_conflicts.get("conflicts", []).size() >= 1, "Expected belief-truth conflict not detected")

    ok = ok and _assert(
        service.update_quest_state("npc_aria", "quest_relic", "in_progress", 11, true).get("ok", false),
        "Failed to write quest state"
    )
    ok = ok and _assert(
        service.update_dialogue_state("npc_aria", "trust_bram", "high", 12).get("ok", false),
        "Failed to write dialogue state"
    )
    ok = ok and _assert(
        service.update_relationship_profile(
            "npc_aria",
            "npc_bram",
            12,
            {"family": true, "friend": true, "enemy": true}
        ).get("ok", false),
        "Failed to write relationship profile"
    )
    ok = ok and _assert(
        service.record_relationship_interaction("npc_aria", "npc_bram", 12, -0.9, -0.7, -0.6, "Major betrayal").get("ok", false),
        "Failed to write negative interaction"
    )
    ok = ok and _assert(
        service.record_relationship_interaction("npc_aria", "npc_bram", 12, -0.8, -0.5, -0.4, "Insult in public").get("ok", false),
        "Failed to write second negative interaction"
    )

    var rel_state: Dictionary = service.get_relationship_state("npc_aria", "npc_bram", 12, 14, 64)
    ok = ok and _assert(rel_state.get("ok", false), "Relationship state query failed")
    ok = ok and _assert(rel_state.get("tags", {}).get("family", false), "Family tag missing")
    ok = ok and _assert(rel_state.get("tags", {}).get("friend", false), "Friend tag missing")
    ok = ok and _assert(rel_state.get("tags", {}).get("enemy", false), "Enemy tag missing")
    ok = ok and _assert(float(rel_state.get("recent", {}).get("valence_avg", 0.0)) < -0.7, "Recent valence not captured")
    ok = ok and _assert(float(rel_state.get("long_term", {}).get("bond", 0.0)) < -0.6, "Long-term bond not dominated by recent feelings")
    ok = ok and _assert(float(rel_state.get("long_term", {}).get("trust", 0.0)) < -0.4, "Long-term trust not dominated by recent feelings")

    var context: Dictionary = service.get_backstory_context("npc_aria", 12, 16)
    ok = ok and _assert(context.get("ok", false), "Context query failed")
    ok = ok and _assert(context.get("relationships", []).size() >= 1, "Relationship context missing")
    ok = ok and _assert(context.get("memories", []).size() >= 1, "Memory context missing")
    ok = ok and _assert(context.get("quest_states", []).size() >= 1, "Quest context missing")
    ok = ok and _assert(context.get("dialogue_states", []).size() >= 1, "Dialogue context missing")
    ok = ok and _assert(context.get("relationship_states", []).size() >= 1, "Relationship profile context missing")
    ok = ok and _assert(context.has("beliefs"), "Context missing beliefs")
    ok = ok and _assert(context.has("belief_truth_conflicts"), "Context missing belief_truth_conflicts")

    ok = ok and _assert(
        service.update_dialogue_state("npc_aria", "life_status", "dead", 12).get("ok", false),
        "Failed to set life_status"
    )
    ok = ok and _assert(
        service.update_dialogue_state("npc_aria", "death_day", 12, 12).get("ok", false),
        "Failed to set death_day"
    )
    ok = ok and _assert(
        service.update_quest_state("npc_aria", "quest_relic", "completed", 13, true).get("ok", false),
        "Failed to add post-death quest state"
    )

    var contradictions: Dictionary = service.detect_contradictions("npc_aria")
    ok = ok and _assert(contradictions.get("ok", false), "Contradiction query failed")
    ok = ok and _assert(contradictions.get("contradictions", []).size() >= 1, "Expected contradiction not detected")

    var playbook: Dictionary = service.get_cypher_playbook("npc_aria", 12, 16)
    ok = ok and _assert(playbook.get("ok", false), "Cypher playbook generation failed")
    var queries: Dictionary = playbook.get("queries", {})
    ok = ok and _assert(queries.has("npc_backstory_context"), "Playbook missing npc_backstory_context query")
    ok = ok and _assert(queries.has("post_death_activity"), "Playbook missing post_death_activity query")
    ok = ok and _assert(queries.has("truths_for_subject"), "Playbook missing truths_for_subject query")
    ok = ok and _assert(queries.has("beliefs_for_npc"), "Playbook missing beliefs_for_npc query")
    ok = ok and _assert(queries.has("belief_truth_conflicts"), "Playbook missing belief_truth_conflicts query")
    var context_query: Dictionary = queries.get("npc_backstory_context", {})
    ok = ok and _assert(String(context_query.get("cypher", "")).find("MATCH (n:NPC {npc_id: $npc_id})") != -1, "Context query malformed")
    var query_params: Dictionary = playbook.get("params", {})
    ok = ok and _assert(String(query_params.get("npc_id", "")) == "npc_aria", "Playbook params missing npc_id")

    service.clear_backstory_space()
    service.queue_free()
    if FileAccess.file_exists(absolute_test_db):
        DirAccess.remove_absolute(absolute_test_db)
    if ok:
        print("BackstoryGraphService tests passed")
    return ok

func _assert(condition: bool, message: String) -> bool:
    if not condition:
        push_error(message)
    return condition
