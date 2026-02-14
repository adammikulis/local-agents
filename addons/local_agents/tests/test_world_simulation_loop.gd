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
	var simulation = app_root.get_node_or_null("WorldSimulation")
	if simulation == null:
		push_error("Main did not spawn WorldSimulation")
		app_root.queue_free()
		await tree.process_frame
		return false
	var simulation_controller = simulation.get_node_or_null("SimulationController")
	if simulation_controller == null:
		push_error("WorldSimulation missing SimulationController")
		app_root.queue_free()
		await tree.process_frame
		return false
	if simulation.has_method("_on_hud_play_pressed"):
		simulation.call("_on_hud_play_pressed")
	for _i in range(6):
		await tree.process_frame
	var ok = true
	if not simulation.is_inside_tree():
		push_error("WorldSimulation left scene tree unexpectedly")
		ok = false
	if not simulation_controller.is_inside_tree():
		push_error("SimulationController left scene tree unexpectedly")
		ok = false
	app_root.queue_free()
	await tree.process_frame
	return ok
