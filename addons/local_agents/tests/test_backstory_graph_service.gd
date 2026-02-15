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
    var upsert_npc_aria_result: Dictionary = service.upsert_npc("npc_aria", "Aria")
    ok = ok and _assert(upsert_npc_aria_result.get("ok", false), "Failed to create npc_aria")
    var upsert_npc_bram_result: Dictionary = service.upsert_npc("npc_bram", "Bram")
    ok = ok and _assert(upsert_npc_bram_result.get("ok", false), "Failed to create npc_bram")
    var upsert_faction_result: Dictionary = service.upsert_faction("faction_guard", "City Guard")
    ok = ok and _assert(upsert_faction_result.get("ok", false), "Failed to create faction")
    var upsert_quest_result: Dictionary = service.upsert_quest("quest_relic", "Recover the Relic")
    ok = ok and _assert(upsert_quest_result.get("ok", false), "Failed to create quest")

    var set_world_time_result: Dictionary = service.set_world_time(12, "spring", "imperial")
    ok = ok and _assert(set_world_time_result.get("ok", false), "Failed to set world time")

    var add_relationship_result: Dictionary = service.add_relationship("npc_aria", "npc_bram", "ALLY_OF", 10, -1, 0.9, "writer", false)
    ok = ok and _assert(
        add_relationship_result.get("ok", false),
        "Failed to add relationship"
    )
    var add_membership_result: Dictionary = service.add_relationship("npc_aria", "faction_guard", "MEMBER_OF", 8, -1, 1.0, "writer", true)
    ok = ok and _assert(
        add_membership_result.get("ok", false),
        "Failed to add first membership"
    )

    var add_memory_result: Dictionary = service.add_memory("mem_aria_001", "npc_aria", "Aria saw Bram hide the relic shard.", -1, -1, 11, 0.8, 0.9, ["quest"])
    ok = ok and _assert(
        add_memory_result.get("ok", false),
        "Failed to add memory"
    )
    var upsert_npc_child_result: Dictionary = service.upsert_npc("npc_child", "Mira")
    ok = ok and _assert(upsert_npc_child_result.get("ok", false), "Failed to create npc_child")
    var upsert_npc_brent_result: Dictionary = service.upsert_npc("npc_brent", "Brent")
    ok = ok and _assert(upsert_npc_brent_result.get("ok", false), "Failed to create npc_brent")
    var upsert_npc_daren_result: Dictionary = service.upsert_npc("npc_daren", "Daren")
    ok = ok and _assert(upsert_npc_daren_result.get("ok", false), "Failed to create npc_daren")
    var upsert_world_truth_result: Dictionary = service.upsert_world_truth("truth_child_father", "npc_child", "father_of", "npc_brent", 11, 1.0, {"source": "authoritative"})
    ok = ok and _assert(
        upsert_world_truth_result.get("ok", false),
        "Failed to upsert world truth"
    )
    var upsert_npc_belief_result: Dictionary = service.upsert_npc_belief("belief_aria_child_father", "npc_aria", "npc_child", "father_of", "npc_daren", 12, 0.85, {"source": "rumor"})
    ok = ok and _assert(
        upsert_npc_belief_result.get("ok", false),
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

    var update_quest_state_result: Dictionary = service.update_quest_state("npc_aria", "quest_relic", "in_progress", 11, true)
    ok = ok and _assert(
        update_quest_state_result.get("ok", false),
        "Failed to write quest state"
    )
    var update_dialogue_state_result: Dictionary = service.update_dialogue_state("npc_aria", "trust_bram", "high", 12)
    ok = ok and _assert(
        update_dialogue_state_result.get("ok", false),
        "Failed to write dialogue state"
    )
    var update_relationship_profile_result: Dictionary = service.update_relationship_profile(
        "npc_aria",
        "npc_bram",
        12,
        {"family": true, "friend": true, "enemy": true}
    )
    ok = ok and _assert(
        update_relationship_profile_result.get("ok", false),
        "Failed to write relationship profile"
    )
    var first_interaction_result: Dictionary = service.record_relationship_interaction("npc_aria", "npc_bram", 12, -0.9, -0.7, -0.6, "Major betrayal")
    ok = ok and _assert(
        first_interaction_result.get("ok", false),
        "Failed to write negative interaction"
    )
    var second_interaction_result: Dictionary = service.record_relationship_interaction("npc_aria", "npc_bram", 12, -0.8, -0.5, -0.4, "Insult in public")
    ok = ok and _assert(
        second_interaction_result.get("ok", false),
        "Failed to write second negative interaction"
    )

    var rel_state: Dictionary = service.get_relationship_state("npc_aria", "npc_bram", 12, 14, 64)
    var rel_tags: Dictionary = rel_state.get("tags", {})
    var rel_recent: Dictionary = rel_state.get("recent", {})
    var rel_long_term: Dictionary = rel_state.get("long_term", {})
    ok = ok and _assert(rel_state.get("ok", false), "Relationship state query failed")
    ok = ok and _assert(rel_tags.get("family", false), "Family tag missing")
    ok = ok and _assert(rel_tags.get("friend", false), "Friend tag missing")
    ok = ok and _assert(rel_tags.get("enemy", false), "Enemy tag missing")
    ok = ok and _assert(float(rel_recent.get("valence_avg", 0.0)) < -0.7, "Recent valence not captured")
    ok = ok and _assert(float(rel_long_term.get("bond", 0.0)) < -0.6, "Long-term bond not dominated by recent feelings")
    ok = ok and _assert(float(rel_long_term.get("trust", 0.0)) < -0.4, "Long-term trust not dominated by recent feelings")

    var context: Dictionary = service.get_backstory_context("npc_aria", 12, 16)
    ok = ok and _assert(context.get("ok", false), "Context query failed")
    ok = ok and _assert(context.get("relationships", []).size() >= 1, "Relationship context missing")
    ok = ok and _assert(context.get("memories", []).size() >= 1, "Memory context missing")
    ok = ok and _assert(context.get("quest_states", []).size() >= 1, "Quest context missing")
    ok = ok and _assert(context.get("dialogue_states", []).size() >= 1, "Dialogue context missing")
    ok = ok and _assert(context.get("relationship_states", []).size() >= 1, "Relationship profile context missing")
    ok = ok and _assert(context.has("beliefs"), "Context missing beliefs")
    ok = ok and _assert(context.has("belief_truth_conflicts"), "Context missing belief_truth_conflicts")

    var life_status_result: Dictionary = service.update_dialogue_state("npc_aria", "life_status", "dead", 12)
    ok = ok and _assert(
        life_status_result.get("ok", false),
        "Failed to set life_status"
    )
    var death_day_result: Dictionary = service.update_dialogue_state("npc_aria", "death_day", 12, 12)
    ok = ok and _assert(
        death_day_result.get("ok", false),
        "Failed to set death_day"
    )
    var post_death_quest_result: Dictionary = service.update_quest_state("npc_aria", "quest_relic", "completed", 13, true)
    ok = ok and _assert(
        post_death_quest_result.get("ok", false),
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
    ok = ok and _assert(queries.has("oral_knowledge_for_npc"), "Playbook missing oral_knowledge_for_npc query")
    ok = ok and _assert(queries.has("oral_transmission_timeline"), "Playbook missing oral_transmission_timeline query")
    ok = ok and _assert(queries.has("ritual_event_participants"), "Playbook missing ritual_event_participants query")
    ok = ok and _assert(queries.has("sacred_site_ritual_history"), "Playbook missing sacred_site_ritual_history query")
    ok = ok and _assert(queries.has("sacred_site_taboo_log"), "Playbook missing sacred_site_taboo_log query")
    var context_query: Dictionary = queries.get("npc_backstory_context", {})
    ok = ok and _assert(String(context_query.get("cypher", "")).find("MATCH (n:NPC {npc_id: $npc_id})") != -1, "Context query malformed")
    var query_params: Dictionary = playbook.get("params", {})
    ok = ok and _assert(String(query_params.get("npc_id", "")) == "npc_aria", "Playbook params missing npc_id")

    var oral_primary: Dictionary = service.record_oral_knowledge("nk_route_aria", "npc_aria", "water_route", "Aria teaches the river path.", 0.92, ["river", "hunting"], 13, {"notes": "water lore"})
    ok = ok and _assert(oral_primary.get("ok", false), "Failed to record oral knowledge for npc_aria")
    var oral_secondary: Dictionary = service.record_oral_knowledge("nk_route_bram", "npc_bram", "ritual_chant", "Bram learns the chant from Aria.", 0.87, ["chant"], 14)
    ok = ok and _assert(oral_secondary.get("ok", false), "Failed to record oral knowledge for npc_bram")
    var lineage_link_result: Dictionary = service.link_oral_knowledge_lineage("nk_route_aria", "nk_route_bram", "npc_aria", "npc_bram", 1, 14)
    ok = ok and _assert(lineage_link_result.get("ok", false), "Failed to link oral lineage")
    var lineage_relink: Dictionary = service.link_oral_knowledge_lineage("nk_route_aria", "nk_route_bram", "npc_aria", "npc_bram", 1, 14)
    ok = ok and _assert(lineage_relink.get("lineage_exists", false), "Lineage should be idempotent")
    var oral_for_aria: Dictionary = service.get_oral_knowledge_for_npc("npc_aria", 16, 4)
    ok = ok and _assert(oral_for_aria.get("oral_knowledge", []).size() >= 1, "Oral knowledge fetch missing entries for Aria")
    var lineage_chain: Dictionary = service.get_oral_lineage("nk_route_bram")
    ok = ok and _assert(lineage_chain.get("lineage", []).size() >= 1, "Lineage chain missing parent knowledge")

    var upsert_site_result: Dictionary = service.upsert_sacred_site("site_spring", "spring", {"x": 102.5, "y": 0.0, "z": -13.7}, 4.5, ["taboo_water"], 12, {"notes": "primary spring"})
    ok = ok and _assert(upsert_site_result.get("ok", false), "Failed to upsert sacred site")
    var site: Dictionary = service.get_sacred_site("site_spring")
    var site_data: Dictionary = site.get("site", {})
    ok = ok and _assert(site_data.get("site_id", "") == "site_spring", "Fetched sacred site mismatch")

    var ritual_event_result: Dictionary = service.record_ritual_event("ritual_sunrise", "site_spring", 14, ["npc_aria", "npc_bram"], {"blessing": "sun"}, {"mood": "solemn"})
    ok = ok and _assert(ritual_event_result.get("ok", false), "Failed to record ritual event")
    var ritual_history: Dictionary = service.get_ritual_history_for_site("site_spring", 16, 8)
    ok = ok and _assert(ritual_history.get("ritual_events", []).size() >= 1, "Ritual history missing recorded event")

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
