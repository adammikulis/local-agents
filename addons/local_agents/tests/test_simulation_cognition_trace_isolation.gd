@tool
extends RefCounted

const SimulationControllerScript := preload("res://addons/local_agents/simulation/SimulationController.gd")
const TestModelHelper := preload("res://addons/local_agents/tests/test_model_helper.gd")

func run_test(tree: SceneTree) -> bool:
	if not ClassDB.class_exists("NetworkGraph"):
		push_error("Cognition trace isolation test requires NetworkGraph extension.")
		return false
	var skip_reason := _cognition_runtime_skip_reason()
	if skip_reason != "":
		print("Skipping cognition trace isolation test (%s)." % skip_reason)
		return true

	var controller = SimulationControllerScript.new()
	tree.get_root().add_child(controller)
	var runtime: Object = Engine.get_singleton("AgentRuntime") if Engine.has_singleton("AgentRuntime") else null
	if runtime == null or not runtime.has_method("load_model"):
		push_error("AgentRuntime unavailable for cognition trace isolation test")
		controller.queue_free()
		return false
	var helper = TestModelHelper.new()
	var model_path := helper.ensure_local_model()
	if model_path.strip_edges() == "":
		push_error("Cognition trace isolation test requires a local model")
		controller.queue_free()
		return false
	var load_options = helper.apply_runtime_overrides({
		"max_tokens": 128,
		"temperature": 0.2,
		"n_gpu_layers": 0,
	})
	var loaded := bool(runtime.call("load_model", model_path, load_options))
	if not loaded:
		push_error("Failed to load local model for cognition trace isolation test")
		controller.queue_free()
		return false

	var dependency_errors: Array[String] = []
	controller.simulation_dependency_error.connect(func(tick, phase, error_code):
		dependency_errors.append("%d:%s:%s" % [int(tick), String(phase), String(error_code)])
	)

	controller.configure("seed-cognition-isolation", false, true)
	controller.resource_event_logging_enabled = true
	controller.register_villager("npc_iso_alpha", "Iso Alpha", {"mood": "alert", "household_id": "home_iso"})
	controller.register_villager("npc_iso_bravo", "Iso Bravo", {"mood": "calm", "household_id": "home_iso"})
	controller.set_dream_influence("npc_iso_alpha", {"motif": "river"})
	controller.set_dream_influence("npc_iso_bravo", {"motif": "bone"})

	for tick in range(1, 49):
		var tick_result: Dictionary = controller.process_tick(tick, 1.0)
		if not bool(tick_result.get("ok", false)):
			dependency_errors.append("%d:%s:%s" % [tick, String(tick_result.get("phase", "unknown")), String(tick_result.get("error", "tick_failed"))])

	var ok := dependency_errors.is_empty()
	var traces: Array = controller.list_llm_trace_events(1, 49)
	ok = ok and not traces.is_empty()

	var seen_tasks := {
		"thought_generation": 0,
		"dialogue_exchange": 0,
		"dream_generation": 0,
	}
	for trace_variant in traces:
		if not (trace_variant is Dictionary):
			continue
		var trace: Dictionary = trace_variant
		var task = String(trace.get("task", ""))
		if task == "internal_thought":
			task = "thought_generation"
		if seen_tasks.has(task):
			seen_tasks[task] = int(seen_tasks.get(task, 0)) + 1
		var profile_id = String(trace.get("profile_id", ""))
		if profile_id.strip_edges() == "":
			ok = false
			push_error("Trace missing profile_id for task=%s" % task)
		var sampler: Dictionary = trace.get("sampler_params", {})
		for key in ["seed", "temperature", "top_p", "max_tokens", "stop", "reset_context", "cache_prompt"]:
			if not sampler.has(key):
				ok = false
				push_error("Trace sampler_params missing key %s for task=%s" % [key, task])
		if not bool(sampler.get("reset_context", false)):
			ok = false
			push_error("reset_context must be true for task=%s" % task)
		if bool(sampler.get("cache_prompt", true)):
			ok = false
			push_error("cache_prompt must be false for task=%s" % task)

		var actor_ids: Array = trace.get("actor_ids", [])
		var referenced_ids: Array = trace.get("referenced_ids", [])
		if task == "internal_thought" or task == "dream_generation":
			if actor_ids.size() != 1 or referenced_ids.size() != 1:
				ok = false
				push_error("Expected one actor/ref id for %s trace" % task)
			elif String(actor_ids[0]) != String(referenced_ids[0]):
				ok = false
				push_error("Actor/ref mismatch for %s trace: %s vs %s" % [task, String(actor_ids[0]), String(referenced_ids[0])])
		elif task == "dialogue_exchange":
			if actor_ids.size() != 2 or referenced_ids.size() != 2:
				ok = false
				push_error("Expected two actor/ref ids for dialogue trace")
			else:
				var actors = actor_ids.duplicate()
				var refs = referenced_ids.duplicate()
				actors.sort()
				refs.sort()
				if actors != refs:
					ok = false
					push_error("Dialogue trace actor/ref sets differ")

		for required in ["thought_generation", "dialogue_exchange", "dream_generation"]:
			if int(seen_tasks.get(required, 0)) <= 0:
				ok = false
				push_error("Missing required trace task: %s" % required)

	runtime.call("unload_model")
	controller.queue_free()
	if not ok:
		push_error("Trace isolation dependency errors: %s" % JSON.stringify(dependency_errors, "", false, true))
		push_error("Trace isolation seen_tasks: %s" % JSON.stringify(seen_tasks, "", false, true))
		push_error("Cognition trace isolation test failed")
		return false
	print("Cognition trace isolation test passed")
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
