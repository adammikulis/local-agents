class_name LASphereGrid
extends RefCounted

## Cubed-sphere grid + seam-aware NEIGHBOUR TABLE — the planet's substrate geometry (Phase A0 spike).
##
## 6 gnomonic cube faces, each `res × res` surface cells, extruded into `depth` RADIAL layers (r=0 = innermost
## core shell, r=depth-1 = outermost/space). This replaces the flat cartesian `idx=(iy*dim_z+iz)*dim_x+ix` +
## `±1/±dx/±layer` scheme: every field kernel will gather its 6 neighbours by TABLE LOOKUP instead of index
## arithmetic, so "down" is simply the INWARD radial neighbour on a real sphere, with no box axes and no poles.
##
## The only hard part is the cube-face SEAMS (a cell on a face edge's lateral neighbour lives on an ADJACENT
## face). We sidestep hand-coding 24 edge transforms + 8 corner cases by building the 2D SURFACE adjacency
## GEOMETRICALLY: step just past the edge in local coords, project to a sphere direction, and match the nearest
## surface cell on another face. Radial neighbours are then trivial arithmetic. (Explicit types only — no ':=' .)

const FACES: int = 6
# Per-cell neighbour slots (flat table = cell*6 + slot):
const N_IN: int = 0    # inward  (r-1); -1 at the core boundary (r==0)
const N_OUT: int = 1   # outward (r+1); -1 at the space boundary (r==depth-1)
const N_A0: int = 2    # -a lateral (surface)
const N_A1: int = 3    # +a lateral
const N_B0: int = 4    # -b lateral
const N_B1: int = 5    # +b lateral

# Cube-face bases: (normal, right=+a axis, up=+b axis). Handedness is irrelevant — the seams are stitched by
# nearest-direction match, so any consistent per-face frame tiles the sphere correctly.
const _FACE_N: Array[Vector3] = [Vector3(1,0,0), Vector3(-1,0,0), Vector3(0,1,0), Vector3(0,-1,0), Vector3(0,0,1), Vector3(0,0,-1)]
const _FACE_R: Array[Vector3] = [Vector3(0,0,-1), Vector3(0,0,1), Vector3(1,0,0), Vector3(1,0,0), Vector3(1,0,0), Vector3(-1,0,0)]
const _FACE_U: Array[Vector3] = [Vector3(0,1,0), Vector3(0,1,0), Vector3(0,0,-1), Vector3(0,0,1), Vector3(0,1,0), Vector3(0,1,0)]

var res: int = 0
var depth: int = 0
var core_radius: float = 0.0
var cell_size: float = 0.0
var surf_count: int = 0          # FACES*res*res
var cell_count: int = 0          # surf_count*depth
var center: Vector3 = Vector3.ZERO

var _dir: PackedVector3Array = PackedVector3Array()        # surf_count unit surface directions
var surf_nbr: PackedInt32Array = PackedInt32Array()        # surf_count*4 : [-a,+a,-b,+b] neighbour surf index
var neighbours: PackedInt32Array = PackedInt32Array()      # cell_count*6 : the full per-cell table (for kernels)


## Local coord of surface cell (i,j) → cube point → unit sphere direction, for face `f`.
func _dir_at(f: int, a_local: float, b_local: float) -> Vector3:
	return (_FACE_N[f] + _FACE_R[f] * a_local + _FACE_U[f] * b_local).normalized()


func _surf_idx(f: int, i: int, j: int) -> int:
	return (f * res + i) * res + j


## Build the grid + tables. res = cells per face edge, depth = radial layers.
func build(p_res: int, p_depth: int, p_core_radius: float, p_cell_size: float, p_center: Vector3 = Vector3.ZERO) -> void:
	res = p_res
	depth = p_depth
	core_radius = p_core_radius
	cell_size = p_cell_size
	center = p_center
	surf_count = FACES * res * res
	cell_count = surf_count * depth

	# 1) Surface directions (cell CENTRES).
	_dir.resize(surf_count)
	for f in FACES:
		for i in res:
			var a: float = (float(i) + 0.5) / float(res) * 2.0 - 1.0
			for j in res:
				var b: float = (float(j) + 0.5) / float(res) * 2.0 - 1.0
				_dir[_surf_idx(f, i, j)] = _dir_at(f, a, b)

	# 2) Surface adjacency: in-face is direct; off-edge is the nearest surface cell on ANOTHER face to the
	#    direction one step past the edge. Closed sphere → every cell has exactly 4 valid neighbours.
	surf_nbr.resize(surf_count * 4)
	var step: float = 2.0 / float(res)     # local-coord spacing between cell centres
	for f in FACES:
		for i in res:
			var a: float = (float(i) + 0.5) / float(res) * 2.0 - 1.0
			for j in res:
				var b: float = (float(j) + 0.5) / float(res) * 2.0 - 1.0
				var s: int = _surf_idx(f, i, j)
				surf_nbr[s * 4 + 0] = _surf_idx(f, i - 1, j) if i > 0 else _seam(f, a - step, b)
				surf_nbr[s * 4 + 1] = _surf_idx(f, i + 1, j) if i < res - 1 else _seam(f, a + step, b)
				surf_nbr[s * 4 + 2] = _surf_idx(f, i, j - 1) if j > 0 else _seam(f, a, b - step)
				surf_nbr[s * 4 + 3] = _surf_idx(f, i, j + 1) if j < res - 1 else _seam(f, a, b + step)

	# 3) Full per-cell 6-neighbour table (radial ± arithmetic + lateral via surf_nbr, same layer).
	neighbours.resize(cell_count * 6)
	for s in surf_count:
		for r in depth:
			var c: int = s * depth + r
			neighbours[c * 6 + N_IN] = (c - 1) if r > 0 else -1
			neighbours[c * 6 + N_OUT] = (c + 1) if r < depth - 1 else -1
			neighbours[c * 6 + N_A0] = surf_nbr[s * 4 + 0] * depth + r
			neighbours[c * 6 + N_A1] = surf_nbr[s * 4 + 1] * depth + r
			neighbours[c * 6 + N_B0] = surf_nbr[s * 4 + 2] * depth + r
			neighbours[c * 6 + N_B1] = surf_nbr[s * 4 + 3] * depth + r


## The surf cell on any OTHER face whose direction is nearest to the off-edge step direction on face `f`.
func _seam(f: int, a_local: float, b_local: float) -> int:
	var target: Vector3 = _dir_at(f, a_local, b_local)
	var best: int = -1
	var best_dot: float = -2.0
	for k in surf_count:
		if k / (res * res) == f:
			continue                       # must land on a different face
		var d: float = target.dot(_dir[k])
		if d > best_dot:
			best_dot = d
			best = k
	return best


func cell_of(f: int, i: int, j: int, r: int) -> int:
	return _surf_idx(f, i, j) * depth + r


func surf_dir(s: int) -> Vector3:
	return _dir[s]


## World position of a cell centre: its surface direction × the layer radius, from the planet centre.
func cell_world_pos(c: int) -> Vector3:
	var s: int = c / depth
	var r: int = c % depth
	return center + _dir[s] * (core_radius + (float(r) + 0.5) * cell_size)

## Outward radial unit at a cell (its surface direction) — used by the GPU for per-cell solar + gravity.
func cell_radial(c: int) -> Vector3:
	return _dir[c / depth]


## WORLD → nearest cell (the cubed-sphere replacement for the box grid's `_col_i`/`_idx`). O(1): inverse
## gnomonic picks the face by the dominant axis, projects to face-local (a,b) → (i,j); the radius picks the
## radial layer. Returns -1 if the point is outside the shell [core_radius, core_radius+depth*cell_size].
func world_to_cell(world_pos: Vector3) -> int:
	var rel: Vector3 = world_pos - center
	var radius: float = rel.length()
	if radius < 0.0001:
		return -1
	var rr: int = int(floor((radius - core_radius) / cell_size))
	if rr < 0 or rr >= depth:
		return -1
	var dir: Vector3 = rel / radius
	var f: int = _face_of(dir)
	# Point on the face plane (dir·n = 1): p = dir / (dir·n); a = p·right, b = p·up ∈ [-1,1].
	var denom: float = dir.dot(_FACE_N[f])
	if denom < 0.0001:
		return -1
	var p: Vector3 = dir / denom
	var a: float = p.dot(_FACE_R[f])
	var b: float = p.dot(_FACE_U[f])
	var i: int = clampi(int((a + 1.0) * 0.5 * float(res)), 0, res - 1)
	var j: int = clampi(int((b + 1.0) * 0.5 * float(res)), 0, res - 1)
	return _surf_idx(f, i, j) * depth + rr

## The cube face whose normal is most aligned with `dir` (dominant axis + sign). Matches _FACE_N order
## [+X,-X,+Y,-Y,+Z,-Z].
func _face_of(dir: Vector3) -> int:
	var ax: float = absf(dir.x)
	var ay: float = absf(dir.y)
	var az: float = absf(dir.z)
	if ax >= ay and ax >= az:
		return 0 if dir.x >= 0.0 else 1
	if ay >= az:
		return 2 if dir.y >= 0.0 else 3
	return 4 if dir.z >= 0.0 else 5


## Neighbour table packed in the GPU KERNEL slot order (matches the water/lava/slump send convention):
## slot 0=inward/down, 1-4=lateral, 5=outward/up. (Internal table order is [IN,OUT,A0,A1,B0,B1].)
func neighbours_kernel_order() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	out.resize(cell_count * 6)
	for c in cell_count:
		var b: int = c * 6
		out[b + 0] = neighbours[b + N_IN]
		out[b + 1] = neighbours[b + N_A0]
		out[b + 2] = neighbours[b + N_A1]
		out[b + 3] = neighbours[b + N_B0]
		out[b + 4] = neighbours[b + N_B1]
		out[b + 5] = neighbours[b + N_OUT]
	return out


## SPIKE self-validation of the seam table. Returns {ok, symmetric, closed, min_dot, max_dot, errors}.
## symmetric = every neighbour relation is mutual (A lists B ⟹ B lists A); closed = every neighbour valid.
## min/max_dot = the alignment of adjacent cell directions (near 1.0 everywhere = a smooth, seam-free surface).
func validate() -> Dictionary:
	var errors: int = 0
	var closed: bool = true
	var symmetric: bool = true
	var min_dot: float = 2.0
	var max_dot: float = -2.0
	for s in surf_count:
		for slot in 4:
			var n: int = surf_nbr[s * 4 + slot]
			if n < 0 or n >= surf_count:
				closed = false
				errors += 1
				continue
			# alignment of neighbouring surface directions (adjacency should be to a NEAR cell)
			var d: float = _dir[s].dot(_dir[n])
			min_dot = minf(min_dot, d)
			max_dot = maxf(max_dot, d)
			# symmetry: n must list s among ITS 4 neighbours
			var mutual: bool = false
			for slot2 in 4:
				if surf_nbr[n * 4 + slot2] == s:
					mutual = true
					break
			if not mutual:
				symmetric = false
				errors += 1
	return {
		"ok": closed and symmetric and errors == 0,
		"closed": closed, "symmetric": symmetric, "errors": errors,
		"surf_count": surf_count, "cell_count": cell_count,
		"min_adj_dot": min_dot, "max_adj_dot": max_dot,
	}
