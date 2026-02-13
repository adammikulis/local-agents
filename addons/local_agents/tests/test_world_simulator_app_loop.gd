extends RefCounted

const MainScene = preload("res://addons/local_agents/scenes/Main.tscn")

func run_test(tree: SceneTree) -> bool:
	var root = tree.get_root()
	if root == null:
		push_error("Root viewport unavailable")
		return false
	var app_root = MainScene.instantiate()
	if app_root == null:
		push_error("Failed to instantiate Main scene")
		return false
	root.add_child(app_root)
	await tree.process_frame
	await tree.process_frame
	var app = app_root.get_node_or_null("WorldSimulatorApp")
	if app == null:
		push_error("Main did not spawn WorldSimulatorApp")
		app_root.queue_free()
		await tree.process_frame
		return false
	if not app.has_method("_generate_world"):
		push_error("WorldSimulatorApp missing _generate_world")
		app_root.queue_free()
		await tree.process_frame
		return false
	# Force generation to make test deterministic even if scenario changes.
	app.call("_generate_world")
	await tree.process_frame
	var tick_before = int(app.get("_sim_tick"))
	for _i in range(6):
		await tree.process_frame
	var tick_after = int(app.get("_sim_tick"))
	var world_snapshot: Dictionary = app.get("_world_snapshot")
	var ok = true
	if world_snapshot.is_empty():
		push_error("World snapshot is empty after generation")
		ok = false
	if tick_after < tick_before:
		push_error("Simulation tick regressed: %d -> %d" % [tick_before, tick_after])
		ok = false
	app_root.queue_free()
	await tree.process_frame
	return ok
