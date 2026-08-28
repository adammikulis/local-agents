class_name LAGridRefine
extends RefCounted

## WHERE THE GRID IS FINE. Resolution follows position: a shell around the terrain surface, plus any
## declared box. The vacuum corners and the quiet interior stay coarsest, which is what makes it
## affordable — a uniform box fine enough for a scale height is ~10^10 cells.

## Rock below the surface the shell reaches, metres. The aquifer stands between the surface and the
## water table, and a cell as coarse as the sky cannot hold it.
var below_m: float = 0.0
## Air above the surface the shell reaches, metres — the column the atmosphere is modelled over.
var above_m: float = 0.0
## World-space boxes refined whatever the terrain says.
var regions: Array[AABB] = []


static func shell(p_below_m: float, p_above_m: float) -> LAGridRefine:
	var r: LAGridRefine = LAGridRefine.new()
	r.below_m = maxf(p_below_m, 0.0)
	r.above_m = maxf(p_above_m, 0.0)
	return r


static func box(region: AABB) -> LAGridRefine:
	var r: LAGridRefine = LAGridRefine.new()
	r.regions.append(region)
	return r


## Nothing to refine: the box stays uniform at its coarsest level.
func empty() -> bool:
	return regions.is_empty() and (below_m <= 0.0 and above_m <= 0.0)


## Per base cell: 1 where the grid refines. A cell counts when its own CUBE reaches the shell, not
## just its centre, or the shell comes out thinner than the cells it is made of.
func mask(grid: LAVoxelGrid, body_centre: Vector3, terrain) -> PackedByteArray:
	var base_count: int = grid.nx * grid.ny * grid.nz
	var out: PackedByteArray = PackedByteArray()
	out.resize(base_count)
	if empty() or grid.cell_size <= 0.0:
		return out
	var pad: float = 0.5 * sqrt(3.0) * grid.cell_size
	var can_surface: bool = below_m + above_m > 0.0 and terrain != null \
		and terrain.has_method("surface_radius")
	for b in base_count:
		var v: Vector3i = _coords(grid, b)
		# THE BOX EDGE STAYS COARSEST. Its faces are where the exterior is prescribed and where a torus
		# wraps, and both are one cell onto one cell.
		if v.x == 0 or v.y == 0 or v.z == 0 or v.x == grid.nx - 1 or v.y == grid.ny - 1 \
				or v.z == grid.nz - 1:
			continue
		var p: Vector3 = grid.origin + (Vector3(v) + Vector3(0.5, 0.5, 0.5)) * grid.cell_size
		var hit: bool = false
		for region: AABB in regions:
			if region.grow(pad).has_point(p):
				hit = true
				break
		if not hit and can_surface:
			var rel: Vector3 = p - body_centre
			var r: float = rel.length()
			if r > 0.0:
				var rs: float = float(terrain.surface_radius(rel / r))
				hit = r >= rs - below_m - pad and r <= rs + above_m + pad
		out[b] = 1 if hit else 0
	return out


func _coords(grid: LAVoxelGrid, b: int) -> Vector3i:
	return Vector3i(b % grid.nx, (b / grid.nx) % grid.ny, b / (grid.nx * grid.ny))
