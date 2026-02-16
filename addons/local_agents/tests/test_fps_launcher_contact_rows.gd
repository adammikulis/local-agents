@tool
extends RefCounted

const FpsLauncherControllerScript := preload("res://addons/local_agents/scenes/simulation/controllers/world/FpsLauncherController.gd")

func run_test(_tree: SceneTree) -> bool:
	var controller := FpsLauncherControllerScript.new()
	var ok := true
	controller.record_projectile_contact_row({
		"contact_impulse": 3.2,
		"relative_speed": 7.4,
		"contact_point": Vector3(2.0, 4.0, 6.0),
		"contact_normal": Vector3(1.0, 0.0, 0.0),
		"body_mass": 0.2,
		"collider_mass": 5.0,
	})
	var first_rows := controller.sample_active_projectile_contact_rows()
	ok = _assert(first_rows.size() == 1, "Queued projectile-contact row should be emitted once on next sample call.") and ok
	if first_rows.size() == 1 and first_rows[0] is Dictionary:
		var row := first_rows[0] as Dictionary
		ok = _assert(float(row.get("contact_impulse", 0.0)) > 0.0, "Queued projectile-contact row should preserve contact_impulse.") and ok
		ok = _assert(float(row.get("relative_speed", 0.0)) > 0.0, "Queued projectile-contact row should preserve relative_speed.") and ok
	var second_rows := controller.sample_active_projectile_contact_rows()
	ok = _assert(second_rows.is_empty(), "Projectile-contact queue should be consumed after one sample pass.") and ok
	ok = _assert(controller.pending_voxel_dispatch_contact_count() == 1, "Projectile-contact row must remain pending for native dispatch until explicit ack.") and ok
	controller.step(0.2)
	controller.step(0.2)
	var pending_rows_after_delay := controller.sample_voxel_dispatch_contact_rows()
	ok = _assert(pending_rows_after_delay.size() == 1, "Pending projectile-contact row should survive multiple frames without scheduled pulse.") and ok
	controller.acknowledge_voxel_dispatch_contact_rows(1)
	ok = _assert(controller.pending_voxel_dispatch_contact_count() == 0, "Pending projectile-contact row should clear only after explicit dispatch ack.") and ok
	var pending_rows_after_ack := controller.sample_voxel_dispatch_contact_rows()
	ok = _assert(pending_rows_after_ack.is_empty(), "Dispatch-contact sampling should be empty after ack consumes queued rows.") and ok
	if ok:
		print("FpsLauncher projectile contact queue-until-dispatch regression test passed.")
	return ok

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
