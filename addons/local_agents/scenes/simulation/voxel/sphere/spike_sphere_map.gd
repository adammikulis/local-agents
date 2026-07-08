extends SceneTree

## Phase B1 spike — prove the WORLD↔CELL mapping (the field port's CPU seam) is exact and the kernel-ordered
## neighbour table is valid. Run:
##   godot --headless -s addons/local_agents/scenes/simulation/voxel/sphere/spike_sphere_map.gd
## Prints MAP_REPORT={...}. Gates:
##   roundtrip_ok  — world_to_cell(cell_world_pos(c)) == c for EVERY cell (inverse gnomonic + radial are exact).
##   kernel_nbr_ok — the kernel-slot-ordered neighbour table (0=down..5=up) matches the internal table and its
##                   valid neighbours are in range; boundary = -1.
##   offshell_ok   — points inside the core / above the atmosphere map to -1 (outside the shell).

const SphereGrid = preload("res://addons/local_agents/scenes/simulation/voxel/sphere/SphereGrid.gd")


func _initialize() -> void:
	var g: RefCounted = SphereGrid.new()
	g.build(12, 6, 40.0, 4.0)                     # res=12/face, 6 layers, core_radius 40, cell 4

	# 1) round-trip every cell centre
	var bad: int = 0
	for c in g.cell_count:
		var p: Vector3 = g.cell_world_pos(c)
		var c2: int = g.world_to_cell(p)
		if c2 != c:
			bad += 1
	var roundtrip_ok: bool = bad == 0

	# 2) kernel-order neighbour table valid + consistent with the internal table
	var kn: PackedInt32Array = g.neighbours_kernel_order()
	var knerr: int = 0
	for c in g.cell_count:
		# slot 0 (down) must equal internal N_IN; slot 5 (up) equal internal N_OUT
		if kn[c * 6 + 0] != g.neighbours[c * 6 + SphereGrid.N_IN]:
			knerr += 1
		if kn[c * 6 + 5] != g.neighbours[c * 6 + SphereGrid.N_OUT]:
			knerr += 1
		for slot in 6:
			var n: int = kn[c * 6 + slot]
			if n != -1 and (n < 0 or n >= g.cell_count):
				knerr += 1
	var kernel_nbr_ok: bool = knerr == 0

	# 3) off-shell points → -1
	var inside_core: int = g.world_to_cell(Vector3(10, 0, 0))          # radius 10 < core 40
	var above_atmo: int = g.world_to_cell(Vector3(200, 0, 0))          # radius 200 > 40+6*4=64
	var offshell_ok: bool = inside_core == -1 and above_atmo == -1

	var report: Dictionary = {
		"ok": roundtrip_ok and kernel_nbr_ok and offshell_ok,
		"cell_count": g.cell_count, "surf_count": g.surf_count,
		"roundtrip_ok": roundtrip_ok, "roundtrip_bad": bad,
		"kernel_nbr_ok": kernel_nbr_ok, "kernel_nbr_err": knerr,
		"offshell_ok": offshell_ok,
	}
	print("MAP_REPORT=", JSON.stringify(report))
	quit(0 if report["ok"] else 1)
