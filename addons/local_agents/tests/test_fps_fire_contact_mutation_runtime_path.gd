@tool
extends RefCounted

const SimulationControllerScript := preload("res://addons/local_agents/simulation/SimulationController.gd")
const SimulationVoxelTerrainMutatorScript := preload("res://addons/local_agents/simulation/controller/SimulationVoxelTerrainMutator.gd")
const WorldInputControllerScript := preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldInputController.gd")
const FpsLauncherControllerScript := preload("res://addons/local_agents/scenes/simulation/controllers/world/FpsLauncherController.gd")
const WorldGenConfigScript := preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")

func run_test(tree: SceneTree) -> bool:
	var simulation_controller := SimulationControllerScript.new()
	tree.root.add_child(simulation_controller)
	simulation_controller.configure("seed-fps-fire-contact-mutation-runtime-path", false, false)
	var config := WorldGenConfigScript.new()
	config.map_width = 20
	config.map_height = 20
	config.voxel_world_height = 34
	config.voxel_sea_level = 10
	var setup: Dictionary = simulation_controller.configure_environment(config)
	if not bool(setup.get("ok", false)):
		simulation_controller.queue_free()
		push_error("Environment setup failed for FPS fire runtime-path mutation test.")
		return false

	var root := Node3D.new()
	var camera := Camera3D.new()
	var launcher := FpsLauncherControllerScript.new()
	var wall := StaticBody3D.new()
	var wall_shape := CollisionShape3D.new()
	var wall_box := BoxShape3D.new()
	wall_box.size = Vector3(2.2, 2.2, 0.6)
	wall_shape.shape = wall_box
	wall.add_child(wall_shape)
	wall.position = Vector3(0.0, 0.0, -3.0)
	root.add_child(wall)
	root.add_child(camera)
	root.add_child(launcher)
	tree.root.add_child(root)

	launcher.configure(camera, root, null)
	launcher.launch_speed = 40.0
	launcher.launch_mass = 0.4
	launcher.projectile_radius = 0.2
	launcher.projectile_ttl_seconds = 2.0
	launcher.spawn_distance = 0.1
	launcher.cooldown_seconds = 0.0
	launcher.launch_energy_scale = 1.0

	var spawn_mode := "none"
	var input_controller := WorldInputControllerScript.new()
	input_controller.configure(
		root,
		null,
		null,
		func() -> String: return spawn_mode,
		func(mode: String) -> void: spawn_mode = mode,
		func() -> void: launcher.try_fire_from_screen_center(),
		func(_screen_pos: Vector2) -> void: pass,
		func(_text: String) -> void: pass,
		Callable(),
		Callable(),
		true
	)

	var ok := true
	input_controller.toggle_fps_mode()
	ok = _assert(input_controller.is_fps_mode(), "FPS mode should be enabled before firing runtime-path test shot.") and ok

	var fire_event := InputEventKey.new()
	fire_event.keycode = KEY_SPACE
	fire_event.pressed = true
	input_controller.handle_unhandled_input(fire_event)
	ok = _assert(launcher.active_projectile_count() == 1, "FPS fire request should create an active projectile in runtime-path test.") and ok

	launcher.step(0.12)
	var contact_rows := launcher.sample_voxel_dispatch_contact_rows()
	ok = _assert(contact_rows.size() >= 1, "Fired projectile should produce contact rows after impact.") and ok
	if contact_rows.size() >= 1 and contact_rows[0] is Dictionary:
		var first_row := contact_rows[0] as Dictionary
		var hit_frame := int(first_row.get("hit_frame", -1))
		var deadline_frame := int(first_row.get("deadline_frame", -1))
		ok = _assert(deadline_frame - hit_frame == FpsLauncherControllerScript.MAX_PROJECTILE_MUTATION_FRAMES, "Contact row should carry bounded mutation deadline metadata.") and ok

	var mutation := SimulationVoxelTerrainMutatorScript.apply_native_voxel_stage_delta(
		simulation_controller,
		1,
		{"physics_contacts": contact_rows.duplicate(true)}
	)
	ok = _assert(bool(mutation.get("changed", false)), "FPS fire contact runtime path should mutate voxel terrain after impact.") and ok
	var changed_tiles_variant = mutation.get("changed_tiles", [])
	var changed_tiles: Array = changed_tiles_variant if changed_tiles_variant is Array else []
	ok = _assert(not changed_tiles.is_empty(), "FPS fire runtime path mutation should report changed_tiles.") and ok

	launcher.acknowledge_voxel_dispatch_contact_rows(contact_rows.size(), true)
	ok = _assert(launcher.pending_voxel_dispatch_contact_count() == 0, "Mutation-confirmed ack should clear pending projectile contacts.") and ok

	input_controller.set_input_enabled(false)
	root.queue_free()
	simulation_controller.queue_free()
	if ok:
		print("FPS fire contact mutation runtime-path test passed.")
	return ok

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
