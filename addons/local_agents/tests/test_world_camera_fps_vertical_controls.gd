@tool
extends RefCounted

const WorldCameraControllerScript := preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldCameraController.gd")

func run_test(tree: SceneTree) -> bool:
	var controller := WorldCameraControllerScript.new()
	var root := Node3D.new()
	var camera := Camera3D.new()
	root.add_child(camera)
	tree.root.add_child(root)
	camera.position = Vector3.ZERO
	controller.configure(camera, 0.007, 0.01, 0.1, 3.0, 120.0, 18.0, 82.0)

	var ok := true
	controller.set_fps_mode(false)
	controller.step_fps(1.0, {KEY_SHIFT: true})
	ok = _assert(is_equal_approx(camera.position.y, 0.0), "Shift altitude input must have no effect outside FPS mode.") and ok

	controller.set_fps_mode(true)
	camera.position = Vector3.ZERO
	controller.step_fps(1.0, {KEY_SHIFT: true})
	ok = _assert(camera.position.y > 0.0, "FPS mode Shift input should move camera upward.") and ok

	camera.position = Vector3.ZERO
	controller.step_fps(1.0, {KEY_CTRL: true})
	ok = _assert(camera.position.y < 0.0, "FPS mode Ctrl input should move camera downward.") and ok

	camera.position = Vector3.ZERO
	controller.step_fps(1.0, {KEY_W: true, KEY_D: true})
	ok = _assert(camera.position.length() > 0.0, "FPS mode WASD movement should remain active.") and ok

	root.queue_free()

	if ok:
		print("World camera FPS vertical controls test passed.")
	return ok

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
