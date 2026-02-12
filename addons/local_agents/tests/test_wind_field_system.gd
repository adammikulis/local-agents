@tool
extends RefCounted

const WindFieldSystemScript = preload("res://addons/local_agents/simulation/WindFieldSystem.gd")
const GridConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/GridConfigResource.gd")
const StateHasherScript = preload("res://addons/local_agents/simulation/SimulationStateHasher.gd")

func run_test(_tree: SceneTree) -> bool:
	var cfg = GridConfigResourceScript.new()
	cfg.grid_layout = "hex_pointy"
	cfg.half_extent = 10.0
	cfg.cell_size = 0.55

	var a = WindFieldSystemScript.new()
	var b = WindFieldSystemScript.new()
	a.configure_from_grid(cfg)
	b.configure_from_grid(cfg)
	a.set_global_wind(Vector3(1.0, 0.0, 0.15), 0.65, 1.3)
	b.set_global_wind(Vector3(1.0, 0.0, 0.15), 0.65, 1.3)

	for _i in range(10):
		a.step(0.2, 0.58, 1.1, 0.1)
		b.step(0.2, 0.58, 1.1, 0.1)

	var rows_a: Array = []
	var rows_b: Array = []
	for x in range(-6, 7):
		for y in range(-6, 7):
			var p = Vector3(float(x), 0.0, float(y))
			var wa: Vector2 = a.sample_wind(p)
			var wb: Vector2 = b.sample_wind(p)
			rows_a.append({"x": x, "y": y, "wx": wa.x, "wy": wa.y})
			rows_b.append({"x": x, "y": y, "wx": wb.x, "wy": wb.y})

	var hasher = StateHasherScript.new()
	var hash_a = hasher.hash_state({"rows": rows_a})
	var hash_b = hasher.hash_state({"rows": rows_b})
	if hash_a == "" or hash_a != hash_b:
		push_error("Wind field determinism hash mismatch")
		return false

	var v1 = a.sample_wind(Vector3(-4.0, 0.0, 1.0))
	var v2 = a.sample_wind(Vector3(4.0, 0.0, 1.0))
	if v1.is_equal_approx(v2):
		push_error("Wind field should vary spatially across the hex grid")
		return false

	var before = a.sample_wind(Vector3(0.0, 0.0, 0.0))
	for _j in range(12):
		a.step(0.2, 0.78, 2.6, 0.0)
	var after = a.sample_wind(Vector3(0.0, 0.0, 0.0))
	if before.is_equal_approx(after):
		push_error("Temperature differential should alter local wind vectors")
		return false

	print("Wind field deterministic fixture hash: %s" % hash_a)
	return true
