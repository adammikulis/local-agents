extends SceneTree

# Two shapes, because a bug in the closed-form solid angle that cancels at one resolution generally will
# not at another. Each row is {res, depth, core_radius, cell_size}.
const CASES: Array = [[8, 6, 400.0, 24.0], [16, 12, 400.0, 12.0], [32, 24, 400.0, 6.0]]

func _init() -> void:
	var script: GDScript = load("res://addons/local_agents/sim/sphere/SphereGrid.gd")
	var failed: int = 0
	for spec in CASES:
		var g = script.new()
		g.build(int(spec[0]), int(spec[1]), float(spec[2]), float(spec[3]))
		var v: Dictionary = g.validate()
		# The summed cell volumes must equal the analytic volume of the shell they tile. This is the check
		# that actually proves cell_volume(), rather than only proving the solid angles normalise.
		var r_lo: float = float(spec[2])
		var r_hi: float = r_lo + float(spec[1]) * float(spec[3])
		var shell: float = (4.0 / 3.0) * PI * (r_hi * r_hi * r_hi - r_lo * r_lo * r_lo)
		var summed: float = 0.0
		for c in g.cell_count:
			summed += g.cell_volume(c)
		var vol_rel_err: float = absf(summed - shell) / shell
		var ok: bool = bool(v["ok"]) and vol_rel_err < 1.0e-6
		if not ok:
			failed += 1
		print("GRID_CHECK={\"res\":%d,\"depth\":%d,\"ok\":%s,\"non_reciprocal\":%d,\"tangent_handed_min\":%.4f}" % [
			int(spec[0]), int(spec[1]), str(ok).to_lower(), float(v["solid_angle_err"]) * 1.0e9,
			vol_rel_err * 1.0e6, float(v["volume_ratio"]), int(v["non_reciprocal"]),
			float(v["tangent_handed_min"])])
	# TOTALS. A uniform channel of 1.0 everywhere must weigh exactly (shell volume x density), which is a
	# closed form and nothing to do with how the grid is diced. Then the same field summed FLAT — the way
	# every ledger does it today — is compared against it, so the size of that error is a measured number
	# rather than an argument.
	var g2 = script.new()
	g2.build(16, 12, 400.0, 12.0)
	var ones: PackedFloat32Array = PackedFloat32Array()
	ones.resize(g2.cell_count)
	ones.fill(1.0)
	var no_mask: PackedByteArray = PackedByteArray()
	var t_lo: float = g2.core_radius
	var t_hi: float = t_lo + float(g2.depth) * g2.cell_size
	var shell_m3: float = ((4.0 / 3.0) * PI * (t_hi * t_hi * t_hi - t_lo * t_lo * t_lo)
		)
	var want_kg: float = shell_m3 * float(LASubstances.table()["h2o"]["density"])
	var got_kg: float = LAFieldTotals.substance_kg(g2, ones, no_mask, LAFieldTotals.CELLS_ALL, "h2o")
	var kg_rel: float = absf(got_kg - want_kg) / want_kg
	if kg_rel > 1.0e-6:
		failed += 1
	print("TOTALS_CHECK={\"kg_rel_err_ppm\":%.4f}" % [kg_rel * 1.0e6])
	print("GRID_GATE={\"cases\":%d,\"failed\":%d}" % [CASES.size(), failed])
	quit(1 if failed > 0 else 0)
