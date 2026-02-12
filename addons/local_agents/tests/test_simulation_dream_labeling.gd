@tool
extends RefCounted

const BackstoryGraphService = preload("res://addons/local_agents/graph/BackstoryGraphService.gd")

func run_test(tree: SceneTree) -> bool:
    if not ClassDB.class_exists("NetworkGraph"):
        print("Skipping dream labeling test (NetworkGraph unavailable).")
        return true

    var service: Node = BackstoryGraphService.new()
    tree.get_root().add_child(service)
    service.clear_backstory_space()

    var ok = true
    var npc_result: Dictionary = service.upsert_npc("npc_dreamer", "Dreamer")
    ok = ok and bool(npc_result.get("ok", false))

    var dream_result: Dictionary = service.add_dream_memory(
        "dream_mem_1",
        "npc_dreamer",
        "I dreamed of a flooded market and silent bells.",
        5,
        {"motif": "bells"},
        0.6,
        0.7,
        {"source": "test"}
    )
    ok = ok and bool(dream_result.get("ok", false))

    var recall: Dictionary = service.get_memory_recall_candidates("npc_dreamer", 5, 8, true)
    ok = ok and bool(recall.get("ok", false))
    var candidates: Array = recall.get("candidates", [])
    ok = ok and candidates.size() >= 1
    if not candidates.is_empty():
        var top: Dictionary = candidates[0]
        ok = ok and bool(top.get("is_dream", false))
        ok = ok and String(top.get("memory_kind", "")) == "dream"

    service.clear_backstory_space()
    service.queue_free()

    if not ok:
        push_error("Dream labeling test failed")
        return false
    print("Dream labeling test passed")
    return true
