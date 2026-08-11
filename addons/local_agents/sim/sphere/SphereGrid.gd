class_name LASphereGrid
extends RefCounted

## Cubed-sphere grid + seam-aware NEIGHBOUR TABLE: the planet's substrate geometry (Phase A0 spike).
##
## 6 gnomonic cube faces, each `res × res` surface cells, extruded into `depth` RADIAL layers (r=0 = innermost
## core shell, r=depth-1 = outermost/space). This replaces the flat cartesian `idx=(iy*dim_z+iz)*dim_x+ix` +
## `±1/±dx/±layer` scheme: every field kernel will gather its 6 neighbours by TABLE LOOKUP instead of index
## arithmetic, so "down" is simply the INWARD radial neighbour on a real sphere, with no box axes and no poles.
##
## The only hard part is the cube-face SEAMS (a cell on a face edge's lateral neighbour lives on an ADJACENT
## face). We sidestep hand-coding 24 edge transforms + 8 corner cases by building the 2D SURFACE adjacency
## GEOMETRICALLY: step just past the edge in local coords, project to a sphere direction, and match the nearest
## surface cell on another face. Radial neighbours are then trivial arithmetic. (Explicit types only, no ':=' inferred typing.)
##
## SLOT-OPPOSITE RECIPROCITY (the contract the kernels actually depend on)
## ----------------------------------------------------------------------
## Every 2-pass gather kernel (`soil_/water_/slump_/lava_flow_sphere3d.glsl`) writes its outflow to
## `send[me*6 + slot]` and credits its inflow from `send[neighbour*6 + OPPOSITE(slot)]`. That is only
## mass-conserving if the table is RECIPROCAL IN THE OPPOSITE SLOT: `nbr[c*6+d] == m  ⟹  nbr[m*6+(d^1)] == c`.
## Merely "A lists B somewhere" is not enough — a link placed in the wrong slot debits a send slot that NO cell
## reads (mass destroyed) and makes some other slot get read twice (mass duplicated).
##
## The raw geometric stitch does NOT satisfy that, and no choice of per-face axes can fix it. Measured on the
## unrepaired table at res 24: 288 of 576 directed cross-face links per radial layer land in a non-opposite
## slot — 4 of the 12 cube edges have their local (a,b) axes ROTATED across the seam (a face-0 `+b` link is the
## partner's `+a` link) and 2 more have them REFLECTED (both sides say `+b`). The rotation is irreducible: with
## the grid lines kept straight, each face is crossed by exactly two of the three great-ring families (X-, Y-,
## Z-rings), so labelling a family "the a-axis" globally requires 2-colouring a triangle. It cannot be done.
##
## The fix is to stop treating the four lateral slots as fixed compass directions and treat them as two
## RECIPROCAL PAIRS: partition each cell's 4 lateral links into pair A (slots N_A0/N_A1) and pair B
## (N_B0/N_B1) such that every link sits in the opposite slot at both ends. That partition is a 2-factorisation
## of the 4-regular surface adjacency graph, which always exists (Petersen). We seed it from the geometry — so
## in the interior of every face pair A really is the ±a axis and pair B the ±b axis, exactly as before — and
## REPAIR only the seams where the geometry contradicts itself, by BENDING the affected line at a handful of
## cells near the four rotated cube edges. Those bends are the topological branch cuts the 8 cube corners
## demand, and there are O(res) of them, not O(res²): `lateral_bends` measures 2·res at even `res` and 6·res at
## odd (an odd seam column cannot pair off internally, so its leftover cell routes a longer path) — at res 24
## that is 48 bent links out of 6912. `surf_nbr` keeps its literal geometric meaning (WaterSurfaceMesh and
## MaterialFieldLakes3D build quads and drainage from it), so only the 6-slot `neighbours` table is permuted.
##
## THE TANGENT BASIS IS A SEPARATE TABLE, AND IT HAS TO BE (2026-07-30)
## -------------------------------------------------------------------
## The four lateral slots were doing a second job they cannot do: standing in for the TANGENT FRAME the wind
## kernel stores momentum in (`vel_x` along "the slot 1/2 axis", `vel_z` along "the slot 3/4 axis"). Coriolis
## rotates that pair, so it needs the frame to be consistently HANDED; the gather kernels need the slots to be
## slot-opposite RECIPROCAL. **Both cannot hold in one table, and that is topology, not a bug.** The pairing's
## two link families form closed cycles on the sphere; where two cycles cross, the handedness sign is the
## transverse intersection sign of two closed curves, and on a sphere every closed curve bounds, so that signed
## count is exactly 0. Measured at res 16/24/32: every crossing pair carries BOTH signs and every pair sums to
## zero. A 50/50 split is the FLOOR, not an accident (measured 1732 right / 1724 left at res 24). Worse than a
## sign flip: cycle ORIENTATION is the convention momentum is stored in, so adjacent cells on different cycles
## disagreed about which way "tangent A" points on 17.45/17.13/16.99% of links at res 16/24/32 — an INTERIOR
## defect growing as O(res²), where the pre-repair face-local axes could only disagree across a seam (O(res)).
##
## So the frame gets its own table and the pairing is left alone. `tan_a`/`tan_b` are built from the FACE-LOCAL
## geometric axes, which are right-handed on all six faces by construction (`cross(_FACE_R, _FACE_U)·_FACE_N`
## == +1 for every f) and merely DISCONTINUOUS at the seams — and Coriolis needs the handedness, not the
## continuity. `tan_b = radial × tan_a` makes (a, b, radial) right-handed at every cell unconditionally.
## Two derived tables carry the discontinuity so nothing else has to:
##   `link_tan` — per lateral slot, the unit direction TOWARD that neighbour written in THIS cell's own (a,b)
##       components. Kernels no longer assume "slot 2 == +tangent A": they dot with this. It is what makes the
##       upwind flux conservative to the face, because both ends of a link evaluate the SAME expression (a cell
##       reads its neighbour's direction back at itself from `link_tan[m*4 + (l^1)]`, and slot-opposite
##       reciprocity is exactly what guarantees that entry is the reverse of its own).
##   `link_rot` — per lateral slot, the (cos, sin) that PARALLEL-TRANSPORTS a vector's (a,b) components out of
##       this cell's frame and into the neighbour's. Anything that moves a VECTOR across a seam must apply it;
##       a SCALAR is unaffected. (Vorticity is the in-tree consumer: a curl differences neighbour VELOCITIES,
##       which are meaningless until they are expressed in one frame.)

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

# Cube-face bases: (normal, right=+a axis, up=+b axis). The seams are stitched by nearest-direction match, so
# any consistent per-face frame tiles the sphere correctly — but the frame is ALSO what `tan_a`/`tan_b` are
# seeded from, and there handedness matters: `cross(_FACE_R[f], _FACE_U[f]) · _FACE_N[f]` is +1 on all six
# faces, which is why the per-cell tangent basis below comes out uniformly right-handed. `validate()` reports
# it as `face_handed_min` rather than leaving it as a comment nobody re-checks.
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

var _back: PackedInt32Array = PackedInt32Array()           # surf_count*4 : partner's geometric slot pointing back
var lateral_slot: PackedInt32Array = PackedInt32Array()    # surf_count*4 : geometric slot -> lateral pair slot 0..3
var lateral_bends: int = 0       # links whose pair had to be bent away from the geometric axis (seam repair)

# TANGENT FRAME — its own table, independent of the lateral slots (see the header). Indexed by SURFACE cell:
# every radial layer of a column shares one frame, because the frame is a direction, not a position.
var tan_a: PackedVector3Array = PackedVector3Array()       # surf_count : unit tangent axis A (face +a, projected)
var tan_b: PackedVector3Array = PackedVector3Array()       # surf_count : unit tangent axis B = radial x tan_a
# surf_count*4*2, indexed (surf*4 + lateral_slot)*2 — LATERAL SLOT ORDER, i.e. kernel slots 1..4 are l = 0..3.
var link_tan: PackedFloat32Array = PackedFloat32Array()    # unit direction toward that neighbour, in MY (a,b)
var link_rot: PackedFloat32Array = PackedFloat32Array()    # (cos, sin) transporting MY (a,b) into the NEIGHBOUR's
# ANGULAR separation to each lateral neighbour, radians, one per surface cell per lateral slot. Multiply by a
# cell's RADIUS to get the arc distance between the two cell centres — the lateral RUN of that link.
#
# It exists because a slope is a rise over a RUN, and this grid's run is not its cell size. The radial
# thickness of a cell is exactly `cell_size`, but the lateral spacing is an arc that grows with radius and
# shrinks toward a face corner, so on the shipped grid the width/height aspect ranges 1.07 to 4.08. Any kernel
# comparing a height difference against a tangent — the angle of repose is the one that does — is asserting
# cells are cubes, and holds sediment at 33 degrees at the shell floor and 10 degrees at the top instead of
# the 35 the material actually stands at. Stored per SURFACE cell like the other two link tables, because the
# angle depends only on the two directions; the radius scaling is the kernel's one multiply.
var link_arc: PackedFloat32Array = PackedFloat32Array()    # radians between cell centres, per lateral slot

# SOLID ANGLE subtended by each surface column, steradians. One per SURFACE cell; every radial layer of a
# column shares it, because a solid angle is a set of directions and does not depend on radius.
#
# THIS GRID'S CELLS ARE NOT THE SAME SIZE. `link_arc` above already records the lateral half of that fact
# (aspect 1.07 to 4.08 on the shipped grid) and applies it to slope. The other half is VOLUME: a column near
# a face centre subtends more solid angle than one at a corner, and a cell high in the shell is wider than one
# at the floor because lateral spacing is an arc that grows with radius. So a sum of per-cell channel values
# is NOT an amount of anything, and a transport moving a fraction of one cell into a differently-sized one
# does not move the amount of matter it debited.
#
# Exact, not approximated: for the gnomonic map dir = normalize(N + R*a + U*b), the solid-angle element is
# da db / (1 + a^2 + b^2)^(3/2), whose antiderivative is atan(a*b / sqrt(1 + a^2 + b^2)). A cell is the 2D
# difference of that over its own [a0,a1] x [b0,b1]. `validate()` checks the sum is 4*pi.
var solid_angle: PackedFloat32Array = PackedFloat32Array()  # surf_count : steradians per column


## Local coord of surface cell (i,j) → cube point → unit sphere direction, for face `f`.
func _dir_at(f: int, a_local: float, b_local: float) -> Vector3:
	return (_FACE_N[f] + _FACE_R[f] * a_local + _FACE_U[f] * b_local).normalized()


## Antiderivative of the gnomonic solid-angle element: d/da d/db of this is 1/(1+a^2+b^2)^(3/2).
func _solid_angle_corner(a: float, b: float) -> float:
	return atan(a * b / sqrt(1.0 + a * a + b * b))


## Inner and outer radius of the shell a cell sits in. Centres are at +0.5 (see cell_world_pos), so layer r
## spans [core_radius + r*cell_size, core_radius + (r+1)*cell_size].
func cell_inner_radius(c: int) -> float:
	return core_radius + float(c % depth) * cell_size


func cell_outer_radius(c: int) -> float:
	return core_radius + float(c % depth + 1) * cell_size


## VOLUME of a cell, in model units cubed. Integrating r^2 dr over the shell gives (r_out^3 - r_in^3)/3, so
## this is exact rather than the mid-radius approximation. Use it to turn any per-cell channel value into an
## amount, and to size a transport between two cells that are not the same size.
func cell_volume(c: int) -> float:
	var ri: float = cell_inner_radius(c)
	var ro: float = cell_outer_radius(c)
	return solid_angle[c / depth] * (ro * ro * ro - ri * ri * ri) / 3.0


## Area of a cell's OUTWARD radial face, model units squared — the face a vertical flux crosses.
func face_area_outward(c: int) -> float:
	var ro: float = cell_outer_radius(c)
	return solid_angle[c / depth] * ro * ro


## Area of a cell's INWARD radial face. Smaller than the outward one by (r_in/r_out)^2, which is exactly why
## a purely radial transport that ignores area does not conserve.
func face_area_inward(c: int) -> float:
	var ri: float = cell_inner_radius(c)
	return solid_angle[c / depth] * ri * ri


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

	# 1) Surface directions (cell CENTRES) + the solid angle each column subtends (cell EDGES).
	_dir.resize(surf_count)
	solid_angle.resize(surf_count)
	for f in FACES:
		for i in res:
			var a: float = (float(i) + 0.5) / float(res) * 2.0 - 1.0
			var a0: float = float(i) / float(res) * 2.0 - 1.0
			var a1: float = float(i + 1) / float(res) * 2.0 - 1.0
			for j in res:
				var b: float = (float(j) + 0.5) / float(res) * 2.0 - 1.0
				var b0: float = float(j) / float(res) * 2.0 - 1.0
				var b1: float = float(j + 1) / float(res) * 2.0 - 1.0
				var s: int = _surf_idx(f, i, j)
				_dir[s] = _dir_at(f, a, b)
				solid_angle[s] = (_solid_angle_corner(a1, b1) - _solid_angle_corner(a0, b1)
					- _solid_angle_corner(a1, b0) + _solid_angle_corner(a0, b0))

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

	# 3) Turn that geometric adjacency into a SLOT-OPPOSITE-RECIPROCAL lateral pairing (see the header).
	_build_back_slots()
	_build_lateral_slots()

	# 3b) The TANGENT FRAME. A different question from the pairing, so a different table (see the header).
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


# ---------------------------------------------------------------------------------------------------------
# Reciprocal lateral pairing. Seeded from the geometry, repaired only where the geometry contradicts itself.
# ---------------------------------------------------------------------------------------------------------

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


## Stage 2 — general alternating-path repair, needed when the seam column has ODD length (odd `res`), where
## pairing cells off along the column always strands one. Walks an alternating path (remove an A link, add an
## A link, remove, …) from an unbalanced cell to another one: every cell in the MIDDLE of such a path loses and
## gains one A link, so only the two ENDS change, and both change toward balance.
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

## Per-cell orthonormal tangent frame. `tan_a` is the face's +a axis projected into the cell's tangent plane —
## on a cube face `|_FACE_R · dir|` never exceeds 1/sqrt(3), so the projection can never degenerate. `tan_b` is
## then `radial × tan_a`, which forces `tan_a × tan_b == radial` at EVERY cell: the frame is right-handed by
## construction, on all six faces, with no dependence on how the lateral links happened to be paired or walked.
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


## For every lateral link: the direction toward the neighbour in MY frame, and the rotation into ITS frame.
## Indexed by LATERAL SLOT (`lateral_slot`, i.e. kernel slots 1..4 as l = 0..3) so a kernel that has a slot in
## hand can read them without a second indirection. Both are functions of the two cells' directions only, so
## they are identical for every radial layer of a column and stored once per SURFACE cell.
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
## slot 0=inward/down, 1-4=lateral, 5=outward/up. (Internal table order is [IN,OUT,A0,A1,B0,B1].) The kernels'
## opposite pairs (0↔5, 1↔2, 3↔4) map exactly onto the internal `d ^ 1` pairs, so the reciprocity guaranteed by
## `validate().reciprocal` carries over to this packing unchanged.
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


## Self-validation of the seam table. Returns {ok, reciprocal, non_reciprocal, symmetric, closed, min_dot,
## max_dot, lateral_bends, errors}.
##
## reciprocal = SLOT-OPPOSITE reciprocity over the full cell table: `nbr[c*6+d] == m ⟹ nbr[m*6+(d^1)] == c`.
## This is the real contract — every 2-pass gather kernel credits its inflow from `send[m*6 + OPPOSITE(d)]`, so
## a link sitting in any other slot destroys mass at that seam (the send slot is written and never read) and
## duplicates it at another (read twice). Reciprocity implies BOTH of those counts are zero, because it makes
## `(c,d) ↦ (m,d^1)` an involution on the valid links: every written send slot has exactly one reader.
##
## symmetric = the weaker set-level property (A lists B ⟹ B lists A SOMEWHERE). It is kept because it isolates
## a genuine stitch failure from a mere slot-assignment failure, but on its own it proves nothing about mass —
## it was true, and reported ok, throughout the years this table was silently leaking at 1.4% of its links.
## closed = every surface neighbour index is in range. min/max_dot = alignment of adjacent cell directions
## (near 1.0 everywhere = a smooth, seam-free surface). `ok` requires ALL of closed, symmetric and reciprocal.
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
	# TANGENT FRAME (a separate table, and a separate contract — see the header). `handed_min` is the worst
	# `(tan_a × tan_b) · radial` over every cell: it must be +1, because Coriolis rotates that pair and a cell
	# where it is -1 deflects backwards. `face_handed_min` is the same test on the six raw face bases, checked
	# rather than asserted, since the per-cell frame inherits its sign from them.
	var handed_min: float = 2.0
	for s in surf_count:
		handed_min = minf(handed_min, tan_a[s].cross(tan_b[s]).dot(_dir[s]))
	var face_handed_min: float = 2.0
	for f in FACES:
		face_handed_min = minf(face_handed_min, _FACE_R[f].cross(_FACE_U[f]).dot(_FACE_N[f]))
	if handed_min < 0.999:
		errors += 1
	# GEOMETRY CLOSES OR IT DOES NOT. The solid angles of all six faces must sum to 4*pi; if they do not, the
	# closed form or the cell-edge coordinates are wrong and every volume built on them is wrong too.
	# `volume_ratio` is how many times bigger the largest cell is than the smallest — the size of the error
	# that treating cells as identical was making. It is reported, never corrected: the grid IS uneven.
	var omega_sum: float = 0.0
	for s in surf_count:
		omega_sum += solid_angle[s]
	var vol_min: float = INF
	var vol_max: float = 0.0
	for c in cell_count:
		var v: float = cell_volume(c)
		vol_min = minf(vol_min, v)
		vol_max = maxf(vol_max, v)
	var omega_err: float = absf(omega_sum - TAU * 2.0)
	if omega_err > 1.0e-4:
		errors += 1
	return {
		"ok": closed and symmetric and non_recip == 0 and errors == 0,
		"closed": closed, "symmetric": symmetric, "errors": errors,
		"reciprocal": non_recip == 0, "non_reciprocal": non_recip, "lateral_bends": lateral_bends,
		"surf_count": surf_count, "cell_count": cell_count,
		"min_adj_dot": min_dot, "max_adj_dot": max_dot,
		"tangent_handed_min": handed_min, "face_handed_min": face_handed_min,
		"solid_angle_sum": omega_sum, "solid_angle_err": omega_err,
		"volume_ratio": (vol_max / vol_min) if vol_min > 0.0 else 0.0,
	}
