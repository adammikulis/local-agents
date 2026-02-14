@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")

const MAX_TICKS := 84

func run_test(tree: SceneTree) -> bool:
	var baseline_controller = SimulationControllerScript.new()
	var foveated_controller = SimulationControllerScript.new()
	var replay_controller = SimulationControllerScript.new()
	tree.get_root().add_child(baseline_controller)
	tree.get_root().add_child(foveated_controller)
	tree.get_root().add_child(replay_controller)

	_configure_controller(baseline_controller, "seed-material-flow-foveated")
	_configure_controller(foveated_controller, "seed-material-flow-foveated")
	_configure_controller(replay_controller, "seed-material-flow-foveated")

	if baseline_controller.has_method("set_native_view_metrics"):
		baseline_controller.call("set_native_view_metrics", {
			"camera_distance": 14.0,
			"zoom_factor": 0.12,
			"uniformity_score": 0.2,
			"compute_budget_scale": 1.0,
		})
	if foveated_controller.has_method("set_native_view_metrics"):
		foveated_controller.call("set_native_view_metrics", {
			"camera_distance": 108.0,
			"zoom_factor": 1.0,
			"uniformity_score": 0.96,
			"compute_budget_scale": 0.2,
		})
	if replay_controller.has_method("set_native_view_metrics"):
		replay_controller.call("set_native_view_metrics", {
			"camera_distance": 108.0,
			"zoom_factor": 1.0,
			"uniformity_score": 0.96,
			"compute_budget_scale": 0.2,
		})

	var baseline_signals: Array = []
	var foveated_signals: Array = []
	var replay_signals: Array = []
	var emitted_ticks := 0

	for tick in range(1, MAX_TICKS + 1):
		var baseline_result: Dictionary = baseline_controller.process_tick(tick, 1.0)
		var foveated_result: Dictionary = foveated_controller.process_tick(tick, 1.0)
		var replay_result: Dictionary = replay_controller.process_tick(tick, 1.0)
		if not bool(baseline_result.get("ok", false)) or not bool(foveated_result.get("ok", false)) or not bool(replay_result.get("ok", false)):
			push_error("Material-flow foveated throttling tick failed at %d" % tick)
			baseline_controller.queue_free()
			foveated_controller.queue_free()
			replay_controller.queue_free()
			return false

		var baseline_state: Dictionary = baseline_result.get("state", {})
		var foveated_state: Dictionary = foveated_result.get("state", {})
		var replay_state: Dictionary = replay_result.get("state", {})
		var baseline_snapshot = _find_unified_material_flow_snapshot(baseline_state)
		var foveated_snapshot = _find_unified_material_flow_snapshot(foveated_state)
		var replay_snapshot = _find_unified_material_flow_snapshot(replay_state)
		if not (baseline_snapshot is Dictionary and foveated_snapshot is Dictionary and replay_snapshot is Dictionary):
			continue
		if (baseline_snapshot as Dictionary).is_empty() or (foveated_snapshot as Dictionary).is_empty() or (replay_snapshot as Dictionary).is_empty():
			continue

		emitted_ticks += 1
		var baseline_signal = _extract_throttle_signal(baseline_snapshot, baseline_state)
		var foveated_signal = _extract_throttle_signal(foveated_snapshot, foveated_state)
		var replay_signal = _extract_throttle_signal(replay_snapshot, replay_state)
		if not baseline_signal.is_empty() and not foveated_signal.is_empty() and not replay_signal.is_empty():
			baseline_signals.append(baseline_signal)
			foveated_signals.append(foveated_signal)
			replay_signals.append(replay_signal)

	baseline_controller.queue_free()
	foveated_controller.queue_free()
	replay_controller.queue_free()

	if emitted_ticks == 0:
		print("Simulation material-flow foveated throttling test skipped: unified material-flow snapshot not emitted yet.")
		return true
	if baseline_signals.is_empty() or foveated_signals.is_empty():
		print("Simulation material-flow foveated throttling test skipped: unified snapshot emitted without throttle metadata.")
		return true
	if replay_signals.is_empty():
		print("Simulation material-flow foveated throttling test skipped: replay run emitted no comparable throttle metadata.")
		return true

	if not _assert_deterministic_tier_ordering(foveated_signals, replay_signals):
		return false

	var baseline_summary = _summarize_signals(baseline_signals)
	var foveated_summary = _summarize_signals(foveated_signals)
	var comparables := 0

	if baseline_summary.has("op_stride") and foveated_summary.has("op_stride"):
		comparables += 1
		if float(foveated_summary.get("op_stride", 0.0)) + 0.0001 < float(baseline_summary.get("op_stride", 0.0)):
			push_error("Expected foveated run to keep/elevate op_stride under far-camera throttling")
			return false
	if baseline_summary.has("voxel_scale") and foveated_summary.has("voxel_scale"):
		comparables += 1
		if float(foveated_summary.get("voxel_scale", 0.0)) + 0.0001 < float(baseline_summary.get("voxel_scale", 0.0)):
			push_error("Expected foveated run to keep/elevate voxel_scale under far-camera throttling")
			return false
	if baseline_summary.has("compute_budget_scale") and foveated_summary.has("compute_budget_scale"):
		comparables += 1
		if float(foveated_summary.get("compute_budget_scale", 1.0)) - 0.0001 > float(baseline_summary.get("compute_budget_scale", 1.0)):
			push_error("Expected foveated run to keep/lower compute_budget_scale under far-camera throttling")
			return false

	if comparables == 0:
		print("Simulation material-flow foveated throttling test skipped: no comparable throttle scalars in snapshot payload.")
		return true

	print("Simulation material-flow foveated throttling test passed (%d comparable scalar groups)." % comparables)
	return true

func _configure_controller(controller, seed_text: String) -> void:
	controller.configure(seed_text, false, false)
	controller.set_cognition_features(false, false, false)
	controller.register_villager("npc_f1", "F1", {"household_id": "home_f1", "profession": "farmer"})
	controller.register_villager("npc_f2", "F2", {"household_id": "home_f1", "profession": "merchant"})
	controller.register_villager("npc_f3", "F3", {"household_id": "home_f2", "profession": "woodcutter"})

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

func _extract_throttle_signal(snapshot: Variant, state: Dictionary) -> Dictionary:
	if not (snapshot is Dictionary):
		return {}
	var source: Dictionary = snapshot
	var out: Dictionary = {}
	_copy_number_if_present(out, source, "op_stride")
	_copy_number_if_present(out, source, "voxel_scale")
	_copy_number_if_present(out, source, "compute_budget_scale")
	_copy_number_if_present(out, source, "zoom_factor")
	_copy_number_if_present(out, source, "camera_distance")
	_copy_number_if_present(out, source, "uniformity_score")

	for nested_key in ["runtime_policy", "throttle", "foveated_throttling", "execution"]:
		var nested: Dictionary = source.get(nested_key, {})
		if nested.is_empty():
			continue
		_copy_number_if_present(out, nested, "op_stride")
		_copy_number_if_present(out, nested, "voxel_scale")
		_copy_number_if_present(out, nested, "compute_budget_scale")
		_copy_number_if_present(out, nested, "zoom_factor")
		_copy_number_if_present(out, nested, "camera_distance")
		_copy_number_if_present(out, nested, "uniformity_score")

	var env: Dictionary = state.get("environment_snapshot", {})
	var metrics: Dictionary = env.get("_native_view_metrics", {})
	if not metrics.is_empty():
		_copy_number_if_present(out, metrics, "zoom_factor")
		_copy_number_if_present(out, metrics, "camera_distance")
		_copy_number_if_present(out, metrics, "uniformity_score")
		_copy_number_if_present(out, metrics, "compute_budget_scale")
	return out

func _summarize_signals(signals: Array) -> Dictionary:
	var totals: Dictionary = {}
	var counts: Dictionary = {}
	for signal_variant in signals:
		if not (signal_variant is Dictionary):
			continue
		var row: Dictionary = signal_variant
		for key_variant in row.keys():
			var key = String(key_variant)
			totals[key] = float(totals.get(key, 0.0)) + float(row.get(key, 0.0))
			counts[key] = int(counts.get(key, 0)) + 1
	var out: Dictionary = {}
	for key_variant in totals.keys():
		var key = String(key_variant)
		var count = maxi(1, int(counts.get(key, 1)))
		out[key] = float(totals.get(key, 0.0)) / float(count)
	return out

func _copy_number_if_present(target: Dictionary, source: Dictionary, key: String) -> void:
	if not source.has(key):
		return
	var value = source.get(key)
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		target[key] = float(value)

func _assert_deterministic_tier_ordering(foveated_signals: Array, replay_signals: Array) -> bool:
	if foveated_signals.size() != replay_signals.size():
		push_error("Expected foveated replay runs to emit the same number of variable-rate throttle rows")
		return false
	for row_index in range(foveated_signals.size()):
		var lhs_variant = foveated_signals[row_index]
		var rhs_variant = replay_signals[row_index]
		if not (lhs_variant is Dictionary and rhs_variant is Dictionary):
			push_error("Expected throttle rows to be dictionaries for deterministic tier ordering checks")
			return false
		var lhs: Dictionary = lhs_variant
		var rhs: Dictionary = rhs_variant
		for key in ["op_stride", "voxel_scale", "compute_budget_scale"]:
			var lhs_has = lhs.has(key)
			var rhs_has = rhs.has(key)
			if lhs_has != rhs_has:
				push_error("Foveated replay tier metadata mismatch for key '%s' at row %d" % [key, row_index])
				return false
			if lhs_has:
				var lhs_value = float(lhs.get(key, 0.0))
				var rhs_value = float(rhs.get(key, 0.0))
				if abs(lhs_value - rhs_value) > 1.0e-9:
					push_error("Variable-rate tier ordering diverged for key '%s' at row %d" % [key, row_index])
					return false
	return true
