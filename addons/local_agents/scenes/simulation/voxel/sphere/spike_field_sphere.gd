extends SceneTree

## Phase B1 spike — prove MaterialField3D.setup_sphere lays the field over a SphereGrid: channels allocate to
## cell_count, world↔cell + cell_radial route through the grid, and the box path still allocates (no regression).
## Run: godot --headless -s addons/local_agents/scenes/simulation/voxel/sphere/spike_field_sphere.gd

const SphereGrid = preload("res://addons/local_agents/scenes/simulation/voxel/sphere/SphereGrid.gd")
const FieldScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialField3D.gd")


func _initialize() -> void:
	var grid: RefCounted = SphereGrid.new()
	grid.build(12, 6, 40.0, 4.0)

	var f: Node = FieldScript.new()
	f.setup_sphere(grid)

	var is_sphere: bool = f.is_sphere()
	var cc: int = f._cell_count
	var chan_ok: bool = f._temp.size() == cc and f._water.size() == cc and f._o2.size() == cc \
		and f._lava.size() == cc and f._co2.size() == cc

	# world↔cell round-trips through the FIELD facade (not just the grid)
	var rt_bad: int = 0
	for c in range(0, cc, 7):        # sample every 7th cell
		if f.world_to_cell(f.cell_world_pos_linear(c)) != c:
			rt_bad += 1
	var radial_ok: bool = f.cell_radial(0).is_equal_approx(grid.cell_radial(0))

	# box path still allocates (non-regression)
	var f2: Node = FieldScript.new()
	f2.setup_dims(8, 6, 8, 4.0, Vector3(-16, -12, -16))
	var box_ok: bool = not f2.is_sphere() and f2._temp.size() == 8 * 6 * 8

	var report: Dictionary = {
		"ok": is_sphere and chan_ok and rt_bad == 0 and radial_ok and box_ok,
		"is_sphere": is_sphere, "cell_count": cc,
		"channels_alloc": chan_ok, "roundtrip_bad": rt_bad, "radial_ok": radial_ok,
		"box_path_ok": box_ok,
	}
	print("FIELD_SPHERE_REPORT=", JSON.stringify(report))
	f.free()
	f2.free()
	quit(0 if report["ok"] else 1)
