@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")

const PARITY_EPSILON := 0.0001
const MAX_TICKS := 72

func run_test(tree: SceneTree) -> bool:
	var controller_a = SimulationControllerScript.new()
	var controller_b = SimulationControllerScript.new()
	tree.get_root().add_child(controller_a)
	tree.get_root().add_child(controller_b)

	_configure_controller(controller_a, "seed-material-flow-parity")
	_configure_controller(controller_b, "seed-material-flow-parity")

	var emitted_ticks := 0
	for tick in range(1, MAX_TICKS + 1):
		var result_a: Dictionary = controller_a.process_tick(tick, 1.0)
		var result_b: Dictionary = controller_b.process_tick(tick, 1.0)
		if not bool(result_a.get("ok", false)) or not bool(result_b.get("ok", false)):
			push_error("Material-flow parity tick failed at %d" % tick)
			controller_a.queue_free()
			controller_b.queue_free()
			return false

		var state_a: Dictionary = result_a.get("state", {})
		var state_b: Dictionary = result_b.get("state", {})
		var snapshot_a = _find_unified_material_flow_snapshot(state_a)
		var snapshot_b = _find_unified_material_flow_snapshot(state_b)
		var has_a = snapshot_a is Dictionary and not (snapshot_a as Dictionary).is_empty()
		var has_b = snapshot_b is Dictionary and not (snapshot_b as Dictionary).is_empty()

		if has_a != has_b:
			push_error("Canonical material-flow snapshot presence diverged at tick %d" % tick)
			controller_a.queue_free()
			controller_b.queue_free()
			return false
		if not has_a:
			continue

		emitted_ticks += 1
		var mismatch = _compare_variants(snapshot_a, snapshot_b, "snapshot")
		if mismatch != "":
			push_error("Canonical material-flow parity mismatch at tick %d: %s" % [tick, mismatch])
			controller_a.queue_free()
			controller_b.queue_free()
			return false

	controller_a.queue_free()
	controller_b.queue_free()

	if emitted_ticks == 0:
		print("Simulation material-flow parity test skipped: unified material-flow snapshot not emitted yet.")
		return true

	print("Simulation material-flow parity test passed (%d emitted ticks, epsilon=%f)." % [emitted_ticks, PARITY_EPSILON])
	return true

func _configure_controller(controller, seed_text: String) -> void:
	controller.configure(seed_text, false, false)
	controller.set_cognition_features(false, false, false)
	controller.register_villager("npc_m1", "M1", {"household_id": "home_m1", "profession": "farmer"})
	controller.register_villager("npc_m2", "M2", {"household_id": "home_m1", "profession": "merchant"})
	controller.register_villager("npc_m3", "M3", {"household_id": "home_m2", "profession": "woodcutter"})
	if controller.has_method("set_native_view_metrics"):
		controller.call("set_native_view_metrics", {
			"camera_distance": 24.0,
			"zoom_factor": 0.35,
			"uniformity_score": 0.5,
			"compute_budget_scale": 1.0,
		})

func _find_unified_material_flow_snapshot(state: Dictionary) -> Variant:
	if state.is_empty():
		return {}
	for key in [
		"unified_material_flow_snapshot",
		"material_flow_unified_snapshot",
		"material_flow_snapshot",
		"material_flow",
	]:
		var value = state.get(key, null)
		if value is Dictionary and not (value as Dictionary).is_empty():
			return value

	var economy: Dictionary = state.get("economy_snapshot", {})
	for key in ["unified_material_flow_snapshot", "material_flow_snapshot", "material_flow"]:
		var value = economy.get(key, null)
		if value is Dictionary and not (value as Dictionary).is_empty():
			return value

	var signals: Dictionary = state.get("environment_signals", {})
	for key in ["unified_material_flow_snapshot", "material_flow_snapshot"]:
		var value = signals.get(key, null)
		if value is Dictionary and not (value as Dictionary).is_empty():
			return value
	return {}

func _compare_variants(a: Variant, b: Variant, path: String) -> String:
	if a is Dictionary and b is Dictionary:
		var left = a as Dictionary
		var right = b as Dictionary
		if left.size() != right.size():
			return "%s size mismatch (%d vs %d)" % [path, left.size(), right.size()]
		for key in left.keys():
			if not right.has(key):
				return "%s missing key %s" % [path, String(key)]
			var mismatch = _compare_variants(left.get(key), right.get(key), "%s.%s" % [path, String(key)])
			if mismatch != "":
				return mismatch
		return ""
	if a is Array and b is Array:
		var left_a = a as Array
		var right_a = b as Array
		if left_a.size() != right_a.size():
			return "%s array size mismatch (%d vs %d)" % [path, left_a.size(), right_a.size()]
		for i in range(left_a.size()):
			var mismatch = _compare_variants(left_a[i], right_a[i], "%s[%d]" % [path, i])
			if mismatch != "":
				return mismatch
		return ""
	if _is_number(a) and _is_number(b):
		var left_f = float(a)
		var right_f = float(b)
		if absf(left_f - right_f) > PARITY_EPSILON:
			return "%s numeric mismatch (%f vs %f, epsilon=%f)" % [path, left_f, right_f, PARITY_EPSILON]
		return ""
	if a != b:
		return "%s mismatch (%s vs %s)" % [path, String(a), String(b)]
	return ""

func _is_number(value: Variant) -> bool:
	var t = typeof(value)
	return t == TYPE_FLOAT or t == TYPE_INT
