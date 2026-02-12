@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")

func run_test(tree: SceneTree) -> bool:
	var baseline = SimulationControllerScript.new()
	var cued = SimulationControllerScript.new()
	tree.get_root().add_child(baseline)
	tree.get_root().add_child(cued)

	baseline.configure("seed-culture-policy", false, false)
	cued.configure("seed-culture-policy", false, false)
	baseline.set_cognition_features(false, false, false)
	cued.set_cognition_features(false, false, false)
	baseline.register_villager("npc_cp_1", "CP1", {"household_id": "home_cp"})
	baseline.register_villager("npc_cp_2", "CP2", {"household_id": "home_cp"})
	cued.register_villager("npc_cp_1", "CP1", {"household_id": "home_cp"})
	cued.register_villager("npc_cp_2", "CP2", {"household_id": "home_cp"})

	cued.set_culture_context_cues({
		"oral_topic_drivers": {
			"water_route_reliability": {
				"salience": 1.0,
				"gain_loss": 1.0,
				"tags": ["water", "ownership"],
			},
			"ritual_obligation": {
				"salience": 1.0,
				"gain_loss": 1.0,
				"tags": ["ritual", "water"],
			},
		},
	})

	var baseline_last: Dictionary = {}
	var cued_last: Dictionary = {}
	for tick in range(1, 97):
		baseline_last = baseline.process_tick(tick, 1.0)
		cued_last = cued.process_tick(tick, 1.0)

	var baseline_state: Dictionary = baseline_last.get("state", {})
	var cued_state: Dictionary = cued_last.get("state", {})
	var baseline_policy: Dictionary = baseline_state.get("cultural_policy", {})
	var cued_policy: Dictionary = cued_state.get("cultural_policy", {})
	if float(cued_policy.get("water_conservation", 0.0)) <= float(baseline_policy.get("water_conservation", 0.0)):
		push_error("Expected culture policy cues to increase water_conservation policy strength")
		baseline.queue_free()
		cued.queue_free()
		return false

	var baseline_partial = int(baseline_state.get("partial_delivery_count", 0))
	var cued_partial = int(cued_state.get("partial_delivery_count", 0))
	if cued_partial > baseline_partial:
		push_error("Expected culture policy cues to not worsen partial delivery count")
		baseline.queue_free()
		cued.queue_free()
		return false

	var saw_context_cue_driver = false
	for driver_variant in (cued_state.get("culture_driver_events", []) as Array):
		if not (driver_variant is Dictionary):
			continue
		var driver = driver_variant as Dictionary
		var label = String(driver.get("label", ""))
		if label.begins_with("context_cue_"):
			saw_context_cue_driver = true
			break
	if not saw_context_cue_driver:
		push_error("Expected context cue drivers in cued culture events")
		baseline.queue_free()
		cued.queue_free()
		return false

	baseline.queue_free()
	cued.queue_free()
	print("Simulation culture policy effects test passed")
	return true
