@tool
extends RefCounted

const SimulationControllerScript := preload("res://addons/local_agents/simulation/SimulationController.gd")
const TestModelHelper := preload("res://addons/local_agents/tests/test_model_helper.gd")

func run_test(tree: SceneTree) -> bool:
    if not ClassDB.class_exists("NetworkGraph"):
        print("Skipping no-empty-generation test (NetworkGraph unavailable).")
        return true

    var controller = SimulationControllerScript.new()
    tree.get_root().add_child(controller)

    var runtime: Object = Engine.get_singleton("AgentRuntime") if Engine.has_singleton("AgentRuntime") else null
    if runtime == null or not runtime.has_method("load_model"):
        push_error("AgentRuntime unavailable for no-empty-generation test")
        controller.queue_free()
        return false

    var helper = TestModelHelper.new()
    var model_path := helper.ensure_local_model()
    if model_path.strip_edges() == "":
        push_error("No-empty-generation test requires a local model")
        controller.queue_free()
        return false

    var load_options = helper.apply_runtime_overrides({
        "max_tokens": 128,
        "temperature": 0.2,
        "n_gpu_layers": 0,
    })
    var loaded := bool(runtime.call("load_model", model_path, load_options))
    if not loaded:
        push_error("Failed to load local model for no-empty-generation test")
        controller.queue_free()
        return false

    var dependency_errors: Array[String] = []
    controller.simulation_dependency_error.connect(func(tick, phase, error_code):
        dependency_errors.append("%d:%s:%s" % [int(tick), String(phase), String(error_code)])
    )

    controller.configure("seed-no-empty", false, true)
    controller.register_villager("npc_ne1", "N1", {"mood": "alert"})
    controller.register_villager("npc_ne2", "N2", {"mood": "calm"})
    controller.set_dream_influence("npc_ne1", {"motif": "river"})

    for tick in range(1, 49):
        var tick_result: Dictionary = controller.process_tick(tick, 1.0)
        if not bool(tick_result.get("ok", false)):
            dependency_errors.append("%d:%s:%s" % [tick, String(tick_result.get("phase", "unknown")), String(tick_result.get("error", "tick_failed"))])

    runtime.call("unload_model")
    controller.queue_free()

    for item in dependency_errors:
        if String(item).contains("empty_generation"):
            push_error("No-empty-generation test failed: %s" % item)
            return false

    print("No-empty-generation test passed")
    return true
