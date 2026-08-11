@tool
extends RefCounted

## Runs run_frame_probe.gd and reports what it found.
##
## The behaviours it covers - the cognition scheduler's DEFERRED adoption and the demo harness's
## physics-frame counting - only exist across engine frames, and a RefCounted test cannot pump them:
## the shared runner calls run_test() synchronously and never awaits, so an awaiting run_test() would
## suspend and be read as a pass. The probe therefore runs as its own SceneTree in a child process and
## this module reports its verdict, which keeps the whole thing inside the canonical runner.
##
## One child process, all frame-dependent assertions - the launch is the expensive part, so it is paid
## once. That is also why this test is registered in the deterministic lane only and not in the fast
## sweep.
##
## (Explicit types only - project rule: no ':=' inferred typing.)

const PROBE_SCRIPT: String = "res://addons/local_agents/tests/run_frame_probe.gd"
const MARKER: String = "FRAME_PROBE="


func run_test(_tree: SceneTree) -> bool:
	var executable: String = OS.get_executable_path()
	if executable == "":
		push_error("Cannot locate the Godot executable to run the frame probe.")
		return false
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args: PackedStringArray = PackedStringArray([
		"--headless",
		"--no-window",
		"--path", project_dir,
		"-s", PROBE_SCRIPT,
	])
	var output: Array = []
	var exit_code: int = OS.execute(executable, args, output, true)
	var text: String = "\n".join(output)

	var payload: Dictionary = _parse_marker(text)
	if payload.is_empty():
		push_error("The frame probe printed no %s line (exit code %d). Output:\n%s" % [MARKER, exit_code, text])
		return false
	var failures: Array = payload.get("failures", [])
	if not bool(payload.get("ok", false)) or not failures.is_empty():
		for failure in failures:
			push_error("frame probe: %s" % String(failure))
		if failures.is_empty():
			push_error("The frame probe reported failure with no detail: %s" % str(payload))
		return false
	if exit_code != 0:
		push_error("The frame probe reported ok but exited %d. Output:\n%s" % [exit_code, text])
		return false
	print("Frame probe passed: %s" % JSON.stringify(payload.get("notes", {}), "", false))
	return true


func _parse_marker(text: String) -> Dictionary:
	for line_variant in text.split("\n", false):
		var line: String = String(line_variant).strip_edges()
		var index: int = line.find(MARKER)
		if index < 0:
			continue
		var body: String = line.substr(index + MARKER.length())
		var parsed: Variant = JSON.parse_string(body)
		if parsed is Dictionary:
			return parsed
	return {}
