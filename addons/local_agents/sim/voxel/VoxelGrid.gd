class_name LAVoxelGrid
extends RefCounted

## A CARTESIAN GRID OF SPACE WITH AXIS-ALIGNED REFINEMENT. Not a planet — space. A planet is wherever
## the matter ends up. A cell at level L has edge `cell_size / 2^L`; a coarse cell faces four fine ones.

## Face tags, not quantities. Ordered so the opposite of d is d ^ 1.
enum { S_NEG_X, S_POS_X, S_NEG_Y, S_POS_Y, S_NEG_Z, S_POS_Z }

const SLOTS: int = S_POS_Z + 1

## Levels the refinement carries. 2:1 between neighbours, so a face joins levels L and L+1 at most.
const MAX_LEVEL: int = 1

## Slot -> unit step in cell indices. Order matches the constants above, so `d ^ 1` is the reverse.
const SLOT_STEP: Array[Vector3i] = [
	Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
	Vector3i(0, -1, 0), Vector3i(0, 1, 0),
	Vector3i(0, 0, -1), Vector3i(0, 0, 1),
]

## Octant -> its corner in half-edges of the parent.
const OCT_STEP: Array[Vector3i] = [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0),
	Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(0, 1, 1), Vector3i(1, 1, 1),
]

var nx: int = 0
var ny: int = 0
var nz: int = 0
## Edge of a LEVEL 0 cell, metres; the coarsest the box carries.
var cell_size: float = 0.0
var origin: Vector3 = Vector3.ZERO         # world position of the minimum corner of base cell (0,0,0)
var cell_count: int = 0                    # leaves; a refined base cell is not one of them

## Refinement level per cell, over interior plus ghost tail.
var levels: PackedByteArray = PackedByteArray()

## Per cell: the base lattice cell it lies in, and which octant of it.
var _cell_base: PackedInt32Array = PackedInt32Array()
var _cell_oct: PackedByteArray = PackedByteArray()
## Per base cell: its leaf, or the first of its eight children; and whether it was split.
var _base_head: PackedInt32Array = PackedInt32Array()
var _base_split: PackedByteArray = PackedByteArray()

## Absolute face index where cell c's slot-d faces begin, 7 per cell; [c * 7 + 6] ends the cell.
var slot_off: PackedInt32Array = PackedInt32Array()
## Per FACE: the cell across it, -1 = outside the box.
var neighbours: PackedInt32Array = PackedInt32Array()
## Per FACE: the face pointing back, -1 = outside. A coarse cell's four subfaces each name their own.
var partners: PackedInt32Array = PackedInt32Array()

## Ghost rows appended past cell_count by a boundary provider; 0 = every wall shut.
var ghost_rows: int = 0


## The slot at which the neighbour at slot `d` points back here. Axis-aligned, so it is the bit flip.
## The FACE pointing back is `partners[f]`, which a 2:1 seam makes a different question.
static func opposite_slot(d: int) -> int:
	return d ^ 1


## Base cells per axis for a box holding a sphere of `radius` at `p_cell_size`.
static func dims_for(radius: float, p_cell_size: float) -> Vector3i:
	var n: int = maxi(int(ceil(2.0 * radius / maxf(p_cell_size, 1.0e-6))), 1)
	return Vector3i(n, n, n)


func index(x: int, y: int, z: int) -> int:
	return x + nx * (y + ny * z)


## Base lattice coordinates of cell `c`; the eight children of a split cell share them.
func coords(c: int) -> Vector3i:
	var b: int = _cell_base[c] if c >= 0 and c < _cell_base.size() else c
	var x: int = b % nx
	var y: int = (b / nx) % ny
	var z: int = b / (nx * ny)
	return Vector3i(x, y, z)


func in_bounds(x: int, y: int, z: int) -> bool:
	return x >= 0 and x < nx and y >= 0 and y < ny and z >= 0 and z < nz


## Refinement level of cell `c`; 0 is the coarsest.
func level_of(c: int) -> int:
	return int(levels[c]) if c >= 0 and c < levels.size() else 0


## Edge of cell `c`, metres.
func cell_edge(c: int) -> float:
	return cell_size * pow(0.5, float(level_of(c)))


func cell_volume(c: int = 0) -> float:
	var e: float = cell_edge(c)
	return e * e * e


## Centre of cell `c` in world coordinates.
func cell_world_pos(c: int) -> Vector3:
	var v: Vector3i = coords(c)
	var base: Vector3 = origin + (Vector3(v) + Vector3(0.5, 0.5, 0.5)) * cell_size
	if level_of(c) == 0:
		return base
	var o: Vector3 = Vector3(OCT_STEP[int(_cell_oct[c])])
	return base + (o - Vector3(0.5, 0.5, 0.5)) * 0.5 * cell_size


## The leaf containing a world point, or -1 outside the box.
func cell_at(p: Vector3) -> int:
	var local: Vector3 = (p - origin) / cell_size
	var x: int = int(floor(local.x))
	var y: int = int(floor(local.y))
	var z: int = int(floor(local.z))
	if not in_bounds(x, y, z):
		return -1
	var b: int = index(x, y, z)
	if _base_split[b] == 0:
		return _base_head[b]
	var f: Vector3 = local - Vector3(float(x), float(y), float(z))
	var o: int = (1 if f.x >= 0.5 else 0) | (2 if f.y >= 0.5 else 0) | (4 if f.z >= 0.5 else 0)
	return _base_head[b] + o


## The leaf of base lattice cell (x, y, z); the first of its eight children where it was split.
func leaf_at(x: int, y: int, z: int) -> int:
	return _base_head[index(x, y, z)]


## True where base lattice cell (x, y, z) was split into eight.
func split_at(x: int, y: int, z: int) -> bool:
	return _base_split[index(x, y, z)] != 0


## The leaf across the box on the axis slot `d` runs along: the torus partner of `c`. A box-edge cell is
## never refined, so this is one cell and not four.
func wrap_partner(c: int, d: int) -> int:
	var axis: int = d >> 1
	var dims: PackedInt32Array = PackedInt32Array([nx, ny, nz])
	var v: Vector3i = coords(c)
	var p: PackedInt32Array = PackedInt32Array([v.x, v.y, v.z])
	p[axis] = dims[axis] - 1 if (d & 1) == 0 else 0
	return leaf_at(p[0], p[1], p[2])


## Centre of the box in world coordinates.
func center() -> Vector3:
	return origin + Vector3(float(nx), float(ny), float(nz)) * cell_size * 0.5


## Every cell's volume, m^3.
func cell_volumes() -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(cell_count + ghost_rows)
	for c in out.size():
		out[c] = cell_volume(c)
	return out


## Every cell's edge, m.
func cell_edges() -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(cell_count + ghost_rows)
	for c in out.size():
		out[c] = cell_edge(c)
	return out


## Longest march a column can take before it leaves the box, in the FINEST cells it may cross.
func max_span() -> int:
	return maxi(maxi(nx, ny), nz) << MAX_LEVEL


## First and last-plus-one face of cell `c`.
func face_begin(c: int) -> int:
	return slot_off[c * 7]


func face_end(c: int) -> int:
	return slot_off[c * 7 + 6]


## First and last-plus-one face of cell `c` on slot `d`. Four where a coarse cell meets fine ones.
func slot_begin(c: int, d: int) -> int:
	return slot_off[c * 7 + d]


func slot_end(c: int, d: int) -> int:
	return slot_off[c * 7 + d + 1]


## Shared area of face `f` owned by cell `c`, m^2: the finer of the pair states it.
func face_area(c: int, f: int) -> float:
	var e: float = cell_edge(c)
	var m: int = neighbours[f]
	if m >= 0:
		e = minf(e, cell_edge(m))
	return e * e


## Centre-to-centre distance across face `f` owned by cell `c`, m; a box edge has half a cell beyond it.
func face_distance(c: int, f: int) -> float:
	var e: float = cell_edge(c)
	var m: int = neighbours[f]
	return 0.5 * (e + cell_edge(m)) if m >= 0 else e


func build(p_nx: int, p_ny: int, p_nz: int, p_cell_size: float, p_origin: Vector3) -> void:
	nx = maxi(p_nx, 1)
	ny = maxi(p_ny, 1)
	nz = maxi(p_nz, 1)
	cell_size = maxf(p_cell_size, 1.0e-6)
	origin = p_origin
	_split(PackedByteArray())


## Build a box centred on `centre` that contains a sphere of `radius`, at `p_cell_size` resolution.
func build_centred(centre: Vector3, radius: float, p_cell_size: float) -> void:
	var d: Vector3i = dims_for(radius, p_cell_size)
	var half: float = 0.5 * float(d.x) * p_cell_size
	build(d.x, d.y, d.z, p_cell_size, centre - Vector3(half, half, half))


## Split the base cells `mask` marks into eight, and rebuild the face list. The mask is the whole
## statement of where the grid is fine, so refining twice with the same mask is one grid.
func refine(mask: PackedByteArray) -> void:
	_split(mask)


func _split(mask: PackedByteArray) -> void:
	var base_count: int = nx * ny * nz
	_base_head = PackedInt32Array()
	_base_head.resize(base_count)
	_base_split = PackedByteArray()
	_base_split.resize(base_count)
	var use: bool = mask.size() == base_count
	var n: int = 0
	for b in base_count:
		var split: bool = use and mask[b] != 0
		_base_split[b] = 1 if split else 0
		_base_head[b] = n
		n += 8 if split else 1
	cell_count = n
	_cell_base = PackedInt32Array()
	_cell_base.resize(n)
	_cell_oct = PackedByteArray()
	_cell_oct.resize(n)
	levels = PackedByteArray()
	levels.resize(n)
	for b in base_count:
		var head: int = _base_head[b]
		if _base_split[b] == 0:
			_cell_base[head] = b
			_cell_oct[head] = 0
			levels[head] = 0
			continue
		for o in 8:
			_cell_base[head + o] = b
			_cell_oct[head + o] = o
			levels[head + o] = 1
	ghost_rows = 0
	_build_faces()


## The leaf of base cell `b` on octant `o`; the base cell's own leaf when it was not split.
func _leaf(b: int, o: int) -> int:
	return _base_head[b] + (o if _base_split[b] != 0 else 0)


func _base_step(b: int, d: int) -> int:
	var v: Vector3i = Vector3i(b % nx, (b / nx) % ny, b / (nx * ny)) + SLOT_STEP[d]
	return index(v.x, v.y, v.z) if in_bounds(v.x, v.y, v.z) else -1


## The four octants of a base cell that touch its slot-`d` face.
func _face_octants(d: int) -> PackedByteArray:
	var axis: int = d >> 1
	var bit: int = 1 if (d & 1) == 1 else 0
	var out: PackedByteArray = PackedByteArray()
	for o in 8:
		if ((o >> axis) & 1) == bit:
			out.append(o)
	return out


func _build_faces() -> void:
	slot_off = PackedInt32Array()
	slot_off.resize(cell_count * 7)
	neighbours = PackedInt32Array()
	partners = PackedInt32Array()
	var at: int = 0
	for c in cell_count:
		var b: int = _cell_base[c]
		var lv: int = int(levels[c])
		var o: int = int(_cell_oct[c])
		for d in SLOTS:
			slot_off[c * 7 + d] = at
			var axis: int = d >> 1
			var toward_hi: bool = (d & 1) == 1
			if lv == 0:
				var b2: int = _base_step(b, d)
				if b2 < 0:
					neighbours.append(-1)
					at += 1
				elif _base_split[b2] == 0:
					neighbours.append(_base_head[b2])
					at += 1
				else:
					for oc in _face_octants(opposite_slot(d)):
						neighbours.append(_base_head[b2] + int(oc))
						at += 1
			else:
				var bit: int = (o >> axis) & 1
				if (toward_hi and bit == 0) or (not toward_hi and bit == 1):
					neighbours.append(_base_head[b] + (o ^ (1 << axis)))
				else:
					var b3: int = _base_step(b, d)
					neighbours.append(-1 if b3 < 0 else _leaf(b3, o ^ (1 << axis)))
				at += 1
		slot_off[c * 7 + 6] = at
	partners.resize(neighbours.size())
	for f in partners.size():
		partners[f] = -1
	_pair_faces()


func _pair_faces() -> void:
	for c in cell_count:
		for d in SLOTS:
			var back: int = opposite_slot(d)
			for f in range(slot_begin(c, d), slot_end(c, d)):
				var m: int = neighbours[f]
				if m < 0:
					continue
				for g in range(slot_begin(m, back), slot_end(m, back)):
					if neighbours[g] == c:
						partners[f] = g
						break


## Append `n` ghost rows: boundary-provider cells past cell_count, six shut faces each until a provider
## attaches one. The face list stays the one declaration of adjacency.
func add_ghost_rows(n: int) -> void:
	var add: int = maxi(n, 0)
	if add == 0:
		return
	var first: int = cell_count + ghost_rows
	ghost_rows += add
	var total: int = cell_count + ghost_rows
	levels.resize(total)
	slot_off.resize(total * 7)
	var at: int = neighbours.size()
	for c in range(first, total):
		levels[c] = 0
		for d in SLOTS:
			slot_off[c * 7 + d] = at + d
		slot_off[c * 7 + 6] = at + SLOTS
		at += SLOTS
	var was: int = neighbours.size()
	neighbours.resize(at)
	partners.resize(at)
	for f in range(was, at):
		neighbours[f] = -1
		partners[f] = -1


## Point ghost cell `gh` back at interior cell `c` across slot `d` of `c`, and take `c`'s level: a
## prescribed exterior state is the same size as the cell it feeds.
func attach_ghost(gh: int, c: int, d: int) -> void:
	levels[gh] = levels[c]
	var back: int = slot_begin(gh, opposite_slot(d))
	neighbours[back] = c
	partners[back] = slot_begin(c, d)
	for f in range(slot_begin(c, d), slot_end(c, d)):
		partners[f] = back


## Structural self-check. Every claim here is one a graded grid has to earn.
func validate() -> Dictionary:
	var reciprocal: int = 0
	var non_reciprocal: int = 0
	var boundary: int = 0
	var ratio_bad: int = 0
	var area_bad: int = 0
	var ratio_max: float = 1.0
	for c in cell_count:
		for d in SLOTS:
			var area: float = 0.0
			for f in range(slot_begin(c, d), slot_end(c, d)):
				var m: int = neighbours[f]
				if m < 0:
					boundary += 1
					area += face_area(c, f)
					continue
				var g: int = partners[f]
				if g >= 0 and neighbours[g] == c:
					reciprocal += 1
				else:
					non_reciprocal += 1
				# 2:1 refinement: a pair's volumes are equal or differ by exactly eight.
				var r: float = cell_volume(c) / cell_volume(m)
				if absf(r - 1.0) > 1.0e-6 and absf(r - 8.0) > 1.0e-6 and absf(r - 0.125) > 1.0e-6:
					ratio_bad += 1
				ratio_max = maxf(ratio_max, maxf(r, 1.0 / r))
				area += face_area(c, f)
			# The four subfaces of a coarse face tile it exactly; a same-level face is the whole face.
			var whole: float = cell_edge(c) * cell_edge(c)
			if absf(area - whole) > 1.0e-6 * whole:
				area_bad += 1
	return {
		"ok": non_reciprocal == 0 and ratio_bad == 0 and area_bad == 0,
		"cells": cell_count,
		"reciprocal": reciprocal,
		"non_reciprocal": non_reciprocal,
		"boundary_faces": boundary,
		"ratio_violations": ratio_bad,
		"area_violations": area_bad,
		"cell_volume": cell_volume(0),
		"volume_ratio": ratio_max,
		"faces": neighbours.size(),
	}
