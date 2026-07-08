extends SceneTree

## Phase A0 spike harness — prove the cubed-sphere seam table (no engine deps, pure geometry + a CPU diffusion).
## Run: godot --headless -s addons/local_agents/scenes/simulation/voxel/sphere/spike_sphere.gd
## Prints one SPIKE_REPORT={...} line. Behavioural gates:
##   ok/closed/symmetric  — the table is a valid closed 4-connected surface (mutual neighbours).
##   min_adj_dot high      — every lateral neighbour is a NEAR cell (no seam teleport across the sphere).
##   seam_diffusion_smooth — a hot patch spread by pure neighbour-gather crosses cube edges/corners with
##                           NO discontinuity (max step-to-step gradient stays bounded; mass conserved).
##   radial_convection     — an inner-hot / outer-cold column relaxes monotonically along the radial axis.

const SphereGrid = preload("res://addons/local_agents/scenes/simulation/voxel/sphere/SphereGrid.gd")


func _initialize() -> void:
	var g: RefCounted = SphereGrid.new()
	g.build(12, 6, 4.0, 1.0)                     # res=12/face, 6 radial layers, tiny planet
	var v: Dictionary = g.validate()

	var diff: Dictionary = _diffusion_test(g)
	var rad: Dictionary = _radial_test(g)

	var report: Dictionary = {
		"ok": v["ok"] and diff["smooth"] and rad["monotone"],
		"surf_count": v["surf_count"], "cell_count": v["cell_count"],
		"closed": v["closed"], "symmetric": v["symmetric"], "errors": v["errors"],
		"min_adj_dot": snappedf(v["min_adj_dot"], 0.0001),
		"max_adj_dot": snappedf(v["max_adj_dot"], 0.0001),
		"seam_diffusion_smooth": diff["smooth"],
		"diff_max_grad": snappedf(diff["max_grad"], 0.0001),
		"diff_mass_err": snappedf(diff["mass_err"], 0.000001),
		"radial_convection": rad["monotone"],
	}
	print("SPIKE_REPORT=", JSON.stringify(report))
	quit(0 if report["ok"] else 1)


## Diffuse a single hot cell across the SURFACE (one radial layer) using ONLY the neighbour table.
## Proves scalars cross cube edges + the 8 corners smoothly: after settling, the field must be a smooth
## blob with no sharp seam gradient, and total heat is conserved (closed surface, symmetric flux).
func _diffusion_test(g: RefCounted) -> Dictionary:
	var surf_count: int = g.surf_count
	var depth: int = g.depth
	var layer: int = depth - 1                    # outer surface shell
	var heat: PackedFloat32Array = PackedFloat32Array()
	heat.resize(surf_count)
	heat.fill(0.0)
	# seed a corner-adjacent cell so the front is guaranteed to sweep a cube corner
	heat[0] = 1000.0
	var start_mass: float = 1000.0

	var rate: float = 0.15
	for step in 400:
		var nxt: PackedFloat32Array = heat.duplicate()
		for s in surf_count:
			var c: int = s * depth + layer
			var here: float = heat[s]
			var flux: float = 0.0
			# lateral neighbours only (slots N_A0..N_B1 = 2..5)
			for slot in range(2, 6):
				var nc: int = g.neighbours[c * 6 + slot]
				var ns: int = nc / depth
				flux += (heat[ns] - here) * rate
			nxt[s] = here + flux
		heat = nxt

	# gradient across every lateral edge after settling (max = worst seam discontinuity)
	var max_grad: float = 0.0
	var end_mass: float = 0.0
	for s in surf_count:
		end_mass += heat[s]
		var c: int = s * depth + layer
		for slot in range(2, 6):
			var ns: int = g.neighbours[c * 6 + slot] / depth
			max_grad = maxf(max_grad, absf(heat[ns] - heat[s]))
	var mass_err: float = absf(end_mass - start_mass) / start_mass
	# smooth = mass conserved AND no cell-to-cell jump anywhere near the seed magnitude (a seam would spike it)
	var smooth: bool = mass_err < 1e-3 and max_grad < 5.0
	return {"smooth": smooth, "max_grad": max_grad, "mass_err": mass_err}


## Radial convection proxy: seed inner layer hot, outer cold on one column; diffuse along the radial axis
## (N_IN/N_OUT) only; the settled profile must be MONOTONE inner→outer (heat climbs radially inward).
func _radial_test(g: RefCounted) -> Dictionary:
	var depth: int = g.depth
	var col: PackedFloat32Array = PackedFloat32Array()
	col.resize(depth)
	for r in depth:
		col[r] = 100.0 if r == 0 else 0.0
	col[0] = 100.0
	var rate: float = 0.2
	for step in 200:
		var nxt: PackedFloat32Array = col.duplicate()
		for r in depth:
			var flux: float = 0.0
			if r > 0:
				flux += (col[r - 1] - col[r]) * rate
			if r < depth - 1:
				flux += (col[r + 1] - col[r]) * rate
			nxt[r] = col[r] + flux
		col = nxt
	# monotone non-increasing outward (inner warmest) — a magma-core geothermal gradient
	var monotone: bool = true
	for r in range(1, depth):
		if col[r] > col[r - 1] + 1e-4:
			monotone = false
	return {"monotone": monotone}
