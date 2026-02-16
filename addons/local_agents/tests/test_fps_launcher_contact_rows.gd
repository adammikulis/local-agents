@tool
extends RefCounted

const FpsLauncherControllerScript := preload("res://addons/local_agents/scenes/simulation/controllers/world/FpsLauncherController.gd")

func run_test(tree: SceneTree) -> bool:
	var controller := FpsLauncherControllerScript.new()
	var root := Node3D.new()
	var camera := Camera3D.new()
	var target := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 2.0, 0.6)
	shape.shape = box
	target.add_child(shape)
	target.position = Vector3(0.0, 0.0, -3.0)
	root.add_child(target)
	root.add_child(camera)
	root.add_child(controller)
	tree.get_root().add_child(root)

	controller.configure(camera, root, null)
	controller.launch_speed = 40.0
	controller.launch_mass = 0.4
	controller.projectile_radius = 0.2
	controller.projectile_ttl_seconds = 2.0
	controller.spawn_distance = 0.1
	controller.cooldown_seconds = 0.0
	controller.launch_energy_scale = 1.0
	controller.projectile_material_tag = "dense_steel"
	controller.projectile_hardness_tag = "hard"

	var ok := true
	ok = _assert(controller.try_fire_from_screen_center(), "Launcher should spawn a voxel-chunk projectile from screen center.") and ok
	controller.step(0.12)

	var first_rows := controller.sample_active_projectile_contact_rows()
	ok = _assert(first_rows.size() == 1, "Voxel-chunk collision should emit one contact row on first sample call.") and ok
	if first_rows.size() == 1 and first_rows[0] is Dictionary:
		var row := first_rows[0] as Dictionary
		ok = _assert(String(row.get("projectile_kind", "")) == "voxel_chunk", "Contact row should label projectile_kind as voxel_chunk.") and ok
		ok = _assert(String(row.get("projectile_density_tag", "")) == "dense", "Contact row should include dense density tag.") and ok
		ok = _assert(String(row.get("projectile_hardness_tag", "")) == "hard", "Contact row should include hard hardness tag.") and ok
		ok = _assert(String(row.get("projectile_material_tag", "")) == "dense_steel", "Contact row should preserve projectile material tag.") and ok
		ok = _assert(float(row.get("contact_impulse", 0.0)) > 0.0, "Contact row should preserve positive contact_impulse.") and ok
		ok = _assert(float(row.get("relative_speed", 0.0)) > 0.0, "Contact row should preserve positive relative_speed.") and ok

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

	root.queue_free()
	if ok:
		print("FpsLauncher voxel-chunk contact queue-until-dispatch regression test passed.")
	return ok

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
