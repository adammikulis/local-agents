@tool
extends RefCounted

const SmellFieldSystemScript = preload("res://addons/local_agents/simulation/SmellFieldSystem.gd")
const StateHasherScript = preload("res://addons/local_agents/simulation/SimulationStateHasher.gd")
const NATIVE_SIM_CORE_ENV_KEY := "LOCAL_AGENTS_ENABLE_NATIVE_SIM_CORE"

func run_test(_tree: SceneTree) -> bool:
	var a = SmellFieldSystemScript.new()
	var b = SmellFieldSystemScript.new()
	a.configure(8.0, 0.55, 2.5)
	b.configure(8.0, 0.55, 2.5)

	for step in range(24):
		var t = float(step)
		a.deposit("plant_food", Vector3(cos(t * 0.3) * 2.0, 0.0, sin(t * 0.3) * 2.0), 0.5)
		a.deposit("rabbit", Vector3(sin(t * 0.2) * 1.1, 0.0, cos(t * 0.2) * 1.1), 0.25)
		a.deposit("villager", Vector3(1.8, 0.0, -1.4), 0.38)
		a.deposit_chemical("linalool", Vector3(-1.0, 0.0, 1.2), 0.42)
		a.deposit_chemical("ammonia", Vector3(0.3, 0.0, -0.7), 0.35)
		b.deposit("plant_food", Vector3(cos(t * 0.3) * 2.0, 0.0, sin(t * 0.3) * 2.0), 0.5)
		b.deposit("rabbit", Vector3(sin(t * 0.2) * 1.1, 0.0, cos(t * 0.2) * 1.1), 0.25)
		b.deposit("villager", Vector3(1.8, 0.0, -1.4), 0.38)
		b.deposit_chemical("linalool", Vector3(-1.0, 0.0, 1.2), 0.42)
		b.deposit_chemical("ammonia", Vector3(0.3, 0.0, -0.7), 0.35)
		a.step(0.2, Vector2(0.35, 0.1), 0.12, 0.15, 1.9)
		b.step(0.2, Vector2(0.35, 0.1), 0.12, 0.15, 1.9)

	var hasher = StateHasherScript.new()
	var snap_a: Dictionary = a.snapshot()
	var snap_b: Dictionary = b.snapshot()
	var hash_a = hasher.hash_state(snap_a)
	var hash_b = hasher.hash_state(snap_b)
	if hash_a == "" or hash_a != hash_b:
		push_error("Smell field deterministic hash mismatch")
		return false

	var layer_rows: Array = a.build_layer_cells("chem_linalool", 0.01, 100)
	if layer_rows.is_empty():
		push_error("Expected linalool voxel layer to have active cells")
		return false

	var danger_probe: Dictionary = a.perceived_danger(Vector3(0.0, 0.0, 0.0), 5)
	if float(danger_probe.get("score", 0.0)) <= 0.0:
		push_error("Danger probe should detect non-zero danger")
		return false
	if not _test_native_dispatch_failure_blocks_cpu_mutation(hasher):
		return false

	print("Smell field deterministic fixture hash: %s" % hash_a)
	return true

func _test_native_dispatch_failure_blocks_cpu_mutation(hasher: RefCounted) -> bool:
	var previous_env := OS.get_environment(NATIVE_SIM_CORE_ENV_KEY)
	OS.set_environment(NATIVE_SIM_CORE_ENV_KEY, "0")
	var system = SmellFieldSystemScript.new()
	system.configure(8.0, 0.55, 2.5)
	system.deposit("plant_food", Vector3(1.25, 0.0, -0.75), 0.9)
	system.deposit_chemical("ammonia", Vector3(-0.5, 0.0, 0.25), 0.7)
	var before_snapshot: Dictionary = system.snapshot()
	var before_hash = hasher.call("hash_state", before_snapshot)
	system.step(0.2, Vector2(0.2, 0.1), 0.12, 0.15, 1.9)
	var after_snapshot: Dictionary = system.snapshot()
	var after_hash = hasher.call("hash_state", after_snapshot)
	OS.set_environment(NATIVE_SIM_CORE_ENV_KEY, previous_env)
	if before_hash != after_hash:
		push_error("Smell field must not mutate layers when native dispatch is unavailable")
		return false
	var status: Dictionary = system.last_step_status()
	if bool(status.get("ok", true)):
		push_error("Expected smell step to fail fast when native dispatch is unavailable")
		return false
	var error_code := String(status.get("error", ""))
	if error_code not in ["gpu_required", "gpu_unavailable", "native_required"]:
		push_error("Expected typed smell dependency error; got '%s'" % error_code)
		return false
	return true
