@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const StructureLifecycleConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/StructureLifecycleConfigResource.gd")
const NativeComputeBridgeScript = preload("res://addons/local_agents/simulation/controller/NativeComputeBridge.gd")

func run_test(tree: SceneTree) -> bool:
	var sim = SimulationControllerScript.new()
	tree.get_root().add_child(sim)
	sim.configure("seed-settlement-growth", false, false)
	sim.set_cognition_features(false, false, false)

	var growth = StructureLifecycleConfigResourceScript.new()
	growth.crowding_members_per_hut_threshold = 1.3
	growth.throughput_expand_threshold = 0.2
	growth.expand_cooldown_ticks = 1
	growth.low_throughput_abandon_threshold = 999.0
	growth.abandon_sustain_ticks = 999
	sim.set_structure_lifecycle_config(growth)

	for i in range(0, 6):
		sim.register_villager("npc_sg_%d" % i, "SG_%d" % i, {"household_id": "home_growth"})

	var native_available := _is_native_structure_lifecycle_available()
	var dependency_errors: Array[String] = []
	sim.simulation_dependency_error.connect(func(tick, phase, error_code):
		dependency_errors.append("%d:%s:%s" % [int(tick), String(phase), String(error_code)])
	)

	var expanded = false
	var max_huts = 0
	for tick in range(1, 28):
		var result: Dictionary = sim.process_tick(tick, 1.0)
		var state: Dictionary = result.get("state", {})
		var events: Dictionary = state.get("structure_lifecycle_events", {})
		if not (events.get("expanded", []) as Array).is_empty():
			expanded = true
		var structures: Dictionary = state.get("structures", {})
		var huts: Array = structures.get("home_growth", [])
		max_huts = maxi(max_huts, huts.size())

	if not native_available:
		sim.queue_free()
		var saw_structure_failure := false
		for row in dependency_errors:
			if row.find(":structure_lifecycle:gpu_required") != -1 \
				or row.find(":structure_lifecycle:gpu_unavailable") != -1 \
				or row.find(":structure_lifecycle:native_required") != -1 \
				or row.find(":structure_lifecycle:native_unavailable") != -1:
				saw_structure_failure = true
				break
		if expanded:
			push_error("Expected no structure lifecycle expansion when native/GPU lifecycle path is unavailable")
			return false
		if not saw_structure_failure:
			push_error("Expected structure lifecycle dependency error with typed native/GPU required semantics when native path is unavailable")
			return false
		print("Settlement growth native-unavailable contract test passed")
		return true

	if not expanded:
		push_error("Expected settlement growth to expand huts under sustained crowding/throughput")
		sim.queue_free()
		return false
	if max_huts < 2:
		push_error("Expected at least two huts for crowded household")
		sim.queue_free()
		return false

	var contraction = StructureLifecycleConfigResourceScript.new()
	contraction.crowding_members_per_hut_threshold = 999.0
	contraction.throughput_expand_threshold = 999.0
	contraction.low_throughput_abandon_threshold = 999.0
	contraction.low_path_strength_abandon_threshold = 1.0
	contraction.abandon_sustain_ticks = 1
	contraction.min_huts_per_household = 1
	sim.set_structure_lifecycle_config(contraction)

	var abandoned = false
	for tick in range(28, 36):
		var result: Dictionary = sim.process_tick(tick, 1.0)
		var state: Dictionary = result.get("state", {})
		var events: Dictionary = state.get("structure_lifecycle_events", {})
		if not (events.get("abandoned", []) as Array).is_empty():
			abandoned = true
			break

	sim.queue_free()
	if not abandoned:
		push_error("Expected settlement growth to abandon a hut under sustained low-access pressure")
		return false

	print("Settlement growth deterministic test passed")
	return true

func _is_native_structure_lifecycle_available() -> bool:
	if not Engine.has_singleton(NativeComputeBridgeScript.NATIVE_SIM_CORE_SINGLETON_NAME):
		return false
	var core = Engine.get_singleton(NativeComputeBridgeScript.NATIVE_SIM_CORE_SINGLETON_NAME)
	if core == null:
		return false
	return core.has_method("step_structure_lifecycle")
