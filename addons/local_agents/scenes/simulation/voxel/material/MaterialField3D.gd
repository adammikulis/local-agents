class_name LAMaterialField3D
extends Node3D

## LAMaterialField3D — the DENSE 3D material-flow substrate (successor to the 2.5D LAMaterialField).
##
## The 2.5D field stored one column per XZ cell (a surface height + material *depths*). That could not
## represent caves: water can't pool in a cavern, lava can't drain into a tube, a plume can't rise a
## shaft. This field stores a real 3D volume — a temperature + per-material amount for every (x,y,z)
## cell — so all of that EMERGES from local rules that now include the Y axis.
##
## DENSE (not sparse bricks): at the sim's 5-unit resolution the whole volume is ~0.9M cells × a few
## float layers ≈ ~20 MB, so a flat 3D array is the simplest thing that works. Solid rock cells (from
## the terrain SDF via is_solid) hold no fluid and are skipped; an active-cell list keeps the CPU
## oracle cheap without brick machinery. The GPU kernels become a 3D dispatch over the same arrays.
##
## Index layout: idx = (iy * _dim_z + iz) * _dim_x + ix  (X contiguous, then Z, then Y). World position
## of a cell centre = _origin + Vector3(ix, iy, iz) * _cell_size.
## (Explicit types only — no ':=' inferred typing.)

const Mat: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/Materials.gd")

# --- Water CA tuning (finite-volume cellular water: fall, pressurise, spread — mass-conserving and
# stable, and it fills sealed caverns bottom-up + supports pressure so water finds its level). Adapted
# from the classic 2D "finite water cells" scheme, generalised to 3D (down, up-if-compressed, 4 lateral).
const MAX_MASS: float = 1.0               # a cell is "full" at this water mass
const MAX_COMPRESS: float = 0.02          # extra mass a cell can hold per cell of water stacked above it
const MIN_MASS: float = 0.0001            # below this a cell is considered dry
const MAX_FLOW: float = 1.0               # max mass moved out of a cell per step (stability cap)
const MIN_FLOW: float = 0.01              # ignore dribbles smaller than this
const LATERAL_FRACTION: float = 0.5      # share of the level-out flow sent to each lateral neighbour

# --- Grid state -------------------------------------------------------------
var _terrain = null
var _cell_size: float = 5.0
var _origin: Vector3 = Vector3.ZERO       # world position of cell (0,0,0) centre
var _dim_x: int = 0
var _dim_y: int = 0
var _dim_z: int = 0
var _cell_count: int = 0

var _solid: PackedByteArray = PackedByteArray()          # 1 = rock (holds no fluid), 0 = void (air/water)
var _water: PackedFloat32Array = PackedFloat32Array()    # water mass per cell (can exceed 1 under pressure)
var _wnext: PackedFloat32Array = PackedFloat32Array()    # double buffer for the water step


# --- Setup ------------------------------------------------------------------

## Explicit-dimension setup (used by tests / when the caller knows the volume directly).
func setup_dims(dim_x: int, dim_y: int, dim_z: int, cell_size: float, origin: Vector3) -> void:
	_dim_x = maxi(1, dim_x)
	_dim_y = maxi(1, dim_y)
	_dim_z = maxi(1, dim_z)
	_cell_size = maxf(0.5, cell_size)
	_origin = origin
	_cell_count = _dim_x * _dim_y * _dim_z
	_solid = PackedByteArray()
	_solid.resize(_cell_count)
	_water = PackedFloat32Array()
	_water.resize(_cell_count)
	_wnext = PackedFloat32Array()
	_wnext.resize(_cell_count)


# --- Index helpers ----------------------------------------------------------

func _idx(ix: int, iy: int, iz: int) -> int:
	return (iy * _dim_z + iz) * _dim_x + ix


func _in_bounds(ix: int, iy: int, iz: int) -> bool:
	return ix >= 0 and ix < _dim_x and iy >= 0 and iy < _dim_y and iz >= 0 and iz < _dim_z


func cell_world_pos(ix: int, iy: int, iz: int) -> Vector3:
	return _origin + Vector3(float(ix), float(iy), float(iz)) * _cell_size


# --- Authoring (tests + terrain sampling) -----------------------------------

func set_solid(ix: int, iy: int, iz: int, solid: bool) -> void:
	if _in_bounds(ix, iy, iz):
		_solid[_idx(ix, iy, iz)] = 1 if solid else 0


func is_cell_solid(ix: int, iy: int, iz: int) -> bool:
	if not _in_bounds(ix, iy, iz):
		return true                                     # out of bounds reads as wall
	return _solid[_idx(ix, iy, iz)] != 0


func add_water_cell(ix: int, iy: int, iz: int, amount: float) -> void:
	if not _in_bounds(ix, iy, iz):
		return
	var i: int = _idx(ix, iy, iz)
	if _solid[i] != 0:
		return
	_water[i] = maxf(0.0, _water[i] + amount)


func water_at_cell(ix: int, iy: int, iz: int) -> float:
	if not _in_bounds(ix, iy, iz):
		return 0.0
	return _water[_idx(ix, iy, iz)]


func total_water() -> float:
	var s: float = 0.0
	for i in range(_cell_count):
		s += _water[i]
	return s


# --- The 3D water CA --------------------------------------------------------

# Stable amount for the LOWER of two vertically-stacked water cells given their combined mass. Below
# MAX_MASS all the water sits in the lower cell; above that the excess is compressed upward, letting a
# tall column press down (pressure) so water in a connected cavern finds a common level.
func _stable_below(total_mass: float) -> float:
	if total_mass <= MAX_MASS:
		return total_mass
	if total_mass < 2.0 * MAX_MASS + MAX_COMPRESS:
		return (MAX_MASS * MAX_MASS + total_mass * MAX_COMPRESS) / (MAX_MASS + MAX_COMPRESS)
	return (total_mass + MAX_COMPRESS) * 0.5


## One water step: gravity fall, upward pressure relief, then lateral levelling — mass-conserving via a
## double buffer. Fills caverns bottom-up and lets connected water find its level (rivers, lakes, sea,
## and now underground pools + water pouring into a cave through a shaft).
func step_water() -> void:
	# Start next = current; every transfer edits _wnext so reads stay on the stable _water snapshot.
	for i in range(_cell_count):
		_wnext[i] = _water[i]

	for iy in range(_dim_y):
		for iz in range(_dim_z):
			for ix in range(_dim_x):
				var i: int = _idx(ix, iy, iz)
				if _solid[i] != 0:
					continue
				var remaining: float = _water[i]
				if remaining < MIN_MASS:
					continue
				var flow: float = 0.0

				# 1) DOWN — gravity. Move toward the stable split with the cell below.
				if iy > 0:
					var ib: int = i - _dim_x * _dim_z
					if _solid[ib] == 0:
						flow = _stable_below(remaining + _water[ib]) - _water[ib]
						flow = clampf(flow, 0.0, minf(MAX_FLOW, remaining))
						if flow > MIN_FLOW:
							_wnext[i] -= flow
							_wnext[ib] += flow
							remaining -= flow
				if remaining < MIN_MASS:
					continue

				# 2) LATERAL — level out with the 4 side neighbours (only push to lower ones).
				var lat: Array = [
					[ix - 1, iz], [ix + 1, iz], [ix, iz - 1], [ix, iz + 1]
				]
				for pr in lat:
					if remaining < MIN_MASS:
						break
					var nx: int = pr[0]
					var nz: int = pr[1]
					if nx < 0 or nx >= _dim_x or nz < 0 or nz >= _dim_z:
						continue
					var inb: int = _idx(nx, iy, nz)
					if _solid[inb] != 0:
						continue
					var diff: float = remaining - _water[inb]
					if diff > MIN_FLOW:
						var lflow: float = clampf(diff * LATERAL_FRACTION, 0.0, minf(MAX_FLOW, remaining))
						if lflow > MIN_FLOW:
							_wnext[i] -= lflow
							_wnext[inb] += lflow
							remaining -= lflow

				# 3) UP — only overflow (compressed above MAX_MASS) pushes into the cell above.
				if remaining > MAX_MASS and iy < _dim_y - 1:
					var iu: int = i + _dim_x * _dim_z
					if _solid[iu] == 0:
						var uflow: float = remaining - _stable_below(remaining + _water[iu])
						uflow = clampf(uflow, 0.0, minf(MAX_FLOW, remaining))
						if uflow > MIN_FLOW:
							_wnext[i] -= uflow
							_wnext[iu] += uflow
							remaining -= uflow

	# Commit the buffer.
	var tmp: PackedFloat32Array = _water
	_water = _wnext
	_wnext = tmp


## Highest world Y that has water in the XZ column at grid (ix, iz), or NAN if the column is dry. Used
## by the surface queries + renderer to find the water surface (open sea/lake OR a cavern pool top).
func column_surface_y(ix: int, iz: int) -> float:
	if ix < 0 or ix >= _dim_x or iz < 0 or iz >= _dim_z:
		return NAN
	for iy in range(_dim_y - 1, -1, -1):
		var m: float = _water[_idx(ix, iy, iz)]
		if m >= MIN_MASS:
			# Surface sits within the top wet cell proportional to its fill.
			var fill: float = clampf(m, 0.0, MAX_MASS)
			return _origin.y + (float(iy) + fill - 0.5) * _cell_size
	return NAN
