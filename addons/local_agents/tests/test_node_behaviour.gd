@tool
extends RefCounted


const AgentStatusScript: GDScript = preload("res://addons/local_agents/runtime/AgentStatus.gd")
const AgentScript: GDScript = preload("res://addons/local_agents/agents/Agent.gd")
const RUNTIME_SINGLETON: String = "AgentRuntime"


class StubRuntime extends Object:
	var load_calls: Array = []
	var next_result: bool = true
	var loaded: bool = false

	func load_model(model_path: String, options: Dictionary) -> bool:
		load_calls.append({"path": model_path, "options": options.duplicate(true)})
		loaded = next_result
		return next_result

	func is_model_loaded() -> bool:
		return loaded


class StubAgentNode extends Object:
	var tick_enabled: bool = false
	var tick_interval: float = 1.0
	var max_actions_per_tick: int = 4
	var db_path: String = ""
	var voice: String = ""
	var default_model_path: String = ""
	var runtime_directory: String = ""

	var think_calls: Array = []
	var messages: Array = []
	var reply: String = "pong"

	func clear_history() -> void:
		messages.clear()

	func add_message(role: String, content: String) -> void:
		messages.append({"role": role, "content": content})

	func get_history() -> Array:
		return messages.duplicate(true)

	func think(prompt: String, options: Dictionary) -> Dictionary:
		think_calls.append({"prompt": prompt, "options": options.duplicate(true)})
		return {"ok": true, "text": reply}


var _failures: Array[String] = []


func run_test(tree: SceneTree) -> bool:
	_failures.clear()
	_test_status_load_model()
	_test_agent_system_prompt(tree)
	_test_configure_keeps_load_options(tree)
	_test_creature_spawner(tree)
	_test_demo_harness_frame_mode(tree)
	if _failures.is_empty():
		print("Local Agents node behaviour tests passed.")
		return true
	for line in _failures:
		push_error(line)
	return false


func _test_status_load_model() -> void:
	var had_real: bool = Engine.has_singleton(RUNTIME_SINGLETON)
	var real_runtime: Object = Engine.get_singleton(RUNTIME_SINGLETON) if had_real else null
	if had_real:
		Engine.unregister_singleton(RUNTIME_SINGLETON)
	var stub: StubRuntime = StubRuntime.new()
	Engine.register_singleton(RUNTIME_SINGLETON, stub)

	# No early returns inside the swap: the real singleton must be put back whatever happens.
	_assert_load_model_contract(stub)

	Engine.unregister_singleton(RUNTIME_SINGLETON)
	stub.free()
	if had_real:
		Engine.register_singleton(RUNTIME_SINGLETON, real_runtime)
		if Engine.get_singleton(RUNTIME_SINGLETON) != real_runtime:
			_fail("Failed to restore the real AgentRuntime singleton; later tests would run against nothing.")
		elif not AgentStatusScript.check().has("model_loaded"):
			_fail("LocalAgentStatus.check() stopped answering after the singleton was restored.")


func _assert_load_model_contract(stub: StubRuntime) -> void:
	# An empty path never reaches the runtime.
	if AgentStatusScript.load_model(""):
		_fail("LocalAgentStatus.load_model(\"\") returned true; an empty path must not load anything.")
	if not stub.load_calls.is_empty():
		_fail("LocalAgentStatus.load_model(\"\") still called the runtime.")

	# THE two-argument contract. A one-argument call cannot satisfy StubRuntime.load_model, so it
	# would return false here and record nothing.
	var first_path: String = "/tmp/local_agents_test_a.gguf"
	if not AgentStatusScript.load_model(first_path, {"context_size": 128}):
		_fail("LocalAgentStatus.load_model(path, options) failed against a runtime that accepts (model_path, options) - it is not passing both arguments.")
	if stub.load_calls.size() != 1:
		_fail("Expected exactly 1 runtime load_model call, got %d." % stub.load_calls.size())
	else:
		var call: Dictionary = stub.load_calls[0]
		if String(call["path"]) != first_path:
			_fail("Runtime was asked to load '%s', expected '%s'." % [String(call["path"]), first_path])
		var options: Dictionary = call["options"]
		if int(options.get("context_size", -1)) != 128:
			_fail("The options argument did not reach the runtime: got %s." % str(options))
	if AgentStatusScript.resident_model_path() != first_path:
		_fail("resident_model_path() is '%s' after a successful load of '%s'." % [AgentStatusScript.resident_model_path(), first_path])

	# Same path, still resident: short-circuits rather than reloading (the runtime always unloads and
	# re-reads from disk, so a speculative call is a real cost).
	AgentStatusScript.load_model(first_path, {})
	if stub.load_calls.size() != 1:
		_fail("Reloading the already-resident path called the runtime again (%d calls)." % stub.load_calls.size())

	# STALENESS: the model is unloaded underneath. load_model must reload, not short-circuit.
	stub.loaded = false
	AgentStatusScript.load_model(first_path, {})
	if stub.load_calls.size() != 2:
		_fail("The resident path went stale: the model was unloaded underneath, but load_model short-circuited instead of reloading.")

	# A failed load must clear residency rather than claim the path.
	stub.next_result = false
	var second_path: String = "/tmp/local_agents_test_b.gguf"
	if AgentStatusScript.load_model(second_path, {}):
		_fail("load_model reported success for a runtime that returned false.")
	if AgentStatusScript.resident_model_path() != "":
		_fail("A failed load left '%s' recorded as resident." % AgentStatusScript.resident_model_path())

	# ensure_model_loaded() goes through the same two-argument call. Which branch it takes depends on
	# whether this machine has a model installed, so both branches are asserted rather than skipped.
	stub.next_result = true
	stub.loaded = false
	var resolved: String = AgentStatusScript.resolve_model_path()
	var before: int = stub.load_calls.size()
	var ensured: bool = AgentStatusScript.ensure_model_loaded({"context_size": 512})
	if resolved == "":
		print("  ensure_model_loaded: no model installed on this machine; asserting the no-op branch.")
		if ensured:
			_fail("ensure_model_loaded() returned true with no model path resolvable.")
		if stub.load_calls.size() != before:
			_fail("ensure_model_loaded() called the runtime with no model path resolvable.")
	else:
		print("  ensure_model_loaded: resolved %s; asserting the load branch." % resolved)
		if not ensured:
			_fail("ensure_model_loaded() failed for resolved model '%s'." % resolved)
		if stub.load_calls.size() != before + 1:
			_fail("ensure_model_loaded() made %d runtime calls, expected 1." % (stub.load_calls.size() - before))
		else:
			var call: Dictionary = stub.load_calls[before]
			if String(call["path"]) != resolved:
				_fail("ensure_model_loaded() loaded '%s', expected '%s'." % [String(call["path"]), resolved])
			if int((call["options"] as Dictionary).get("context_size", -1)) != 512:
				_fail("ensure_model_loaded() dropped its options argument.")

	# Leave the shared static residency clean for every later test in this process.
	stub.next_result = false
	AgentStatusScript.load_model("/tmp/local_agents_test_reset.gguf", {})
	if AgentStatusScript.resident_model_path() != "":
		_fail("Could not reset the tracked resident path; it is still '%s'." % AgentStatusScript.resident_model_path())


func _test_agent_system_prompt(tree: SceneTree) -> void:
	var wanted: String = "You are a terse dockside guide."
	var agent: Node = AgentScript.new()
	agent.name = "SystemPromptAgent"
	agent.system_prompt = wanted
	tree.root.add_child(agent)
	var stub: StubAgentNode = StubAgentNode.new()
	agent.agent_node = stub

	# backend forced in-process so no llama-server is started; the agent names no model, so the
	# in-process load is a no-op and nothing touches the disk.
	var result: Dictionary = agent.think("hello", {"backend": "in_process"})

	if not bool(result.get("ok", false)):
		_fail("think() failed against the stub agent node: %s" % str(result))
	var history: Array = agent.history
	if history.size() < 2:
		_fail("Expected at least a system + user message in history, got %s." % str(history))
	else:
		var head: Dictionary = history[0]
		if String(head.get("role", "")) != "system":
			_fail("history[0] role is '%s', expected 'system'." % String(head.get("role", "")))
		if String(head.get("content", "")) != wanted:
			_fail("history[0] content is '%s', expected the agent's system_prompt." % String(head.get("content", "")))
		if String((history[1] as Dictionary).get("content", "")) != "hello":
			_fail("The user message did not land after the system message: %s" % str(history))
	if history.size() >= 3 and String((history[2] as Dictionary).get("content", "")) != "pong":
		_fail("The assistant reply was not recorded: %s" % str(history))

	# The merged request: the sync path reads the NATIVE node's own history, so the system message has
	# to be mirrored across, and the options dictionary has to carry the prompt too.
	if stub.think_calls.size() != 1:
		_fail("Expected exactly 1 native think call, got %d." % stub.think_calls.size())
	else:
		var options: Dictionary = (stub.think_calls[0] as Dictionary)["options"]
		if String(options.get("system_prompt", "")) != wanted:
			_fail("system_prompt did not reach the merged request options: %s" % str(options))
	if stub.messages.is_empty():
		_fail("The system message was never mirrored into the native agent node's history.")
	elif String((stub.messages[0] as Dictionary).get("role", "")) != "system":
		_fail("The native agent node's history[0] role is '%s', expected 'system'." % String((stub.messages[0] as Dictionary).get("role", "")))

	# Applying it twice must not stack a second system message.
	agent.think("again", {"backend": "in_process"})
	var systems: int = 0
	for entry_variant in agent.history:
		if entry_variant is Dictionary and String((entry_variant as Dictionary).get("role", "")) == "system":
			systems += 1
	if systems != 1:
		_fail("The conversation holds %d system messages; the prompt must be applied idempotently." % systems)

	tree.root.remove_child(agent)
	agent.free()
	stub.free()


func _test_configure_keeps_load_options(tree: SceneTree) -> void:
	var agent: Node = AgentScript.new()
	agent.name = "ConfigureAgent"
	tree.root.add_child(agent)
	var stub: StubAgentNode = StubAgentNode.new()
	agent.agent_node = stub

	agent.load_options = {"context_size": 8192, "n_gpu_layers": 33}
	agent.inference_options = {"temperature": 0.9}

	var params: LocalAgentInferenceParams = LocalAgentInferenceParams.new()
	params.temperature = 0.11
	agent.configure(null, params)

	var load_options: Dictionary = agent.load_options
	if int(load_options.get("context_size", -1)) != 8192:
		_fail("configure(null, preset) dropped load_options.context_size: %s" % str(load_options))
	if int(load_options.get("n_gpu_layers", -1)) != 33:
		_fail("configure(null, preset) dropped load_options.n_gpu_layers: %s" % str(load_options))
	if absf(float(agent.inference_options.get("temperature", -1.0)) - 0.11) > 0.0001:
		_fail("configure(null, preset) did not replace inference_options: %s" % str(agent.inference_options))

	# ...and the durable knobs still reach the request afterwards.
	agent.think("hi", {"backend": "in_process"})
	if stub.think_calls.is_empty():
		_fail("think() never reached the native node after configure().")
	else:
		var options: Dictionary = (stub.think_calls[0] as Dictionary)["options"]
		if int(options.get("context_size", -1)) != 8192:
			_fail("context_size did not survive configure() into the merged request: %s" % str(options))
		if absf(float(options.get("temperature", -1.0)) - 0.11) > 0.0001:
			_fail("The new sampling preset did not reach the merged request: %s" % str(options))

	# The mirror image: a profile must not wipe the sampling preset.
	var profile: LocalAgentModelProfile = LocalAgentModelProfile.new()
	profile.context_size = 1024
	agent.configure(profile, null)
	if absf(float(agent.inference_options.get("temperature", -1.0)) - 0.11) > 0.0001:
		_fail("configure(profile, null) wiped inference_options: %s" % str(agent.inference_options))
	if int(agent.load_options.get("context_size", -1)) != 1024:
		_fail("configure(profile, null) did not apply the profile: %s" % str(agent.load_options))

	tree.root.remove_child(agent)
	agent.free()
	stub.free()


func _test_creature_spawner(tree: SceneTree) -> void:
	var spawner: LocalAgentCreatureSpawner = LocalAgentCreatureSpawner.new()
	spawner.name = "TestSpawner"
	spawner.build_floor = false
	spawner.spawn_on_ready = false
	spawner.ground_y = 3.0
	spawner.placement_seed = 7
	spawner.area_extent = Vector3(10.0, 0.0, 10.0)
	# A typed local, because a typed Dictionary export only converts through a statically typed
	# assignment - handing it an untyped literal through set() is silently dropped.
	var wanted: Dictionary[String, int] = {"rabbit": 3, "fox": 2}
	spawner.counts = wanted
	tree.root.add_child(spawner)
	spawner.global_position = Vector3(20.0, 50.0, -20.0)

	spawner.spawn()
	var made: Array[Node] = spawner.spawned()
	if made.size() != 5:
		_fail("Spawner made %d creatures, expected 5 (rabbit 3 + fox 2)." % made.size())

	var by_species: Dictionary = {}
	for creature in made:
		var species: String = String(creature.get("species"))
		by_species[species] = int(by_species.get(species, 0)) + 1
		if not (creature is Node3D):
			_fail("A spawned creature is not a Node3D.")
			continue
		var where: Vector3 = (creature as Node3D).global_position
		# ground_y is an ABSOLUTE world height, not an offset from the spawner: raising the spawner
		# must not raise where its creatures are dropped.
		if absf(where.y - spawner.ground_y) > 0.001:
			_fail("A creature was placed at y=%.3f, expected ground_y=%.3f." % [where.y, spawner.ground_y])
		if absf(where.x - spawner.global_position.x) > 5.001 or absf(where.z - spawner.global_position.z) > 5.001:
			_fail("A creature at %s fell outside the %s scatter box centred on the spawner." % [str(where), str(spawner.area_extent)])
		if not creature.is_in_group("la_creatures"):
			_fail("A spawned creature is not in the la_creatures group, so no scheduler can adopt it.")
	if int(by_species.get("rabbit", 0)) != 3 or int(by_species.get("fox", 0)) != 2:
		_fail("Spawned population is %s, expected 3 rabbit + 2 fox." % str(by_species))

	# Spawning twice replaces the population rather than stacking a second one on top.
	spawner.spawn()
	if spawner.spawned().size() != 5:
		_fail("A second spawn() left %d creatures, expected the population to be replaced." % spawner.spawned().size())
	spawner.clear()
	if not spawner.spawned().is_empty():
		_fail("clear() left %d creatures behind." % spawner.spawned().size())

	tree.root.remove_child(spawner)
	spawner.free()


# Which callback is routed into the counter is asserted by invoking them directly, so the answer does
# not depend on how many render frames the machine happened to draw. That real frames actually reach
# an in-tree harness is asserted separately, in run_frame_probe.gd.
func _test_demo_harness_frame_mode(tree: SceneTree) -> void:
	var host: Node = Node.new()
	host.name = "HarnessHost"
	tree.root.add_child(host)

	# A run length is PHYSICS ticks and there is no other option: render frames must never advance it.
	var harness: LocalAgentDemoHarness = _make_harness(host)
	for i in range(5):
		harness._process(0.016)
	if harness.frames_elapsed() != 0:
		_fail("render frames advanced the run length by %d." % harness.frames_elapsed())
	for i in range(3):
		harness._physics_process(0.016)
	if harness.frames_elapsed() != 3:
		_fail("3 physics ticks counted as %d." % harness.frames_elapsed())

	tree.root.remove_child(host)
	host.free()


# run_frames is set AFTER add_child on purpose: _ready() parses the command line, and a harness armed
# with a small run_frames would quit the whole test process the moment it ticked.
func _make_harness(host: Node) -> LocalAgentDemoHarness:
	var harness: LocalAgentDemoHarness = LocalAgentDemoHarness.new()
	harness.report_source = host
	host.add_child(harness)
	harness.run_frames = 1000000
	harness.shoot_path = ""
	return harness


func _fail(message: String) -> void:
	if not _failures.has(message):
		_failures.append(message)
