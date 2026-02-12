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

    service.clear_backstory_space()
    service.queue_free()
    if ok:
        print("BackstoryGraphService tests passed")
    return ok

func _assert(condition: bool, message: String) -> bool:
    if not condition:
        push_error(message)
    return condition
