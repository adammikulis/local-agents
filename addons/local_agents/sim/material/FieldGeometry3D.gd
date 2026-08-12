class_name LAFieldGeometry
extends RefCounted

## DIRECTION ON A UNIFORM CARTESIAN GRID. A neighbour slot is an axis tag, so which neighbour is BELOW a
## cell is read from the solved gravity there and never from a slot number.

## The slot whose unit step points most nearly along `dir`; -1 when `dir` is zero.
static func slot_toward(dir: Vector3) -> int:
	var ax: float = absf(dir.x)
	var ay: float = absf(dir.y)
	var az: float = absf(dir.z)
	if ax <= 0.0 and ay <= 0.0 and az <= 0.0:
		return -1
	if ax >= ay and ax >= az:
		return LAVoxelGrid.S_NEG_X if dir.x < 0.0 else LAVoxelGrid.S_POS_X
	if ay >= az:
		return LAVoxelGrid.S_NEG_Y if dir.y < 0.0 else LAVoxelGrid.S_POS_Y
	return LAVoxelGrid.S_NEG_Z if dir.z < 0.0 else LAVoxelGrid.S_POS_Z


## Unit vector gravity pulls along at `c`. ZERO where no mass has been solved for, which is the honest
## answer: nothing has measured a direction there.
static func down(field, c: int) -> Vector3:
	if field == null or field._gravity == null:
		return Vector3.ZERO
	return field._gravity.down_at(c)


## The local vertical, pointing away from the mass — what the cubed sphere called `cell_radial`.
static func up(field, c: int) -> Vector3:
	return -down(field, c)


## Neighbour one step along gravity from `c`; -1 outside the box or where gravity vanishes.
static func below(field, c: int) -> int:
	return step_along(field, c, down(field, c))


## Neighbour one step against gravity from `c`; -1 outside the box or where gravity vanishes.
static func above(field, c: int) -> int:
	return step_along(field, c, up(field, c))


static func step_along(field, c: int, dir: Vector3) -> int:
	if field == null or field._grid == null or c < 0:
		return -1
	var d: int = slot_toward(dir)
	if d < 0:
		return -1
	return field._grid.neighbours[c * LAVoxelGrid.SLOTS + d]


## The open cell over `c`, found by marching up out of rock. -1 when the march leaves the box still in rock.
static func air_above(field, c: int, limit: int) -> int:
	var solid: PackedByteArray = field._solid
	var at: int = c
	for _k in limit:
		if at < 0:
			return -1
		if solid[at] == 0:
			return at
		at = above(field, at)
	return -1


## The open cell resting on rock over `c` — where a body stands. -1 when there is no such cell within `limit`.
static func ground(field, c: int, limit: int) -> int:
	var solid: PackedByteArray = field._solid
	var at: int = air_above(field, c, limit)
	if at < 0:
		return -1
	for _k in limit:
		var lo: int = below(field, at)
		if lo < 0 or solid[lo] != 0:
			return at
		at = lo
	return at


## Solid cells between `c` and open air, marching up. -1 when the march leaves the box still in rock, which
## is how a cell deeper than `limit` and a cell outside the box read the same: not near a surface.
static func burial_steps(field, c: int, limit: int) -> int:
	var solid: PackedByteArray = field._solid
	var at: int = c
	for k in limit:
		var hi: int = above(field, at)
		if hi < 0:
			return -1
		if solid[hi] == 0:
			return k
		at = hi
	return -1


## Geometric centre of the box, model units. `setup_body` builds the box around the body, so this is the
## body's centre and the pivot its rotation turns about.
static func centre(field) -> Vector3:
	var grid: LAVoxelGrid = field._grid if field != null else null
	if grid == null:
		return Vector3.ZERO
	return grid.origin + 0.5 * grid.cell_size * Vector3(grid.nx, grid.ny, grid.nz)


## Distance of a cell's centre from the body centre, model units — the coordinate `sea_radius` is quoted in.
static func radius_of(field, c: int) -> float:
	if field == null or field._grid == null:
		return 0.0
	return (field._grid.cell_world_pos(c) - centre(field)).length()


## Curl of the velocity field at `c`, 1/s, by central differences over the six neighbours.
static func curl(field, c: int) -> Vector3:
	var grid: LAVoxelGrid = field._grid
	if grid == null or c < 0:
		return Vector3.ZERO
	var dvx: Vector3 = _axis_deriv(field, c, LAVoxelGrid.S_NEG_X, LAVoxelGrid.S_POS_X)
	var dvy: Vector3 = _axis_deriv(field, c, LAVoxelGrid.S_NEG_Y, LAVoxelGrid.S_POS_Y)
	var dvz: Vector3 = _axis_deriv(field, c, LAVoxelGrid.S_NEG_Z, LAVoxelGrid.S_POS_Z)
	return Vector3(dvy.z - dvz.y, dvz.x - dvx.z, dvx.y - dvy.x)


## d(velocity)/d(axis) across the pair of slots on one axis, in 1/s.
static func _axis_deriv(field, c: int, lo_slot: int, hi_slot: int) -> Vector3:
	var grid: LAVoxelGrid = field._grid
	var base: int = c * LAVoxelGrid.SLOTS
	var lo: int = grid.neighbours[base + lo_slot]
	var hi: int = grid.neighbours[base + hi_slot]
	var h: float = maxf(grid.cell_size, 1.0e-6)
	if lo >= 0 and hi >= 0:
		return (velocity(field, hi) - velocity(field, lo)) / (2.0 * h)
	if hi >= 0:
		return (velocity(field, hi) - velocity(field, c)) / h
	if lo >= 0:
		return (velocity(field, c) - velocity(field, lo)) / h
	return Vector3.ZERO


## Air velocity at a cell, m/s, in the grid's own axes.
static func velocity(field, c: int) -> Vector3:
	if field._vel_x.size() != field._cell_count:
		return Vector3.ZERO
	return Vector3(field._vel_x[c], field._vel_y[c], field._vel_z[c])


## The body's spin axis expressed in the FIELD frame. The one place that answers it.
static func spin_axis(field) -> Vector3:
	if field._body != null and field._body.has_method("spin_axis"):
		var v: Vector3 = field.dir_to_field(field._body.spin_axis())
		if v.length() > 0.001:
			return v.normalized()
	return Vector3.ZERO
