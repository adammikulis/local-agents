@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const StateHasherScript = preload("res://addons/local_agents/simulation/SimulationStateHasher.gd")
const WorldGenConfigScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")

func run_test(tree: SceneTree) -> bool:
    var c1 = SimulationControllerScript.new()
    var c2 = SimulationControllerScript.new()
    tree.get_root().add_child(c1)
    tree.get_root().add_child(c2)

    c1.configure("seed-worldgen", false, false)
    c2.configure("seed-worldgen", false, false)

    var config = WorldGenConfigScript.new()
    config.map_width = 20
    config.map_height = 20
    var setup_a: Dictionary = c1.configure_environment(config)
    var setup_b: Dictionary = c2.configure_environment(config)

    if not bool(setup_a.get("ok", false)) or not bool(setup_b.get("ok", false)):
        push_error("Environment setup failed")
        c1.queue_free()
        c2.queue_free()
        return false

    var hasher = StateHasherScript.new()
    var hash_a = hasher.hash_state(setup_a)
    var hash_b = hasher.hash_state(setup_b)
    c1.queue_free()
    c2.queue_free()

    if hash_a == "" or hash_a != hash_b:
        push_error("Worldgen determinism hash mismatch")
        return false

    print("Worldgen deterministic fixture hash: %s" % hash_a)
    return true
