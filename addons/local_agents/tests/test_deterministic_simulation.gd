@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const StateHasherScript = preload("res://addons/local_agents/simulation/SimulationStateHasher.gd")

func run_test(tree: SceneTree) -> bool:
    var c1 = SimulationControllerScript.new()
    var c2 = SimulationControllerScript.new()
    tree.get_root().add_child(c1)
    tree.get_root().add_child(c2)

    c1.configure("seed-alpha", false, false)
    c2.configure("seed-alpha", false, false)
    c1.set_cognition_features(false, false, false)
    c2.set_cognition_features(false, false, false)

    c1.register_villager("npc_1", "Ari", {"mood": "focused"})
    c1.register_villager("npc_2", "Bren", {"mood": "curious"})
    c2.register_villager("npc_1", "Ari", {"mood": "focused"})
    c2.register_villager("npc_2", "Bren", {"mood": "curious"})

    c1.set_narrator_directive("Keep trade stable")
    c2.set_narrator_directive("Keep trade stable")
    c1.set_dream_influence("npc_1", {"motif": "lanterns"})
    c2.set_dream_influence("npc_1", {"motif": "lanterns"})

    var hasher = StateHasherScript.new()
    var hashes_a: Array = []
    var hashes_b: Array = []

    for tick in range(1, 73):
        var state_a: Dictionary = c1.process_tick(tick, 1.0)
        var state_b: Dictionary = c2.process_tick(tick, 1.0)
        hashes_a.append(hasher.hash_state(state_a))
        hashes_b.append(hasher.hash_state(state_b))

    c1.queue_free()
    c2.queue_free()

    if hashes_a != hashes_b:
        push_error("Deterministic simulation hash mismatch")
        return false

    print("Deterministic simulation test passed")
    return true
