@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const WorldGenConfigScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")

func run_test(tree: SceneTree) -> bool:
    var controller = SimulationControllerScript.new()
    tree.get_root().add_child(controller)
    controller.configure("seed-water-first", false, false)

    var config = WorldGenConfigScript.new()
    config.map_width = 18
    config.map_height = 18
    config.spawn_top_candidate_count = 6

    var setup: Dictionary = controller.configure_environment(config)
    if not bool(setup.get("ok", false)):
        push_error("Environment setup failed for water-first test")
        controller.queue_free()
        return false

    var spawn: Dictionary = setup.get("spawn", {})
    var top: Array = spawn.get("top_candidates", [])
    var chosen: Dictionary = spawn.get("chosen", {})
    controller.queue_free()

    if top.is_empty() or chosen.is_empty():
        push_error("Spawn artifact missing candidates")
        return false

    var best = top[0]
    var chosen_score = float(chosen.get("score_total", 0.0))
    var best_score = float(best.get("score_total", 0.0))
    if not is_equal_approx(chosen_score, best_score):
        push_error("Water-first selection did not choose top score")
        return false

    var breakdown: Dictionary = chosen.get("score_breakdown", {})
    var water_term = float(breakdown.get("water_reliability", breakdown.get("water_score", 0.0)))
    var flood_term = float(breakdown.get("flood_safety", breakdown.get("flood_score", 0.0)))
    if not (breakdown.has("water_reliability") or breakdown.has("water_score")) or not (breakdown.has("flood_safety") or breakdown.has("flood_score")):
        push_error("Water-first breakdown missing water/flood terms")
        return false
    if water_term < 0.0 or flood_term < 0.0:
        push_error("Water-first breakdown water/flood terms should be non-negative")
        return false

    print("Water-first spawn artifact: %s" % JSON.stringify(chosen, "", false, true))
    return true
