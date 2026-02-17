extends Node

const _TEST_NAME := "fps_fire_destroy"
const _POLL_INTERVAL_SECONDS := 0.01
const _TIMEOUT_SECONDS := 20.0
const _PROJECTILE_SETTLE_TIMEOUT_SECONDS := 8.0
const _REFIRE_INTERVAL_SECONDS := 0.6

var _world_controller: Node = null
var _completed: bool = false
var _final_runtime: Dictionary = {}

func start(world_controller: Node) -> void:
	_world_controller = world_controller
	_install_quit_button()
	call_deferred("_run")

func _run() -> void:
	var ok := true
	ok = _assert(_world_controller != null, "Harness missing world controller reference.") and ok
	if not ok:
		_finish(false)
		return
	await _wait_frames(6)
	ok = _assert(_world_controller.has_method("set_fps_mode_for_testing"), "World controller missing set_fps_mode_for_testing.") and ok
	ok = _assert(_world_controller.has_method("fire_from_screen_center_for_testing"), "World controller missing fire_from_screen_center_for_testing.") and ok
	ok = _assert(_world_controller.has_method("set_native_voxel_dispatch_enabled_for_testing"), "World controller missing set_native_voxel_dispatch_enabled_for_testing.") and ok
	ok = _assert(_world_controller.has_method("active_fps_projectile_count_for_testing"), "World controller missing active_fps_projectile_count_for_testing.") and ok
	ok = _assert(_world_controller.has_method("native_voxel_dispatch_runtime"), "World controller missing native_voxel_dispatch_runtime.") and ok
	if not ok:
		_finish(false)
		return

	var fps_enabled := bool(_world_controller.call("set_fps_mode_for_testing", true))
	ok = _assert(fps_enabled, "Failed to force FPS mode before fire request.") and ok
	var dispatch_enabled := bool(_world_controller.call("set_native_voxel_dispatch_enabled_for_testing", true))
	ok = _assert(dispatch_enabled, "Failed to keep world-native dispatch active for runtime mutation assertions.") and ok
	var runtime_before: Dictionary = _runtime_snapshot()
	_final_runtime = runtime_before.duplicate(true)
	var fired := bool(_world_controller.call("fire_from_screen_center_for_testing"))
	ok = _assert(fired, "Center fire request did not produce a projectile fire success.") and ok
	if not ok:
		_finish(false, _final_runtime)
		return

	var wait_result: Dictionary = await _wait_for_contact_rows(runtime_before)
	ok = _assert(bool(wait_result.get("contact_observed", false)), "Timed out waiting for projectile contact evidence.") and ok

	var mutation_wait_result: Dictionary = await _wait_for_runtime_mutation(runtime_before)
	var runtime_after_variant = mutation_wait_result.get("runtime", {})
	var runtime_after: Dictionary = runtime_after_variant if runtime_after_variant is Dictionary else {}
	_final_runtime = runtime_after.duplicate(true)
	ok = _assert(bool(mutation_wait_result.get("real_mutation_observed", false)), "Timed out waiting for real mutator-applied mutation evidence after contact.") and ok
	ok = _assert(bool(mutation_wait_result.get("contact_dispatch_consumed", false)), "Timed out waiting for native dispatch to consume projectile contact rows.") and ok
	ok = _assert(int(runtime_after.get("dispatch_attempts_after_fire", 0)) > int(runtime_before.get("dispatch_attempts_after_fire", 0)), "Runtime path did not attempt native dispatch after fire.") and ok
	ok = _assert(int(runtime_after.get("pulses_success", 0)) > int(runtime_before.get("pulses_success", 0)), "Runtime path did not record a successful native dispatch pulse after fire.") and ok
	ok = _assert(int(runtime_after.get("contacts_dispatched", 0)) > int(runtime_before.get("contacts_dispatched", 0)), "Runtime path did not record dispatched contact consumption after fire.") and ok
	ok = _assert(int(runtime_after.get("hits_queued", 0)) > int(runtime_before.get("hits_queued", 0)), "Runtime path did not record projectile contact queueing after fire.") and ok
	ok = _assert(int(runtime_after.get("real_mutations", 0)) > int(runtime_before.get("real_mutations", 0)), "Runtime path did not report real mutator-applied mutation evidence after contact.") and ok
	if runtime_after.has("debris_emitted_total") or runtime_before.has("debris_emitted_total"):
		var debris_before := int(runtime_before.get("debris_emitted_total", 0))
		var debris_after := int(runtime_after.get("debris_emitted_total", 0))
		if debris_after > debris_before:
			print("FPS_FIRE_DESTROY_DEBRIS_EVIDENCE=%d" % (debris_after - debris_before))
		else:
			print("FPS_FIRE_DESTROY_DEBRIS_EVIDENCE=unavailable")
	ok = _assert(int(runtime_after.get("first_mutation_frames_since_fire", -1)) >= 0, "Runtime path did not report first_mutation_frames_since_fire evidence.") and ok
	ok = _assert(String(runtime_after.get("last_backend", "")).findn("gpu") != -1, "Runtime path must report GPU backend for native dispatch.") and ok
	ok = _assert(int(runtime_after.get("dependency_errors", 0)) == int(runtime_before.get("dependency_errors", 0)), "Runtime path recorded dependency errors during FPS fire mutation harness.") and ok
	ok = _assert(String(runtime_after.get("last_error", "")).strip_edges() == "", "Runtime path recorded unexpected dependency error during FPS fire mutation harness.") and ok
	var cleanup_result := await _wait_for_projectile_cleanup()
	ok = _assert(bool(cleanup_result.get("cleaned", false)), "Projectile runtime path should destroy projectile state after impact/TTL progression.") and ok

	_finish(ok, _final_runtime)

func _wait_for_contact_rows(runtime_before: Dictionary) -> Dictionary:
	var elapsed := 0.0
	var baseline_hits_queued := int(runtime_before.get("hits_queued", 0))
	var contact_observed := false
	var next_refire_elapsed := _REFIRE_INTERVAL_SECONDS

	while elapsed < _TIMEOUT_SECONDS:
		await _sleep_seconds(_POLL_INTERVAL_SECONDS)
		elapsed += _POLL_INTERVAL_SECONDS
		var runtime := _runtime_snapshot()
		var hits_queued := int(runtime.get("hits_queued", 0))
		contact_observed = hits_queued > baseline_hits_queued
		if contact_observed:
			break
		if elapsed >= next_refire_elapsed and not contact_observed:
			if int(_world_controller.call("active_fps_projectile_count_for_testing")) <= 0:
				_world_controller.call("fire_from_screen_center_for_testing")
			next_refire_elapsed += _REFIRE_INTERVAL_SECONDS
	return {
		"contact_observed": contact_observed,
	}

func _runtime_snapshot() -> Dictionary:
	var runtime_variant = _world_controller.call("native_voxel_dispatch_runtime")
	if runtime_variant is Dictionary:
		return (runtime_variant as Dictionary).duplicate(true)
	return {}

func _wait_for_runtime_mutation(runtime_before: Dictionary) -> Dictionary:
	var elapsed := 0.0
	var baseline_real_mutations := int(runtime_before.get("real_mutations", 0))
	var baseline_contacts_dispatched := int(runtime_before.get("contacts_dispatched", 0))
	var real_mutation_observed := false
	var contact_dispatch_consumed := false
	var runtime: Dictionary = _runtime_snapshot()

	while elapsed < _TIMEOUT_SECONDS:
		await _sleep_seconds(_POLL_INTERVAL_SECONDS)
		elapsed += _POLL_INTERVAL_SECONDS
		runtime = _runtime_snapshot()
		var real_mutations_count := int(runtime.get("real_mutations", 0))
		var first_mutation_frames := int(runtime.get("first_mutation_frames_since_fire", -1))
		var contacts_dispatched_count := int(runtime.get("contacts_dispatched", 0))
		real_mutation_observed = real_mutations_count > baseline_real_mutations and first_mutation_frames >= 0
		contact_dispatch_consumed = contacts_dispatched_count > baseline_contacts_dispatched
		if real_mutation_observed and contact_dispatch_consumed:
			break
	return {
		"real_mutation_observed": real_mutation_observed,
		"contact_dispatch_consumed": contact_dispatch_consumed,
		"runtime": runtime,
	}

func _wait_for_projectile_cleanup() -> Dictionary:
	var elapsed := 0.0
	while elapsed < _PROJECTILE_SETTLE_TIMEOUT_SECONDS:
		await _sleep_seconds(_POLL_INTERVAL_SECONDS)
		elapsed += _POLL_INTERVAL_SECONDS
		var active_count := int(_world_controller.call("active_fps_projectile_count_for_testing"))
		if active_count <= 0:
			return {"cleaned": true, "elapsed": elapsed}
	return {"cleaned": false, "elapsed": elapsed}

func _install_quit_button() -> void:
	var layer := CanvasLayer.new()
	layer.name = "FpsFireDestroyHarnessUi"
	add_child(layer)
	var button := Button.new()
	button.name = "Quit"
	button.text = "Quit"
	button.size = Vector2(72.0, 30.0)
	button.position = Vector2(10.0, 10.0)
	button.pressed.connect(_on_quit_pressed)
	layer.add_child(button)

func _sleep_seconds(seconds: float) -> void:
	await get_tree().create_timer(maxf(0.0, seconds)).timeout

func _wait_frames(frame_count: int) -> void:
	for _i in range(maxi(0, frame_count)):
		await get_tree().process_frame

func _finish(passed: bool, runtime_snapshot: Dictionary = {}) -> void:
	if _completed:
		return
	_completed = true
	_print_runtime_evidence(runtime_snapshot)
	if passed:
		print("%s harness passed." % _TEST_NAME)
		get_tree().quit(0)
		return
	print("%s harness failed." % _TEST_NAME)
	push_error("%s harness failed." % _TEST_NAME)
	get_tree().quit(1)

func _on_quit_pressed() -> void:
	push_error("%s harness failed: quit requested from in-window button." % _TEST_NAME)
	_finish(false, _final_runtime)

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition

func _print_runtime_evidence(runtime_snapshot: Dictionary) -> void:
	var snapshot: Dictionary = runtime_snapshot.duplicate(true)
	if snapshot.is_empty():
		snapshot = _runtime_snapshot()
	var payload := JSON.stringify(snapshot)
	print("FPS_FIRE_DESTROY_RUNTIME=%s" % payload)
