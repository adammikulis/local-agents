@tool
extends RefCounted

const SmellFieldSystemScript = preload("res://addons/local_agents/simulation/SmellFieldSystem.gd")
const StateHasherScript = preload("res://addons/local_agents/simulation/SimulationStateHasher.gd")

func run_test(_tree: SceneTree) -> bool:
	var a = SmellFieldSystemScript.new()
	var b = SmellFieldSystemScript.new()
	a.configure(8.0, 0.55)
	b.configure(8.0, 0.55)

	for step in range(24):
		var t = float(step)
		a.deposit("plant_food", Vector3(cos(t * 0.3) * 2.0, 0.0, sin(t * 0.3) * 2.0), 0.5)
		a.deposit("rabbit", Vector3(sin(t * 0.2) * 1.1, 0.0, cos(t * 0.2) * 1.1), 0.25)
		a.deposit("villager", Vector3(1.8, 0.0, -1.4), 0.38)
		b.deposit("plant_food", Vector3(cos(t * 0.3) * 2.0, 0.0, sin(t * 0.3) * 2.0), 0.5)
		b.deposit("rabbit", Vector3(sin(t * 0.2) * 1.1, 0.0, cos(t * 0.2) * 1.1), 0.25)
		b.deposit("villager", Vector3(1.8, 0.0, -1.4), 0.38)
		a.step(0.2, Vector2(0.35, 0.1), 0.12, 0.15, 1.9)
		b.step(0.2, Vector2(0.35, 0.1), 0.12, 0.15, 1.9)

	# Trigger adaptive subdivision only when needed (strength above threshold).
	a.deposit("plant_food", Vector3(0.0, 0.0, 0.0), 1.2)
	b.deposit("plant_food", Vector3(0.0, 0.0, 0.0), 1.2)

	var hasher = StateHasherScript.new()
	var field_a: Dictionary = a.call("field").to_dict()
	var field_b: Dictionary = b.call("field").to_dict()
	var hierarchy_a: Dictionary = a.call("hierarchy_snapshot")
	var hash_a = hasher.hash_state(field_a)
	var hash_b = hasher.hash_state(field_b)
	if hash_a == "" or hash_a != hash_b:
		push_error("Smell field deterministic hash mismatch")
		return false

	if Dictionary(hierarchy_a.get("sparse_layers", {})).is_empty():
		push_error("Expected sparse LOD layer data after high-strength deposit")
		return false

	var danger_probe: Dictionary = a.perceived_danger(Vector3(0.0, 0.0, 0.0), 5)
	if float(danger_probe.get("score", 0.0)) <= 0.0:
		push_error("Danger probe should detect non-zero danger")
		return false

	print("Smell field deterministic fixture hash: %s" % hash_a)
	return true
