class_name LAVoxelGrid
extends RefCounted

## A UNIFORM CARTESIAN GRID OF SPACE. Not a planet — space. A planet is wherever the matter ends up.
##
## THE POINT. The grid this replaces was a cubed-sphere shell, so the planet's SHAPE was an input: the
## coordinate system asserted a sphere and nothing could be any other shape. Here the cells are just
## boxes, and a body is round because its own gravity pulled it round. Spherical is an OUTPUT.
##
## WHAT THAT DELETES, all of it geometry the curvilinear grid needed and this one does not have:
##   solid angle per column · per-cell volume (every cell is cell_size^3) · the donor/receiver volume
##   ratio on every transfer · link arc length · the tangent basis and its parallel transport between
##   faces · the face seam table and the family orientation repair · the kernel-order slot permutation
##   and the reciprocal-slot lookup it needed.
##
## SLOTS are axis-aligned and ordered so the OPPOSITE OF d IS d ^ 1:
##   0 = -X, 1 = +X, 2 = -Y, 3 = +Y, 4 = -Z, 5 = +Z
## A neighbour outside the box is -1, exactly as a missing neighbour was before.
##
## THERE IS NO "DOWN" HERE. The old grid's slot 0 was inward, so gravity was a direction the indexing
## supplied for free. It does not exist on this grid and must not be reintroduced: down is
## -normalize(g) at each cell, and g comes from the mass distribution (LAFieldGravity).
##
## (Explicit types only, no ':=' inferred typing.)

const SLOTS: int = 6

const S_NEG_X: int = 0
const S_POS_X: int = 1
const S_NEG_Y: int = 2
const S_POS_Y: int = 3
const S_NEG_Z: int = 4
const S_POS_Z: int = 5

## Slot -> unit step in cell indices. Order matches the constants above, so `d ^ 1` is the reverse.
const SLOT_STEP: Array[Vector3i] = [
	Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
	Vector3i(0, -1, 0), Vector3i(0, 1, 0),
	Vector3i(0, 0, -1), Vector3i(0, 0, 1),
]

var nx: int = 0
var ny: int = 0
var nz: int = 0
var cell_size: float = 0.0                 # model units; the same along every axis
var origin: Vector3 = Vector3.ZERO         # world position of the minimum corner of cell (0,0,0)
var cell_count: int = 0

## cell_count * 6 flat neighbour table, slot order above. -1 = outside the box.
var neighbours: PackedInt32Array = PackedInt32Array()


## The slot a neighbour at slot `d` used to point back here. Axis-aligned, so it is the bit flip and
## needs no table. The cubed-sphere grid needed a permutation here and got it wrong for four slots.
static func opposite_slot(d: int) -> int:
	return d ^ 1


func index(x: int, y: int, z: int) -> int:
	return x + nx * (y + ny * z)


func coords(c: int) -> Vector3i:
	var x: int = c % nx
	var y: int = (c / nx) % ny
	var z: int = c / (nx * ny)
	return Vector3i(x, y, z)


func in_bounds(x: int, y: int, z: int) -> bool:
	return x >= 0 and x < nx and y >= 0 and y < ny and z >= 0 and z < nz


## Centre of cell `c` in world coordinates.
func cell_world_pos(c: int) -> Vector3:
	var v: Vector3i = coords(c)
	return origin + (Vector3(v) + Vector3(0.5, 0.5, 0.5)) * cell_size


## The cell containing a world point, or -1 outside the box.
func cell_at(p: Vector3) -> int:
	var local: Vector3 = (p - origin) / cell_size
	var x: int = int(floor(local.x))
	var y: int = int(floor(local.y))
	var z: int = int(floor(local.z))
	if not in_bounds(x, y, z):
		return -1
	return index(x, y, z)


## Volume in model units cubed. Constant — the argument exists so callers read the same shape as before
## and so a future non-uniform grid has a seam, not because it varies.
func cell_volume(_c: int = 0) -> float:
	return cell_size * cell_size * cell_size


## Area of one face, model units squared. Every face of every cell is the same.
func face_area(_c: int = 0, _d: int = 0) -> float:
	return cell_size * cell_size


func build(p_nx: int, p_ny: int, p_nz: int, p_cell_size: float, p_origin: Vector3) -> void:
	nx = maxi(p_nx, 1)
	ny = maxi(p_ny, 1)
	nz = maxi(p_nz, 1)
	cell_size = maxf(p_cell_size, 1.0e-6)
	origin = p_origin
	cell_count = nx * ny * nz
	_build_neighbours()


## Build a box centred on `center` that contains a sphere of `radius`, at `p_cell_size` resolution.
## The commonest construction while one body is being simulated; it asserts nothing about what fills it.
func build_centred(center: Vector3, radius: float, p_cell_size: float) -> void:
	var n: int = maxi(int(ceil(2.0 * radius / maxf(p_cell_size, 1.0e-6))), 1)
	var half: float = 0.5 * float(n) * p_cell_size
	build(n, n, n, p_cell_size, center - Vector3(half, half, half))


## Build over a VoxelLodTerrain's own `voxel_bounds`, snapped so a field cell is a whole number of voxels
## and the origin lands on a voxel-block boundary.
##
## WHY THIS MATTERS. godot_voxel's terrain is already a uniform Cartesian voxel field. The grid this
## replaces was a cubed-sphere shell, so the two were different coordinate systems describing one planet:
## the solid mask was built by calling `is_solid(world_pos)` per cell, an interpolated SDF sample through
## the script boundary, once for every cell in the field. Aligned, a field cell maps to a whole voxel
## block by integer arithmetic, so occupancy is a block read and a carve and the field's view of that
## carve are the same coordinates rather than two.
func build_over_voxel_bounds(bounds: AABB, p_cell_size: float, voxel_size: float = 1.0) -> void:
	var cs: float = maxf(round(p_cell_size / maxf(voxel_size, 1.0e-6)), 1.0) * voxel_size
	var lo: Vector3 = Vector3(
		floor(bounds.position.x / cs) * cs,
		floor(bounds.position.y / cs) * cs,
		floor(bounds.position.z / cs) * cs)
	var hi: Vector3 = bounds.position + bounds.size
	build(
		maxi(int(ceil((hi.x - lo.x) / cs)), 1),
		maxi(int(ceil((hi.y - lo.y) / cs)), 1),
		maxi(int(ceil((hi.z - lo.z) / cs)), 1),
		cs, lo)


## Voxels per cell along one axis, for the block-aligned terrain read. Integer by construction of
## build_over_voxel_bounds; anything else means the grid was built unaligned.
func voxels_per_cell(voxel_size: float = 1.0) -> int:
	return int(round(cell_size / maxf(voxel_size, 1.0e-6)))


## Is the grid aligned to `voxel_size`, so cell <-> voxel is integer arithmetic with no resampling?
func is_voxel_aligned(voxel_size: float = 1.0) -> bool:
	var vs: float = maxf(voxel_size, 1.0e-6)
	var n: float = cell_size / vs
	if absf(n - round(n)) > 1.0e-6:
		return false
	for a in [origin.x, origin.y, origin.z]:
		var k: float = float(a) / cell_size
		if absf(k - round(k)) > 1.0e-6:
			return false
	return true


func _build_neighbours() -> void:
	neighbours.resize(cell_count * SLOTS)
	for z in nz:
		for y in ny:
			for x in nx:
				var c: int = index(x, y, z)
				var base: int = c * SLOTS
				for d in SLOTS:
					var s: Vector3i = SLOT_STEP[d]
					var ax: int = x + s.x
					var ay: int = y + s.y
					var az: int = z + s.z
					neighbours[base + d] = index(ax, ay, az) if in_bounds(ax, ay, az) else -1


## The neighbour table as the kernels consume it. There is no permutation: the build order IS the
## kernel order. The method is kept so call sites read the same and so the absence is explicit.
func neighbours_kernel_order() -> PackedInt32Array:
	return neighbours


## Structural self-check. Every claim here is one the cubed-sphere grid had to work to earn.
func validate() -> Dictionary:
	var reciprocal: int = 0
	var non_reciprocal: int = 0
	var boundary: int = 0
	for c in cell_count:
		var base: int = c * SLOTS
		for d in SLOTS:
			var m: int = neighbours[base + d]
			if m < 0:
				boundary += 1
				continue
			if neighbours[m * SLOTS + opposite_slot(d)] == c:
				reciprocal += 1
			else:
				non_reciprocal += 1
	var vol: float = cell_volume()
	return {
		"ok": non_reciprocal == 0 and cell_count == nx * ny * nz,
		"cells": cell_count,
		"reciprocal": reciprocal,
		"non_reciprocal": non_reciprocal,
		"boundary_faces": boundary,
		"cell_volume": vol,
		"volume_ratio": 1.0,
		"total_volume": vol * float(cell_count),
	}
