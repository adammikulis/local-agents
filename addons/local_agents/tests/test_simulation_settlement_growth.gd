@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const SettlementGrowthConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/SettlementGrowthConfigResource.gd")

func run_test(tree: SceneTree) -> bool:
	var sim = SimulationControllerScript.new()
	tree.get_root().add_child(sim)
	sim.configure("seed-settlement-growth", false, false)
	sim.set_cognition_features(false, false, false)

	var growth = SettlementGrowthConfigResourceScript.new()
	growth.crowding_members_per_hut_threshold = 1.3
	growth.throughput_expand_threshold = 0.2
	growth.expand_cooldown_ticks = 1
	growth.low_throughput_abandon_threshold = 999.0
	growth.abandon_sustain_ticks = 999
	sim.set_settlement_growth_config(growth)

	for i in range(0, 6):
		sim.register_villager("npc_sg_%d" % i, "SG_%d" % i, {"household_id": "home_growth"})

	var expanded = false
	var max_huts = 0
	for tick in range(1, 28):
		var result: Dictionary = sim.process_tick(tick, 1.0)
		var state: Dictionary = result.get("state", {})
		var events: Dictionary = state.get("settlement_growth_events", {})
		if not (events.get("expanded", []) as Array).is_empty():
			expanded = true
		var structures: Dictionary = state.get("settlement_structures", {})
		var huts: Array = structures.get("home_growth", [])
		max_huts = maxi(max_huts, huts.size())

	if not expanded:
		push_error("Expected settlement growth to expand huts under sustained crowding/throughput")
		sim.queue_free()
		return false
	if max_huts < 2:
		push_error("Expected at least two huts for crowded household")
		sim.queue_free()
		return false

	var contraction = SettlementGrowthConfigResourceScript.new()
	contraction.crowding_members_per_hut_threshold = 999.0
	contraction.throughput_expand_threshold = 999.0
	contraction.low_throughput_abandon_threshold = 999.0
	contraction.low_path_strength_abandon_threshold = 1.0
	contraction.abandon_sustain_ticks = 1
	contraction.min_huts_per_household = 1
	sim.set_settlement_growth_config(contraction)

	var abandoned = false
	for tick in range(28, 36):
		var result: Dictionary = sim.process_tick(tick, 1.0)
		var state: Dictionary = result.get("state", {})
		var events: Dictionary = state.get("settlement_growth_events", {})
		if not (events.get("abandoned", []) as Array).is_empty():
			abandoned = true
			break

	sim.queue_free()
	if not abandoned:
		push_error("Expected settlement growth to abandon a hut under sustained low-access pressure")
		return false

	print("Settlement growth deterministic test passed")
	return true
