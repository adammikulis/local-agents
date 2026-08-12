class_name LASphereGrid
extends RefCounted


const FACES: int = 6
# Per-cell neighbour slots (flat table = cell*6 + slot). OPPOSITE SLOT IS `d ^ 1` for all three pairs.
const N_IN: int = 0    # inward  (r-1); -1 at the core boundary (r==0)
const N_OUT: int = 1   # outward (r+1); -1 at the space boundary (r==depth-1)
const N_A0: int = 2    # lateral pair A, entry end  (in a face interior: the -a lateral)
const N_A1: int = 3    # lateral pair A, exit  end  (in a face interior: the +a lateral)
const N_B0: int = 4    # lateral pair B, entry end  (in a face interior: the -b lateral)
const N_B1: int = 5    # lateral pair B, exit  end  (in a face interior: the +b lateral)

# GEOMETRIC surface-adjacency slots (flat table = surf*4 + slot) — `surf_nbr` only. These keep their literal
# axis meaning; the reciprocal pairing above is a permutation of them stored in `lateral_slot`.
const S_A0: int = 0    # -a lateral
const S_A1: int = 1    # +a lateral
const S_B0: int = 2    # -b lateral
const S_B1: int = 3    # +b lateral

const _FACE_N: Array[Vector3] = [Vector3(1,0,0), Vector3(-1,0,0), Vector3(0,1,0), Vector3(0,-1,0), Vector3(0,0,1), Vector3(0,0,-1)]
const _FACE_R: Array[Vector3] = [Vector3(0,0,-1), Vector3(0,0,1), Vector3(1,0,0), Vector3(1,0,0), Vector3(1,0,0), Vector3(-1,0,0)]
const _FACE_U: Array[Vector3] = [Vector3(0,1,0), Vector3(0,1,0), Vector3(0,0,-1), Vector3(0,0,1), Vector3(0,1,0), Vector3(0,1,0)]

var res: int = 0
var depth: int = 0
var core_radius: float = 0.0
var cell_size: float = 0.0       # MEAN radial thickness; equals every shell's only when `shells_uniform`
var surf_count: int = 0          # FACES*res*res
var cell_count: int = 0          # surf_count*depth
var center: Vector3 = Vector3.ZERO

# RADIAL SHELL TABLE. `cell_size` is one number for the whole column; these are per shell, so the grid can be
# graded (thin near the surface, thick aloft and at depth) without every consumer assuming a constant step.
var shells_uniform: bool = true
var shell_dr: PackedFloat32Array = PackedFloat32Array()      # depth   : radial thickness of shell r
var shell_mid: PackedFloat32Array = PackedFloat32Array()     # depth   : radius of shell r's centre
var shell_face: PackedFloat32Array = PackedFloat32Array()    # depth+1 : shell boundary radii, inward first
var shell_d_out: PackedFloat32Array = PackedFloat32Array()   # depth   : centre-to-centre run to r+1
var shell_d_in: PackedFloat32Array = PackedFloat32Array()    # depth   : centre-to-centre run to r-1
var shell_vol: PackedFloat32Array = PackedFloat32Array()     # depth   : cell volume per unit solid angle

# A cubed-sphere cell does not subtend a fixed solid angle: gnomonic cells shrink toward a face corner.
var surf_omega: PackedFloat32Array = PackedFloat32Array()    # surf_count : cell solid angle, steradians

var _dir: PackedVector3Array = PackedVector3Array()        # surf_count unit surface directions
var _cell_vol: PackedFloat32Array = PackedFloat32Array()   # cell_count : omega*shell_vol, model units^3
var surf_nbr: PackedInt32Array = PackedInt32Array()        # surf_count*4 : [-a,+a,-b,+b] neighbour surf index
var neighbours: PackedInt32Array = PackedInt32Array()      # cell_count*6 : the full per-cell table (for kernels)
var link_partner: PackedInt32Array = PackedInt32Array()

var _back: PackedInt32Array = PackedInt32Array()           # surf_count*4 : partner's geometric slot pointing back
var lateral_slot: PackedInt32Array = PackedInt32Array()    # surf_count*4 : geometric slot -> lateral pair slot 0..3
var lateral_bends: int = 0       # links whose pair had to be bent away from the geometric axis (seam repair)

# TANGENT FRAME — its own table, independent of the lateral slots. Indexed by SURFACE cell:
# every radial layer of a column shares one frame, because the frame is a direction, not a position.
var tan_a: PackedVector3Array = PackedVector3Array()       # surf_count : unit tangent axis A (face +a, projected)
var tan_b: PackedVector3Array = PackedVector3Array()       # surf_count : unit tangent axis B = radial x tan_a
# surf_count*4*2, indexed (surf*4 + lateral_slot)*2 — LATERAL SLOT ORDER, i.e. kernel slots 1..4 are l = 0..3.
var link_tan: PackedFloat32Array = PackedFloat32Array()    # unit direction toward that neighbour, in MY (a,b)
var link_rot: PackedFloat32Array = PackedFloat32Array()    # (cos, sin) transporting MY (a,b) into the NEIGHBOUR's
var link_arc: PackedFloat32Array = PackedFloat32Array()    # radians between cell centres, per lateral slot


## Local coord of surface cell (i,j) → cube point → unit sphere direction, for face `f`.
func _dir_at(f: int, a_local: float, b_local: float) -> Vector3:
	return (_FACE_N[f] + _FACE_R[f] * a_local + _FACE_U[f] * b_local).normalized()


func _surf_idx(f: int, i: int, j: int) -> int:
	return (f * res + i) * res + j


## Build the grid + tables. res = cells per face edge, depth = radial layers. `p_shell_dr`, when it carries
## exactly `p_depth` positive entries, grades the shells and `p_cell_size` becomes their mean.
func build(p_res: int, p_depth: int, p_core_radius: float, p_cell_size: float, p_center: Vector3 = Vector3.ZERO,
		p_shell_dr: PackedFloat32Array = PackedFloat32Array()) -> void:
	res = p_res
	depth = p_depth
	core_radius = p_core_radius
	cell_size = p_cell_size
	center = p_center
	surf_count = FACES * res * res
	cell_count = surf_count * depth
	_build_shells(p_shell_dr)

	# 1) Surface directions (cell CENTRES).
	_dir.resize(surf_count)
	for f in FACES:
		for i in res:
			var a: float = (float(i) + 0.5) / float(res) * 2.0 - 1.0
			for j in res:
				var b: float = (float(j) + 0.5) / float(res) * 2.0 - 1.0
				_dir[_surf_idx(f, i, j)] = _dir_at(f, a, b)
	_build_omega()

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
				surf_nbr[s * 4 + S_A0] = _surf_idx(f, i - 1, j) if i > 0 else _seam(f, a - step, b)
				surf_nbr[s * 4 + S_A1] = _surf_idx(f, i + 1, j) if i < res - 1 else _seam(f, a + step, b)
				surf_nbr[s * 4 + S_B0] = _surf_idx(f, i, j - 1) if j > 0 else _seam(f, a, b - step)
				surf_nbr[s * 4 + S_B1] = _surf_idx(f, i, j + 1) if j < res - 1 else _seam(f, a, b + step)

	# 3) Turn that geometric adjacency into a SLOT-OPPOSITE-RECIPROCAL lateral pairing.
	_build_back_slots()
	_build_lateral_slots()

	# 3b) The TANGENT FRAME. A different question from the pairing, so a different table.
	_build_tangent_basis()
	_build_link_frames()

	# 4) Full per-cell 6-neighbour table (radial ± arithmetic + lateral via the reciprocal pairing, same layer).
	neighbours.resize(cell_count * 6)
	for s in surf_count:
		for r in depth:
			var c: int = s * depth + r
			neighbours[c * 6 + N_IN] = (c - 1) if r > 0 else -1
			neighbours[c * 6 + N_OUT] = (c + 1) if r < depth - 1 else -1
			for g in 4:
				neighbours[c * 6 + N_A0 + lateral_slot[s * 4 + g]] = surf_nbr[s * 4 + g] * depth + r
	_build_link_partner()


## The radial tables. An empty or wrong-length profile is the UNIFORM grid, and its centres are formed by the
## same expression the kernels used before this table existed, so a uniform build reproduces them exactly.
func _build_shells(p_shell_dr: PackedFloat32Array) -> void:
	shells_uniform = p_shell_dr.size() != depth
	if not shells_uniform:
		for r in depth:
			if p_shell_dr[r] <= 0.0:
				shells_uniform = true
				break
	shell_dr.resize(depth)
	shell_mid.resize(depth)
	shell_face.resize(depth + 1)
	shell_d_out.resize(depth)
	shell_d_in.resize(depth)
	shell_vol.resize(depth)
	shell_face[0] = core_radius
	if shells_uniform:
		for r in depth:
			shell_dr[r] = cell_size
			shell_mid[r] = core_radius + (float(r) + 0.5) * cell_size
			shell_face[r + 1] = core_radius + float(r + 1) * cell_size
			shell_d_out[r] = cell_size
			shell_d_in[r] = cell_size
	else:
		var span: float = 0.0
		for r in depth:
			shell_dr[r] = p_shell_dr[r]
			shell_face[r + 1] = shell_face[r] + p_shell_dr[r]
			shell_mid[r] = shell_face[r] + p_shell_dr[r] * 0.5
			span += p_shell_dr[r]
		cell_size = span / float(depth)
	for r in depth:
		if not shells_uniform:
			shell_d_out[r] = (shell_mid[r + 1] - shell_mid[r]) if r < depth - 1 else shell_dr[r]
			shell_d_in[r] = (shell_mid[r] - shell_mid[r - 1]) if r > 0 else shell_dr[r]
		var lo: float = shell_face[r]
		var hi: float = shell_face[r + 1]
		shell_vol[r] = (hi * hi * hi - lo * lo * lo) / 3.0


## Solid angle subtended by the gnomonic quad [-1,1]^2 corner (a, b), Van Oosterom & Strackee.
func _omega_corner(a: float, b: float) -> float:
	return atan2(a * b, sqrt(1.0 + a * a + b * b))


## Exact per-cell solid angle, and the cell volumes that follow from it. Sums to 4*pi over the six faces.
func _build_omega() -> void:
	surf_omega.resize(surf_count)
	for f in FACES:
		for i in res:
			var a0: float = float(i) / float(res) * 2.0 - 1.0
			var a1: float = float(i + 1) / float(res) * 2.0 - 1.0
			for j in res:
				var b0: float = float(j) / float(res) * 2.0 - 1.0
				var b1: float = float(j + 1) / float(res) * 2.0 - 1.0
				surf_omega[_surf_idx(f, i, j)] = _omega_corner(a1, b1) - _omega_corner(a0, b1) \
					- _omega_corner(a1, b0) + _omega_corner(a0, b0)
	_cell_vol.resize(cell_count)
	for s in surf_count:
		for r in depth:
			_cell_vol[s * depth + r] = surf_omega[s] * shell_vol[r]


## Volume of every cell, model units^3, as the kernels read it (kernels3d/cellvol.glsli, binding 40). The
## channels are fill fractions, so a conserved substance is the sum of channel*volume, never the bare sum.
func cell_volumes() -> PackedFloat32Array:
	return _cell_vol


## Thinnest (`want_max` false) or thickest shell in the table.
func _dr_extreme(want_max: bool) -> float:
	if depth <= 0:
		return 0.0
	var best: float = shell_dr[0]
	for r in depth:
		best = maxf(best, shell_dr[r]) if want_max else minf(best, shell_dr[r])
	return best


## Total radial span of the shell, from the core boundary to space.
func shell_span() -> float:
	return shell_face[depth] - core_radius if depth > 0 else 0.0


## Radial layer containing `radius`, or -1 outside the shell. Boundary search, so it answers a graded profile
## and a uniform one the same way.
func shell_of(radius: float) -> int:
	if depth <= 0 or radius < shell_face[0] or radius >= shell_face[depth]:
		return -1
	var lo: int = 0
	var hi: int = depth - 1
	while lo < hi:
		var mid: int = (lo + hi + 1) / 2
		if radius >= shell_face[mid]:
			lo = mid
		else:
			hi = mid - 1
	return lo


## Nearest shell BOUNDARY index to `radius`, 0..depth. A different question from `shell_of`, which answers
## which cell contains the radius; a water LEVEL is a face, a cell index is not.
func face_of(radius: float) -> int:
	if depth <= 0:
		return 0
	var best: int = 0
	var best_d: float = absf(shell_face[0] - radius)
	for i in range(1, depth + 1):
		var d: float = absf(shell_face[i] - radius)
		if d < best_d:
			best_d = d
			best = i
	return best


## The shell table flattened for the GPU: `SHELL_STRIDE` floats per shell, in `shell.glsli`'s field order.
func shell_table() -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(depth * 4)
	for r in depth:
		out[r * 4 + 0] = shell_dr[r]
		out[r * 4 + 1] = shell_mid[r]
		out[r * 4 + 2] = shell_d_out[r]
		out[r * 4 + 3] = shell_d_in[r]
	return out


## Resolve each link to the flat slot index that answers it. Derived, never assumed: it searches the
## neighbour's own six slots for the one pointing back, so a table that is not reciprocal yields -1 here and
## `validate()` reports it rather than a kernel silently reading someone else's flux.
func _build_link_partner() -> void:
	link_partner.resize(cell_count * 6)
	for c in cell_count:
		for d in 6:
			var m: int = neighbours[c * 6 + d]
			if m < 0:
				link_partner[c * 6 + d] = -1
				continue
			var found: int = -1
			for e in 6:
				if neighbours[m * 6 + e] == c:
					found = m * 6 + e
					break
			link_partner[c * 6 + d] = found


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


## For every surface link (s, geometric slot g), the slot the PARTNER uses to point back at s. -1 if the stitch
## failed to produce a mutual link (should never happen on a closed sphere; `validate().symmetric` reports it).
func _build_back_slots() -> void:
	_back.resize(surf_count * 4)
	_back.fill(-1)
	for s in surf_count:
		for g in 4:
			var m: int = surf_nbr[s * 4 + g]
			if m < 0 or m >= surf_count:
				continue
			for g2 in 4:
				if surf_nbr[m * 4 + g2] == s:
					_back[s * 4 + g] = g2
					break


## How many of `s`'s 4 lateral links currently belong to family `f`.
func _family_count(fam: PackedInt32Array, s: int, f: int) -> int:
	var n: int = 0
	for g in 4:
		if fam[s * 4 + g] == f:
			n += 1
	return n


## Seed each link's family from the geometry (family 0 = the ±a axis, 1 = ±b). Where the two ends disagree —
## the rotated cube edges — the lower cell index wins, deterministically. Both ends compute the same answer.
func _seed_families() -> PackedInt32Array:
	var fam: PackedInt32Array = PackedInt32Array()
	fam.resize(surf_count * 4)
	fam.fill(0)
	for s in surf_count:
		for g in 4:
			var m: int = surf_nbr[s * 4 + g]
			var bg: int = _back[s * 4 + g]
			if m < 0 or bg < 0:
				fam[s * 4 + g] = g / 2
				continue
			var mine: int = g / 2
			var theirs: int = bg / 2
			if mine == theirs:
				fam[s * 4 + g] = mine
			else:
				fam[s * 4 + g] = mine if s < m else theirs
	return fam


## Repair to the 2-factor condition (every cell exactly 2 links of each family). Two stages: a cheap adjacent-
## pair sweep that resolves the whole seam in one pass at even `res`, then a general augmenting search for
## whatever is left. Returns the number of links flipped away from their geometric family.
func _repair_families(fam: PackedInt32Array) -> int:
	return _repair_pairs(fam) + _repair_augment(fam)


## Stage 1 — flip a link shared by TWO cells that are unbalanced the SAME way: one flip fixes both. Along a
## rotated seam every cell of the column is unbalanced identically, so this walks the column pairing them off
## and is the only stage that runs when `res` is even (measured: exactly 2·res flips, i.e. res/2 per seam).
func _repair_pairs(fam: PackedInt32Array) -> int:
	var flips: int = 0
	var progress: bool = true
	var passes: int = 0
	while progress and passes < 8:
		progress = false
		passes += 1
		for s in surf_count:
			var da: int = _family_count(fam, s, 0)
			if da == 2:
				continue
			var give: int = 0 if da > 2 else 1        # the family this cell has too many of
			for g in 4:
				if fam[s * 4 + g] != give:
					continue
				var m: int = surf_nbr[s * 4 + g]
				var bg: int = _back[s * 4 + g]
				if m < 0 or bg < 0:
					continue
				var dm: int = _family_count(fam, m, 0)
				if (give == 0 and dm <= 2) or (give == 1 and dm >= 2):
					continue                          # the far end does not want to give the same family away
				fam[s * 4 + g] = 1 - give
				fam[m * 4 + bg] = 1 - give
				flips += 1
				progress = true
				break
	return flips


func _repair_augment(fam: PackedInt32Array) -> int:
	var flips: int = 0
	var rounds: int = 0
	for u0 in surf_count:
		while _family_count(fam, u0, 0) != 2 and rounds < surf_count:
			rounds += 1
			var applied: int = _augment_once(fam, u0)
			if applied <= 0:
				break                                 # no path exists — validate() will report the residue
			flips += applied
	return flips


## One breadth-first alternating path from `u0`. A search state is (cell, kind) where kind 0 = the next link
## taken must be family A and is flipped to B, kind 1 = the next must be B and is flipped to A. The path ends
## at the first cell the arriving flip pushes toward balance. Returns the number of links flipped (0 = none).
func _augment_once(fam: PackedInt32Array, u0: int) -> int:
	var t0: int = 0 if _family_count(fam, u0, 0) > 2 else 1
	var prev_state: PackedInt32Array = PackedInt32Array()
	prev_state.resize(surf_count * 2)
	prev_state.fill(-2)                               # -2 = unvisited, -1 = the start state
	var prev_slot: PackedInt32Array = PackedInt32Array()
	prev_slot.resize(surf_count * 2)
	prev_slot.fill(-1)
	var queue: PackedInt32Array = PackedInt32Array([u0 * 2 + t0])
	prev_state[u0 * 2 + t0] = -1
	var head: int = 0
	var goal: int = -1
	while head < queue.size() and goal < 0:
		var st: int = queue[head]
		head += 1
		var v: int = st / 2
		var t: int = st % 2
		for g in 4:
			if fam[v * 4 + g] != t:
				continue
			var w: int = surf_nbr[v * 4 + g]
			if w < 0 or _back[v * 4 + g] < 0:
				continue
			var ns: int = w * 2 + (1 - t)
			if prev_state[ns] != -2:
				continue
			prev_state[ns] = st
			prev_slot[ns] = g
			var dw: int = _family_count(fam, w, 0)
			# `w != u0`: ending back on the start cell would move it TWICE in the same direction, turning a
			# deficit of one into a surplus of one instead of balancing it. Passing THROUGH u0 is still fine
			# (it gains and loses one link there), so u0 stays expandable — it just cannot be the endpoint.
			if w != u0 and ((t == 0 and dw > 2) or (t == 1 and dw < 2)):
				goal = ns                             # this flip balances the far end: path complete
				break
			queue.append(ns)
	if goal < 0:
		return 0
	# Reconstruct. A path may in principle cross the same link once from each end; flipping it twice is a
	# no-op that would leave the cells between the two crossings unbalanced, so reject rather than corrupt.
	var used: Dictionary = {}
	var cur: int = goal
	while prev_state[cur] != -1:
		var pv: int = prev_state[cur] / 2
		var pg: int = prev_slot[cur]
		var pw0: int = surf_nbr[pv * 4 + pg]
		# canonical link id: the (cell, slot) pair as seen from the LOWER-indexed of its two ends
		var key: int = (pv * 4 + pg) if pv < pw0 else (pw0 * 4 + _back[pv * 4 + pg])
		if used.has(key):
			return 0
		used[key] = true
		cur = prev_state[cur]
	var flips: int = 0
	cur = goal
	while prev_state[cur] != -1:
		var pst: int = prev_state[cur]
		var pv2: int = pst / 2
		var pg2: int = prev_slot[cur]
		var pw: int = surf_nbr[pv2 * 4 + pg2]
		var pbg: int = _back[pv2 * 4 + pg2]
		var flipped: int = 1 - fam[pv2 * 4 + pg2]
		fam[pv2 * 4 + pg2] = flipped
		fam[pw * 4 + pbg] = flipped
		flips += 1
		cur = pst
	return flips


## Orient each family: its links form disjoint cycles (2 per cell), so walking a cycle and calling the link we
## LEAVE by "exit" and the one we ARRIVE by "entry" puts every link in opposite slots at its two ends.
func _orient_families(fam: PackedInt32Array) -> void:
	lateral_slot.resize(surf_count * 4)
	lateral_slot.fill(-1)
	for f in 2:
		var in_slot: int = 0 if f == 0 else 2
		var out_slot: int = 1 if f == 0 else 3
		for s in surf_count:
			for g in 4:
				if fam[s * 4 + g] != f or lateral_slot[s * 4 + g] >= 0:
					continue
				var cur: int = s
				var og: int = g
				while lateral_slot[cur * 4 + og] < 0:
					var m: int = surf_nbr[cur * 4 + og]
					var bg: int = _back[cur * 4 + og]
					if m < 0 or bg < 0:
						break
					lateral_slot[cur * 4 + og] = out_slot
					lateral_slot[m * 4 + bg] = in_slot
					var nxt: int = -1
					for g2 in 4:
						if g2 != bg and fam[m * 4 + g2] == f:
							nxt = g2
							break
					if nxt < 0:
						break
					cur = m
					og = nxt


## Seed → repair → orient, then a hard guard: every cell's four lateral slots must be a permutation of 0..3.
## A cell that failed (only possible if the stitch itself is broken) falls back to the raw geometric order, so
## the table stays well-formed and `validate()` reports the residual non-reciprocity instead of hiding it.
func _build_lateral_slots() -> void:
	var fam: PackedInt32Array = _seed_families()
	lateral_bends = _repair_families(fam)
	_orient_families(fam)
	for s in surf_count:
		var mask: int = 0
		for g in 4:
			var v: int = lateral_slot[s * 4 + g]
			if v >= 0 and v < 4:
				mask |= 1 << v
		if mask != 15:
			for g in 4:
				lateral_slot[s * 4 + g] = g


# ---------------------------------------------------------------------------------------------------------
# TANGENT FRAME + per-link direction/rotation. Built from the FACE geometry, never from the lateral slots.
# ---------------------------------------------------------------------------------------------------------

func _build_tangent_basis() -> void:
	tan_a.resize(surf_count)
	tan_b.resize(surf_count)
	var per_face: int = res * res
	for s in surf_count:
		var f: int = s / per_face
		var n: Vector3 = _dir[s]
		var ax: Vector3 = _FACE_R[f] - n * _FACE_R[f].dot(n)
		tan_a[s] = ax.normalized()
		tan_b[s] = n.cross(tan_a[s])


## Rotate `v` by the same rotation that carries the unit `n_from` onto the unit `n_to` — parallel transport
## along the great circle joining two adjacent cells. Length-preserving, so momentum transported across a seam
## keeps its magnitude; the only thing it changes is which plane the vector lives in.
func _transport(v: Vector3, n_from: Vector3, n_to: Vector3) -> Vector3:
	var axis: Vector3 = n_from.cross(n_to)
	var alen: float = axis.length()
	if alen < 1.0e-9:
		return v
	return v.rotated(axis / alen, atan2(alen, n_from.dot(n_to)))


func _build_link_frames() -> void:
	link_tan.resize(surf_count * 8)
	link_rot.resize(surf_count * 8)
	link_arc.resize(surf_count * 4)
	link_tan.fill(0.0)
	link_rot.fill(0.0)
	link_arc.fill(0.0)
	for s in surf_count:
		var ns: Vector3 = _dir[s]
		var a_s: Vector3 = tan_a[s]
		var b_s: Vector3 = tan_b[s]
		for g in 4:
			var m: int = surf_nbr[s * 4 + g]
			var l: int = lateral_slot[s * 4 + g]
			if m < 0 or m >= surf_count or l < 0 or l > 3:
				continue
			var nm: Vector3 = _dir[m]
			var base: int = (s * 4 + l) * 2
			# Direction toward the neighbour, flattened into MY tangent plane.
			var d: Vector3 = nm - ns
			d = d - ns * d.dot(ns)
			if d.length_squared() > 1.0e-16:
				d = d.normalized()
				link_tan[base + 0] = d.dot(a_s)
				link_tan[base + 1] = d.dot(b_s)
			# Transport my axes onto the neighbour's tangent plane and read them off in the neighbour's axes.
			# Two right-handed frames sharing a normal differ by a rotation, so (cos, sin) is the whole map:
			# (va, vb) in mine becomes (va*cos - vb*sin, va*sin + vb*cos) in theirs.
			var at: Vector3 = _transport(a_s, ns, nm)
			link_rot[base + 0] = at.dot(tan_a[m])
			link_rot[base + 1] = at.dot(tan_b[m])
			# Angle between the two cell directions. Times the radius it is the arc between their centres,
			# which is the lateral RUN any slope test needs.
			link_arc[s * 4 + l] = ns.angle_to(nm)


## Cell-indexed accessors for the per-surface frame (callers hold cell indices, columns are contiguous).
func tangent_a(c: int) -> Vector3:
	return tan_a[c / depth]


func tangent_b(c: int) -> Vector3:
	return tan_b[c / depth]


## Transport a tangent vector's (a, b) components from cell `c`'s frame into the frame of the neighbour that
## sits in LATERAL slot `l` (0..3 == kernel slots 1..4). The inverse direction is the neighbour's own entry for
## the reverse slot `l ^ 1`, which slot-opposite reciprocity guarantees exists.
func rotate_into_neighbour(c: int, l: int, v: Vector2) -> Vector2:
	var base: int = ((c / depth) * 4 + l) * 2
	var cs: float = link_rot[base + 0]
	var sn: float = link_rot[base + 1]
	return Vector2(v.x * cs - v.y * sn, v.x * sn + v.y * cs)


## Unit direction from cell `c` toward its LATERAL slot `l` neighbour, in `c`'s own (tan_a, tan_b) components.
func link_dir(c: int, l: int) -> Vector2:
	var base: int = ((c / depth) * 4 + l) * 2
	return Vector2(link_tan[base + 0], link_tan[base + 1])


func cell_of(f: int, i: int, j: int, r: int) -> int:
	return _surf_idx(f, i, j) * depth + r


func surf_dir(s: int) -> Vector3:
	return _dir[s]


## World position of a cell centre: its surface direction × the layer radius, from the planet centre.
func cell_world_pos(c: int) -> Vector3:
	var s: int = c / depth
	var r: int = c % depth
	return center + _dir[s] * shell_mid[r]

## Outward radial unit at a cell (its surface direction) — used by the GPU for per-cell solar + gravity.
func cell_radial(c: int) -> Vector3:
	return _dir[c / depth]


## WORLD → nearest cell (the cubed-sphere replacement for the box grid's `_col_i`/`_idx`). Inverse gnomonic
## picks the face by the dominant axis, projects to face-local (a,b) → (i,j); `shell_of` picks the radial
## layer. Returns -1 if the point is outside the shell.
func world_to_cell(world_pos: Vector3) -> int:
	var rel: Vector3 = world_pos - center
	var radius: float = rel.length()
	if radius < 0.0001:
		return -1
	var rr: int = shell_of(radius)
	if rr < 0:
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
			# set-level symmetry: n must list s among ITS 4 neighbours
			var mutual: bool = false
			for slot2 in 4:
				if surf_nbr[n * 4 + slot2] == s:
					mutual = true
					break
			if not mutual:
				symmetric = false
				errors += 1
	var non_recip: int = 0
	for c in cell_count:
		for d2 in 6:
			var m: int = neighbours[c * 6 + d2]
			if m < 0:
				continue
			if neighbours[m * 6 + (d2 ^ 1)] != c:
				non_recip += 1
	errors += non_recip
	var handed_min: float = 2.0
	for s in surf_count:
		handed_min = minf(handed_min, tan_a[s].cross(tan_b[s]).dot(_dir[s]))
	var face_handed_min: float = 2.0
	for f in FACES:
		face_handed_min = minf(face_handed_min, _FACE_R[f].cross(_FACE_U[f]).dot(_FACE_N[f]))
	var omega_total: float = 0.0
	var omega_min: float = INF
	var omega_max: float = 0.0
	for s in surf_count:
		omega_total += surf_omega[s]
		omega_min = minf(omega_min, surf_omega[s])
		omega_max = maxf(omega_max, surf_omega[s])
	if handed_min < 0.999:
		errors += 1
	return {
		"ok": closed and symmetric and non_recip == 0 and errors == 0,
		"closed": closed, "symmetric": symmetric, "errors": errors,
		"reciprocal": non_recip == 0, "non_reciprocal": non_recip, "lateral_bends": lateral_bends,
		"surf_count": surf_count, "cell_count": cell_count,
		"shells_uniform": shells_uniform, "shell_span": shell_span(),
		"shell_dr_min": _dr_extreme(false), "shell_dr_max": _dr_extreme(true),
		"min_adj_dot": min_dot, "max_adj_dot": max_dot,
		"tangent_handed_min": handed_min, "face_handed_min": face_handed_min,
		"omega_total": omega_total, "omega_min": omega_min, "omega_max": omega_max,
	}
