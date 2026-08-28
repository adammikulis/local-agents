class_name LAVoxelGrid
extends RefCounted

## A CARTESIAN GRID OF SPACE WITH AXIS-ALIGNED REFINEMENT. Not a planet — space. A planet is wherever
## the matter ends up. A cell at level L has edge `cell_size / 2^L`; a coarse cell faces four fine ones.

## Face tags, not quantities. Ordered so the opposite of d is d ^ 1.
enum { S_NEG_X, S_POS_X, S_NEG_Y, S_POS_Y, S_NEG_Z, S_POS_Z }

const SLOTS: int = S_POS_Z + 1

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

## Per cell: base lattice cell, lattice coordinates at its level (3 ints), full-depth Morton code, centre.
var cell_base: PackedInt32Array = PackedInt32Array()
var cell_local: PackedInt32Array = PackedInt32Array()
var cell_morton: PackedInt32Array = PackedInt32Array()
var centres: PackedVector3Array = PackedVector3Array()
## Per base cell: first leaf, and leaf count.
var base_head: PackedInt32Array = PackedInt32Array()
var base_leaves: PackedInt32Array = PackedInt32Array()

## Absolute face index where cell c's slot-d faces begin, 7 per cell; [c * 7 + 6] ends the cell.
var slot_off: PackedInt32Array = PackedInt32Array()
## Per FACE: the cell across it, -1 = outside the box.
var neighbours: PackedInt32Array = PackedInt32Array()
## Per FACE: the face pointing back, -1 = outside. A coarse cell's four subfaces each name their own.
var partners: PackedInt32Array = PackedInt32Array()

## Ghost rows appended past cell_count by a boundary provider; 0 = every wall shut.
var ghost_rows: int = 0
## The finest level any cell is at; 0 on a uniform box, and the edge the refinement reached, m.
var max_level: int = 0
var target_edge_m: float = 0.0


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


## Refinement level of cell `c`; 0 is the coarsest.
func level_of(c: int) -> int:
	return int(levels[c]) if c >= 0 and c < levels.size() else 0


## Edge of cell `c`, metres.
func cell_edge(c: int) -> float:
	return cell_size * pow(0.5, float(level_of(c)))


func cell_volume(c: int = 0) -> float:
	return pow(cell_edge(c), 3.0)


## Centre of cell `c` in world coordinates.
func cell_world_pos(c: int) -> Vector3:
	return centres[c]


## The leaf containing a world point, or -1 outside the box.
func cell_at(p: Vector3) -> int:
	return LAGridGeometry.cell_at(self, p)


func leaf_at(x: int, y: int, z: int) -> int:
	return base_head[index(x, y, z)]


func wrap_partner(c: int, d: int) -> int:
	return LAGridGeometry.wrap_partner(self, c, d)


## Every cell's volume, m^3, and every cell's edge, m.
func cell_volumes() -> PackedFloat32Array:
	return LAGridGeometry.volumes(self)


func cell_edges() -> PackedFloat32Array:
	return LAGridGeometry.edges(self)


## Longest march a column can take before it leaves the box, in the FINEST cells it may cross.
func max_span() -> int:
	return maxi(maxi(nx, ny), nz) << max_level


## First face of cell `c` on slot `d`; `d` == SLOTS ends the cell. Four faces on a slot where a coarse
## cell meets fine ones, and the whole cell's range is slot 0 to SLOTS.
func slot_begin(c: int, d: int) -> int:
	return slot_off[c * 7 + d]


func build(p_nx: int, p_ny: int, p_nz: int, p_cell_size: float, p_origin: Vector3) -> void:
	nx = maxi(p_nx, 1)
	ny = maxi(p_ny, 1)
	nz = maxi(p_nz, 1)
	cell_size = maxf(p_cell_size, 1.0e-6)
	origin = p_origin
	refine(PackedByteArray())


func refine(mask: PackedByteArray) -> void:
	adopt_geometry(LAGridGeometry.build(Vector3i(nx, ny, nz), mask))


## Take a geometry LAGridGeometry built (or a cached one) as this grid's own.
func adopt_geometry(g: Dictionary) -> void:
	cell_count = int(g["cell_count"])
	levels = g["levels"]
	max_level = int(g["max_level"])
	target_edge_m = float(g.get("target_edge_m", cell_size))
	cell_base = g["cell_base"]
	cell_local = g["cell_local"]
	cell_morton = g["cell_morton"]
	base_head = g["base_head"]
	base_leaves = g["base_leaves"]
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
	for f in range(slot_begin(c, d), slot_begin(c, d + 1)):
		partners[f] = back


## Structural self-check: reciprocity, the 2:1 volume ratio, and the tiling of a coarse face.
func validate() -> Dictionary:
	return LAGridGeometry.validate(self)
