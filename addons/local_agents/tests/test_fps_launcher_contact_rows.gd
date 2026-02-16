@tool
extends RefCounted

const FpsLauncherControllerScript := preload("res://addons/local_agents/scenes/simulation/controllers/world/FpsLauncherController.gd")

func run_test(tree: SceneTree) -> bool:
	var ok := true
	ok = _run_chunk_bounce_and_contact_queue_test(tree) and ok
	ok = _run_rigidbody_response_test(tree) and ok
	ok = _run_mutation_deadline_invariant_test(tree) and ok
	if ok:
		print("FpsLauncher voxel-chunk contact queue-until-dispatch regression test passed.")
	return ok

func _run_chunk_bounce_and_contact_queue_test(tree: SceneTree) -> bool:
	var controller := FpsLauncherControllerScript.new()
	var root := Node3D.new()
	var camera := Camera3D.new()
	var static_chunk := StaticBody3D.new()
	var static_shape := CollisionShape3D.new()
	var static_box := BoxShape3D.new()
	static_box.size = Vector3(2.2, 2.2, 0.6)
	static_shape.shape = static_box
	static_chunk.add_child(static_shape)
	static_chunk.position = Vector3(0.0, 0.0, -3.0)
	root.add_child(static_chunk)
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
	ok = _assert(controller.try_fire_from_screen_center(), "Launcher should spawn voxel-chunk projectile from screen center.") and ok
	ok = _assert(controller.active_projectile_count() == 1, "Fire action should create one active voxel-chunk projectile state immediately after spawn.") and ok
	controller.step(0.12)
	ok = _assert(controller.active_projectile_count() == 1, "Projectile should remain active after first chunk contact so bounce/deflection can continue.") and ok
	var projectile_node := _find_projectile_visual(root)
	ok = _assert(projectile_node != null, "Projectile visual node should exist while active after bounce.") and ok
	if projectile_node != null:
		ok = _assert(
			projectile_node.global_position.z > (static_chunk.global_position.z - 0.2),
			"Projectile should not tunnel through chunk collision surface after first step."
		) and ok

	var first_rows := controller.sample_active_projectile_contact_rows()
	ok = _assert(first_rows.size() >= 1, "Chunk bounce should emit at least one contact row.") and ok
	for row_variant in first_rows:
		if not (row_variant is Dictionary):
			continue
		var row := row_variant as Dictionary
		ok = _assert(String(row.get("projectile_kind", "")) == "voxel_chunk", "Contact row should label projectile_kind as voxel_chunk.") and ok
		ok = _assert(String(row.get("projectile_density_tag", "")) == "dense", "Contact row should include dense density tag.") and ok
		ok = _assert(String(row.get("projectile_hardness_tag", "")) == "hard", "Contact row should include hard hardness tag.") and ok
		ok = _assert(String(row.get("projectile_material_tag", "")) == "dense_steel", "Contact row should preserve projectile material tag.") and ok
		ok = _assert(float(row.get("contact_impulse", 0.0)) > 0.0, "Contact row should preserve positive contact_impulse.") and ok
		ok = _assert(float(row.get("relative_speed", 0.0)) > 0.0, "Contact row should preserve positive relative_speed.") and ok

	var second_rows := controller.sample_active_projectile_contact_rows()
	ok = _assert(second_rows.is_empty(), "Projectile-contact queue should be consumed after one sample pass.") and ok
	ok = _assert(controller.pending_voxel_dispatch_contact_count() >= 1, "Projectile-contact rows must remain pending for native dispatch until explicit ack.") and ok

	controller.step(0.2)
	controller.step(0.2)
	var pending_rows_after_delay := controller.sample_voxel_dispatch_contact_rows()
	ok = _assert(pending_rows_after_delay.size() >= 1, "Pending projectile-contact rows should survive multiple frames without scheduled pulse.") and ok

	controller.acknowledge_voxel_dispatch_contact_rows(pending_rows_after_delay.size(), true)
	ok = _assert(controller.pending_voxel_dispatch_contact_count() == 0, "Pending projectile-contact row should clear only after explicit dispatch ack.") and ok
	var pending_rows_after_ack := controller.sample_voxel_dispatch_contact_rows()
	ok = _assert(pending_rows_after_ack.is_empty(), "Dispatch-contact sampling should be empty after ack consumes queued rows.") and ok

	tree.get_root().remove_child(root)
	root.free()
	return ok

func _run_rigidbody_response_test(tree: SceneTree) -> bool:
	var controller := FpsLauncherControllerScript.new()
	var root := Node3D.new()
	var camera := Camera3D.new()
	var target := RigidBody3D.new()
	target.mass = 3.0
	target.gravity_scale = 0.0
	target.sleeping = false
	root.add_child(target)
	root.add_child(camera)
	root.add_child(controller)
	tree.get_root().add_child(root)

	controller.configure(camera, root, null)

	var projectile := FpsLauncherControllerScript.ChunkProjectileState.new()
	projectile.projectile_id = 77
	projectile.velocity = Vector3(0.0, 0.0, -40.0)
	projectile.mass = 0.4
	projectile.radius = 0.2
	projectile.ttl_seconds = 1.5
	projectile.material_tag = "dense_steel"
	projectile.hardness_tag = "hard"
	var hit := {
		"collider": target,
		"collider_id": target.get_instance_id(),
		"position": Vector3(0.0, 0.0, -1.0),
		"normal": Vector3(0.0, 0.0, 1.0),
	}

	var ok := true
	controller.call("_apply_rigidbody_collision_response", projectile, hit)
	ok = _assert(target.linear_velocity.length() > 0.0, "Voxel-chunk projectile collision should preserve rigidbody response by applying non-zero impulse to the target.") and ok
	var contact_row_variant: Variant = controller.call("_build_contact_row", projectile, hit, Vector3.ZERO)
	var contact_row: Dictionary = {}
	if contact_row_variant is Dictionary:
		contact_row = contact_row_variant as Dictionary
	ok = _assert(float(contact_row.get("collider_mass", 0.0)) > 0.0, "Contact row should preserve rigidbody mass semantics for collider payload.") and ok

	tree.get_root().remove_child(root)
	root.free()
	return ok

func _run_mutation_deadline_invariant_test(tree: SceneTree) -> bool:
	var controller := FpsLauncherControllerScript.new()
	var root := Node3D.new()
	var camera := Camera3D.new()
	root.add_child(camera)
	root.add_child(controller)
	tree.get_root().add_child(root)
	controller.configure(camera, root, null)
	controller.record_projectile_contact_row({
		"body_id": 101,
		"contact_point": Vector3(2.0, 1.0, 2.0),
		"contact_impulse": 14.0,
		"relative_speed": 22.0,
		"projectile_kind": "voxel_chunk",
	})

	var ok := true
	ok = _assert(controller.pending_voxel_dispatch_contact_count() == 1, "Launcher should queue projectile contact row for mutation dispatch.") and ok
	var queued_rows_variant: Variant = controller.sample_voxel_dispatch_contact_rows()
	var queued_rows: Array = queued_rows_variant if queued_rows_variant is Array else []
	ok = _assert(queued_rows.size() == 1, "Queued projectile-contact row should be sampleable before deadline expiry.") and ok
	if queued_rows.size() == 1 and queued_rows[0] is Dictionary:
		var queued_row := queued_rows[0] as Dictionary
		ok = _assert(
			int(queued_row.get("deadline_frame", -1)) > int(queued_row.get("hit_frame", 0)),
			"Queued projectile-contact row should expose future deadline_frame relative to hit_frame."
		) and ok
	var initial_status_variant: Variant = controller.projectile_mutation_deadline_status()
	var initial_status: Dictionary = initial_status_variant if initial_status_variant is Dictionary else {}
	ok = _assert(bool(initial_status.get("ok", false)), "Deadline status should be healthy immediately after queuing contact rows.") and ok
	controller.acknowledge_voxel_dispatch_contact_rows(1, false)
	ok = _assert(controller.pending_voxel_dispatch_contact_count() == 1, "Non-mutating dispatch ack must not clear projectile contact rows.") and ok
	for _i in range(FpsLauncherControllerScript.MAX_PROJECTILE_MUTATION_FRAMES + 2):
		controller.step(0.016)
	ok = _assert(controller.pending_voxel_dispatch_contact_count() == 0, "Projectile rows that miss mutation deadline must be purged after PROJECTILE_MUTATION_DEADLINE_EXCEEDED.") and ok
	var status_variant: Variant = controller.projectile_mutation_deadline_status()
	var status: Dictionary = status_variant if status_variant is Dictionary else {}
	ok = _assert(not bool(status.get("ok", true)), "Deadline invariant should hard-fail status contract when queued projectile contact expires.") and ok
	ok = _assert(String(status.get("error", "")) == "PROJECTILE_MUTATION_DEADLINE_EXCEEDED", "Deadline failure contract should preserve PROJECTILE_MUTATION_DEADLINE_EXCEEDED error code.") and ok
	ok = _assert(int(status.get("expired_contacts", 0)) > 0, "Deadline failure contract should report expired contact rows explicitly.") and ok
	var expired_rows_variant: Variant = controller.sample_expired_voxel_dispatch_contact_rows()
	var expired_rows: Array = expired_rows_variant if expired_rows_variant is Array else []
	ok = _assert(expired_rows.size() == 1, "Deadline invariant should report deterministic expired row count for single stale projectile contact.") and ok
	if expired_rows.size() == 1 and expired_rows[0] is Dictionary:
		var expired_row := expired_rows[0] as Dictionary
		ok = _assert(String(expired_row.get("error_code", "")) == "PROJECTILE_MUTATION_DEADLINE_EXCEEDED", "Expired contact row should carry PROJECTILE_MUTATION_DEADLINE_EXCEEDED error_code.") and ok
		ok = _assert(int(expired_row.get("body_id", 0)) == 101, "Expired contact row should preserve original projectile body_id for telemetry continuity.") and ok
		ok = _assert(int(expired_row.get("expired_frame", -1)) > int(expired_row.get("deadline_frame", 0)), "Expired contact row should include expired_frame beyond deadline_frame.") and ok
	var consumed_expired_variant: Variant = controller.consume_expired_voxel_dispatch_contact_rows()
	var consumed_expired: Array = consumed_expired_variant if consumed_expired_variant is Array else []
	ok = _assert(consumed_expired.size() == 1, "consume_expired_voxel_dispatch_contact_rows should deterministically return stale row payloads.") and ok
	ok = _assert(controller.sample_expired_voxel_dispatch_contact_rows().is_empty(), "Expired contact reporting queue should clear after consume call.") and ok

	tree.get_root().remove_child(root)
	root.free()
	return ok

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition

func _find_projectile_visual(root: Node3D) -> Node3D:
	for child in root.get_children():
		if child is Node3D and String((child as Node3D).name).begins_with("VoxelChunkProjectile_"):
			return child as Node3D
	return null
