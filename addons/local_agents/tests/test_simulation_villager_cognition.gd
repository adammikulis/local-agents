@tool
extends RefCounted

const SimulationControllerScript := preload("res://addons/local_agents/simulation/SimulationController.gd")
const TestModelHelper := preload("res://addons/local_agents/tests/test_model_helper.gd")

func run_test(tree: SceneTree) -> bool:
    if not ClassDB.class_exists("NetworkGraph"):
        print("Skipping villager cognition test (NetworkGraph unavailable).")
        return true

    var skip_reason := _cognition_runtime_skip_reason()
    if skip_reason != "":
        print("Skipping villager cognition test (%s)." % skip_reason)
        return true

    var controller = SimulationControllerScript.new()
    tree.get_root().add_child(controller)
    var runtime: Object = Engine.get_singleton("AgentRuntime") if Engine.has_singleton("AgentRuntime") else null
    if runtime == null or not runtime.has_method("load_model"):
        push_error("AgentRuntime unavailable for cognition test")
        controller.queue_free()
        return false
    var helper = TestModelHelper.new()
    var model_path := helper.ensure_local_model()
    if model_path.strip_edges() == "":
        push_error("Cognition test requires a local model")
        controller.queue_free()
        return false
    var load_options = helper.apply_runtime_overrides({
        "max_tokens": 128,
        "temperature": 0.2,
        "n_gpu_layers": 0,
    })
    var loaded := bool(runtime.call("load_model", model_path, load_options))
    if not loaded:
        push_error("Failed to load local model for cognition test")
        controller.queue_free()
        return false

    var counters := {
        "thought": 0,
        "dialogue": 0,
        "dream": 0,
    }
    var dependency_errors: Array[String] = []
    controller.villager_thought_recorded.connect(func(_npc_id, _tick, _memory_id, _thought_text):
        counters["thought"] = int(counters.get("thought", 0)) + 1
    )
    controller.villager_dialogue_recorded.connect(func(_source, _target, _tick, _event_id, _dialogue_text):
        counters["dialogue"] = int(counters.get("dialogue", 0)) + 1
    )
    controller.villager_dream_recorded.connect(func(_npc_id, _tick, _memory_id, _dream_text, _effect):
        counters["dream"] = int(counters.get("dream", 0)) + 1
    )
    controller.simulation_dependency_error.connect(func(tick, phase, error_code):
        dependency_errors.append("%d:%s:%s" % [int(tick), String(phase), String(error_code)])
    )

    controller.configure("seed-cognition", false, true)
    controller.register_villager("npc_c1", "C1", {"mood": "alert"})
    controller.register_villager("npc_c2", "C2", {"mood": "calm"})
    controller.set_dream_influence("npc_c1", {"motif": "river"})

    for tick in range(1, 49):
        var tick_result: Dictionary = controller.process_tick(tick, 1.0)
        if not bool(tick_result.get("ok", false)):
            dependency_errors.append("%d:%s:%s" % [tick, String(tick_result.get("phase", "unknown")), String(tick_result.get("error", "tick_failed"))])

    var ok := true
    ok = ok and int(counters.get("thought", 0)) >= 2
    ok = ok and int(counters.get("dialogue", 0)) >= 1
    ok = ok and int(counters.get("dream", 0)) >= 2
    ok = ok and dependency_errors.is_empty()

    # Verify dream/thought memories are persisted with explicit non-factual labels.
    var backstory = controller.get("_backstory_service")
    var recall_1: Dictionary = backstory.get_memory_recall_candidates("npc_c1", 1, 32, true)
    var recall_2: Dictionary = backstory.get_memory_recall_candidates("npc_c2", 1, 32, true)
    ok = ok and bool(recall_1.get("ok", false)) and bool(recall_2.get("ok", false))

    var seen_dream := false
    var seen_thought := false
    for row_variant in recall_1.get("candidates", []):
        if not (row_variant is Dictionary):
            continue
        var row: Dictionary = row_variant
        var kind := String(row.get("memory_kind", ""))
        if kind == "dream":
            seen_dream = true
            seen_dream = seen_dream and bool(row.get("is_dream", false))
        if kind == "thought":
            seen_thought = true
            seen_thought = seen_thought and not bool(row.get("is_dream", true))

    ok = ok and seen_dream and seen_thought

    runtime.call("unload_model")
    controller.queue_free()
    if not ok:
        push_error("Cognition counters: %s" % JSON.stringify(counters, "", false, true))
        push_error("Cognition dependency errors: %s" % JSON.stringify(dependency_errors, "", false, true))
        push_error("Villager cognition test failed")
        return false
    print("Villager cognition test passed")
    return true

func _cognition_runtime_skip_reason() -> String:
    if not Engine.has_singleton("AgentRuntime"):
        return "AgentRuntime singleton unavailable"
    var runtime: Object = Engine.get_singleton("AgentRuntime")
    if runtime == null:
        return "AgentRuntime singleton unavailable"
    if not runtime.has_method("load_model"):
        return "AgentRuntime.load_model unavailable"
    var base_url := _cognition_backend_base_url()
    var endpoint := _parse_backend_endpoint(base_url)
    var host := String(endpoint.get("host", "127.0.0.1"))
    var port := int(endpoint.get("port", 8080))
    if not _is_tcp_endpoint_reachable(host, port, 750):
        return "cognition HTTP backend unreachable at %s" % base_url
    return ""

func _cognition_backend_base_url() -> String:
    for key in [
        "LOCAL_AGENTS_TEST_COGNITION_BASE_URL",
        "LOCAL_AGENTS_COGNITION_BASE_URL",
        "LOCAL_AGENTS_SERVER_BASE_URL",
    ]:
        var value := OS.get_environment(key).strip_edges()
        if value != "":
            return value
    return "http://127.0.0.1:8080"

func _parse_backend_endpoint(base_url: String) -> Dictionary:
    var cleaned := base_url.strip_edges()
    if cleaned == "":
        return {"host": "127.0.0.1", "port": 8080}
    var scheme_idx := cleaned.find("://")
    if scheme_idx >= 0:
        cleaned = cleaned.substr(scheme_idx + 3)
    var slash_idx := cleaned.find("/")
    if slash_idx >= 0:
        cleaned = cleaned.substr(0, slash_idx)
    var host := cleaned
    var port := 8080
    var colon_idx := cleaned.rfind(":")
    if colon_idx > 0 and colon_idx < cleaned.length() - 1:
        host = cleaned.substr(0, colon_idx)
        port = int(cleaned.substr(colon_idx + 1))
    if host == "":
        host = "127.0.0.1"
    return {"host": host, "port": port}

func _is_tcp_endpoint_reachable(host: String, port: int, timeout_ms: int) -> bool:
    var peer := StreamPeerTCP.new()
    var err := peer.connect_to_host(host, port)
    if err != OK:
        return false
    var deadline_ms := Time.get_ticks_msec() + maxi(50, timeout_ms)
    while true:
        var status := peer.get_status()
        if status == StreamPeerTCP.STATUS_CONNECTED:
            peer.disconnect_from_host()
            return true
        if status != StreamPeerTCP.STATUS_CONNECTING:
            peer.disconnect_from_host()
            return false
        if Time.get_ticks_msec() >= deadline_ms:
            peer.disconnect_from_host()
            return false
        OS.delay_msec(25)
    return false
