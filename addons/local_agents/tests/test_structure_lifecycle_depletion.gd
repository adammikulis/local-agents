@tool
extends RefCounted

const StructureLifecycleSystemScript = preload("res://addons/local_agents/simulation/StructureLifecycleSystem.gd")
const StructureLifecycleConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/StructureLifecycleConfigResource.gd")

func run_test(_tree: SceneTree) -> bool:
	var a = StructureLifecycleSystemScript.new()
	var b = StructureLifecycleSystemScript.new()
	var config = StructureLifecycleConfigResourceScript.new()
	config.throughput_expand_threshold = 1.0
	config.depletion_signal_threshold = 0.4
	config.path_extension_trigger_ticks = 2
	config.depletion_sustain_ticks = 3
	config.camp_spawn_cooldown_ticks = 4
	config.max_temporary_camps_per_household = 2
	a.set_config(config)
	b.set_config(config)
	a.ensure_core_anchors(Vector3.ZERO)
	b.ensure_core_anchors(Vector3.ZERO)

	var events_a: Array = []
	var events_b: Array = []
	for tick in range(1, 7):
		var result_a = a.step_lifecycle(
			tick,
			{"home_1": 4},
			{"home_1": {"throughput": 0.05, "path_strength": 0.0, "partial_delivery_ratio": 0.9}},
			{"home_1": Vector3(2.0, 0.0, -1.0)},
			{}
		)
		var result_b = b.step_lifecycle(
			tick,
			{"home_1": 4},
			{"home_1": {"throughput": 0.05, "path_strength": 0.0, "partial_delivery_ratio": 0.9}},
			{"home_1": Vector3(2.0, 0.0, -1.0)},
			{}
		)
		events_a.append(_event_signature(result_a))
		events_b.append(_event_signature(result_b))

	if events_a != events_b:
		push_error("Expected deterministic depletion lifecycle signatures for identical inputs")
		return false

	var saw_path_extension = false
	var saw_camp = false
	for event_variant in events_a:
		if not (event_variant is Dictionary):
			continue
		var event = event_variant as Dictionary
		if int(event.get("path_extensions", 0)) > 0:
			saw_path_extension = true
		if int(event.get("camps", 0)) > 0:
			saw_camp = true
	if not saw_path_extension:
		push_error("Expected path extension pressure event under sustained depletion")
		return false
	if not saw_camp:
		push_error("Expected temporary camp spawn under sustained depletion")
		return false

	for tick in range(7, 13):
		a.step_lifecycle(
			tick,
			{"home_1": 4},
			{"home_1": {"throughput": 1.3, "path_strength": 0.95, "partial_delivery_ratio": 0.0}},
			{"home_1": Vector3(2.0, 0.0, -1.0)},
			{}
		)
	var structures: Dictionary = a.export_structures()
	var home_rows: Array = structures.get("home_1", [])
	var active_camps = 0
	var abandoned_camps = 0
	for row_variant in home_rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		if String(row.get("structure_type", "")) != "camp_temp":
			continue
		if String(row.get("state", "")) == "active":
			active_camps += 1
		elif String(row.get("state", "")) == "abandoned":
			abandoned_camps += 1
	if active_camps != 0:
		push_error("Expected temporary camps to retire once depletion pressure clears")
		return false
	if abandoned_camps <= 0:
		push_error("Expected at least one abandoned temporary camp after recovery")
		return false

	print("Structure lifecycle depletion deterministic test passed")
	return true

func _event_signature(result: Dictionary) -> Dictionary:
	var paths: Array = result.get("path_extensions", [])
	var camps: Array = result.get("camps", [])
	var expanded: Array = result.get("expanded", [])
	var abandoned: Array = result.get("abandoned", [])
	return {
		"path_extensions": paths.size(),
		"camps": camps.size(),
		"expanded": expanded.size(),
		"abandoned": abandoned.size(),
	}
