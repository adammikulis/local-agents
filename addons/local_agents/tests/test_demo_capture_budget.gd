extends RefCounted

class Source extends Node:
	var ready_for_capture: bool = false

	func demo_shot_pose(_altitude: float, _pitch: float, _yaw: float) -> void:
		pass

	func demo_shot_ready() -> bool:
		return ready_for_capture

class Capture extends LocalAgentDemoHarness:
	var deadline_ms: int = 0
	var captures: Array[String] = []

	func _shot_deadline_ms() -> int:
		return deadline_ms

	func _capture(path: String, _tag: String = "") -> void:
		captures.append(path)

	func _quit(_code: int) -> void:
		pass


func run_test(tree: SceneTree) -> bool:
	var source: Source = Source.new()
	var harness: Capture = Capture.new()
	harness.report_source = source
	harness.deadline_ms = Time.get_ticks_msec() + 900
	tree.root.add_child(source)
	source.add_child(harness)
	harness.shoot_path = "capture.png"
	harness.shoot_frames = 1
	harness._poses.assign([Vector3(30, -3, 0), Vector3(30, -3, 180), Vector3(200, -15, 0)])
	harness._process(0.0)
	OS.delay_msec(350)
	harness._process(0.0)
	var ok: bool = harness.captures.is_empty()
	source.ready_for_capture = true
	for pose in range(3):
		if pose > 0:
			harness._process(0.0)
		harness._process(0.0)
		harness._process(0.0)
	ok = harness.captures.size() == 3 and harness._done and ok
	source.free()
	if not ok:
		push_error("capture protocol spent the first pose budget on world initialization")
	return ok
