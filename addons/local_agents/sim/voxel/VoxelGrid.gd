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

var nx: int = 0
var ny: int = 0
var nz: int = 0
## Edge of a LEVEL 0 cell, metres; the coarsest the box carries.
var cell_size: float = 0.0
var origin: Vector3 = Vector3.ZERO         # world position of the minimum corner of base cell (0,0,0)
var cell_count: int = 0                    # leaves; a refined base cell is not one of them

## Refinement level per cell, over interior plus ghost tail.
var levels: PackedByteArray = PackedByteArray()

## Per cell: the base lattice cell it lies in, which octant of it, and its centre in world coordinates.
var cell_base: PackedInt32Array = PackedInt32Array()
var cell_oct: PackedByteArray = PackedByteArray()
var centres: PackedVector3Array = PackedVector3Array()
## Per base cell: its leaf, or the first of its eight children; and whether it was split.
var base_head: PackedInt32Array = PackedInt32Array()
var base_split: PackedByteArray = PackedByteArray()

## Absolute face index where cell c's slot-d faces begin, 7 per cell; [c * 7 + 6] ends the cell.
var slot_off: PackedInt32Array = PackedInt32Array()
## Per FACE: the cell across it, -1 = outside the box.
var neighbours: PackedInt32Array = PackedInt32Array()
## Per FACE: the face pointing back, -1 = outside. A coarse cell's four subfaces each name their own.
var partners: PackedInt32Array = PackedInt32Array()

## Ghost rows appended past cell_count by a boundary provider; 0 = every wall shut.
var ghost_rows: int = 0
## The finest level any cell is at; 0 on a uniform box.
var max_level: int = 0


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
	var b: int = cell_base[c] if c >= 0 and c < cell_base.size() else c
	return Vector3i(b % nx, (b / nx) % ny, b / (nx * ny))


func in_bounds(x: int, y: int, z: int) -> bool:
	return x >= 0 and x < nx and y >= 0 and y < ny and z >= 0 and z < nz


## Refinement level of cell `c`; 0 is the coarsest.
func level_of(c: int) -> int:
	return int(levels[c]) if c >= 0 and c < levels.size() else 0


## Edge of the FINEST cell the grid actually holds, metres — not the finest MAX_LEVEL would allow.
## Every bound that is a property of the smallest cell reads this, so a uniform box states its own edge.
func min_cell_size() -> float:
	return cell_size * pow(0.5, float(max_level))


## Edge of cell `c`, metres.
func cell_edge(c: int) -> float:
	return cell_size * pow(0.5, float(level_of(c)))


func cell_volume(c: int = 0) -> float:
	var e: float = cell_edge(c)
	return e * e * e


## Centre of cell `c` in world coordinates.
func cell_world_pos(c: int) -> Vector3:
	return centres[c]


## The leaf containing a world point, or -1 outside the box.
func cell_at(p: Vector3) -> int:
	var local: Vector3 = (p - origin) / cell_size
	var x: int = int(floor(local.x))
	var y: int = int(floor(local.y))
	var z: int = int(floor(local.z))
	if not in_bounds(x, y, z):
		return -1
	var b: int = index(x, y, z)
	if base_split[b] == 0:
		return base_head[b]
	var f: Vector3 = local - Vector3(float(x), float(y), float(z))
	return base_head[b] + ((1 if f.x >= 0.5 else 0) | (2 if f.y >= 0.5 else 0)
		| (4 if f.z >= 0.5 else 0))


## The leaf of base lattice cell (x, y, z); the first of its eight children where it was split.
func leaf_at(x: int, y: int, z: int) -> int:
	return base_head[index(x, y, z)]


## The leaf across the box on the axis slot `d` runs along: the torus partner of `c`. A box-edge cell is
## never refined, so this is one cell and not four.
func wrap_partner(c: int, d: int) -> int:
	var axis: int = d >> 1
	var dims: PackedInt32Array = PackedInt32Array([nx, ny, nz])
	var v: Vector3i = coords(c)
	var p: PackedInt32Array = PackedInt32Array([v.x, v.y, v.z])
	p[axis] = dims[axis] - 1 if (d & 1) == 0 else 0
	return leaf_at(p[0], p[1], p[2])


## Every cell's volume, m^3, and every cell's edge, m.
func cell_volumes() -> PackedFloat32Array:
	return LAGridGeometry.volumes(self)


func cell_edges() -> PackedFloat32Array:
	return LAGridGeometry.edges(self)


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
	refine(PackedByteArray())


## Build a box centred on `centre` that contains a sphere of `radius`, at `p_cell_size` resolution.
func build_centred(centre: Vector3, radius: float, p_cell_size: float) -> void:
	var d: Vector3i = dims_for(radius, p_cell_size)
	var half: float = 0.5 * float(d.x) * p_cell_size
	build(d.x, d.y, d.z, p_cell_size, centre - Vector3(half, half, half))


## Split the base cells `mask` marks into eight, and rebuild the face list. The mask is the whole
## statement of where the grid is fine, so refining twice with the same mask is one grid.
func refine(mask: PackedByteArray) -> void:
	var g: Dictionary = LAGridGeometry.build(Vector3i(nx, ny, nz), mask)
	cell_count = int(g["cell_count"])
	levels = g["levels"]
	max_level = 0
	for c in levels.size():
		max_level = maxi(max_level, int(levels[c]))
	cell_base = g["cell_base"]
	cell_oct = g["cell_oct"]
	base_head = g["base_head"]
	base_split = g["base_split"]
	slot_off = g["slot_off"]
	neighbours = g["neighbours"]
	partners = g["partners"]
	ghost_rows = 0
	centres = LAGridGeometry.centres(self)


## Append `n` ghost rows: boundary-provider cells past cell_count, six shut faces each until a provider
## attaches one. The face list stays the one declaration of adjacency.
func add_ghost_rows(n: int) -> void:
	var g: Dictionary = LAGridGeometry.ghost_rows(self, n)
	if g.is_empty():
		return
	ghost_rows += n
	levels = g["levels"]
	slot_off = g["slot_off"]
	neighbours = g["neighbours"]
	partners = g["partners"]
	centres = LAGridGeometry.centres(self)


## Point ghost cell `gh` back at interior cell `c` across slot `d` of `c`, and take `c`'s level: a
## prescribed exterior state is the same size as the cell it feeds.
func attach_ghost(gh: int, c: int, d: int) -> void:
	levels[gh] = levels[c]
	var back: int = slot_begin(gh, opposite_slot(d))
	neighbours[back] = c
	partners[back] = slot_begin(c, d)
	for f in range(slot_begin(c, d), slot_end(c, d)):
		partners[f] = back


## Structural self-check: reciprocity, the 2:1 volume ratio, and the tiling of a coarse face.
func validate() -> Dictionary:
	return LAGridGeometry.validate(self)
