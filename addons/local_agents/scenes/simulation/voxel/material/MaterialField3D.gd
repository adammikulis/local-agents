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


var _sea_level: float = 0.0
var _half_extent: float = 0.0


# --- Setup ------------------------------------------------------------------

## Build the 3D volume covering XZ in [-half_extent, half_extent] and Y in [y_min, y_max] at cell_size,
## bound to `terrain` (for the is_solid rock/void query). Cells are sampled solid/void lazily.
func setup(terrain, half_extent: float, cell_size: float, y_min: float, y_max: float, sea_level: float) -> void:
	_terrain = terrain
	_half_extent = maxf(1.0, half_extent)
	_cell_size = maxf(0.5, cell_size)
	_sea_level = sea_level
	var dx: int = int(round((2.0 * _half_extent) / _cell_size)) + 1
	var dy: int = int(round((y_max - y_min) / _cell_size)) + 1
	setup_dims(dx, dy, dx, _cell_size, Vector3(-_half_extent, y_min, -_half_extent))


## Sample rock/void for every cell from the terrain SDF (is_solid). Eager version — fine at setup for
## the dense grid; a budgeted lazy variant can replace it once wired into the frame loop. Skips the
## per-cell query for cells clearly in open air above the column's surface (cheap win).
func sample_solidity() -> void:
	if _terrain == null or not _terrain.has_method("is_solid"):
		return
	var has_surf: bool = _terrain.has_method("surface_height")
	for iz in range(_dim_z):
		for ix in range(_dim_x):
			var wx: float = _origin.x + float(ix) * _cell_size
			var wz: float = _origin.z + float(iz) * _cell_size
			var surf: float = _terrain.surface_height(wx, wz) if has_surf else NAN
			for iy in range(_dim_y):
				var wy: float = _origin.y + float(iy) * _cell_size
				var i: int = _idx(ix, iy, iz)
				# Well above the surface => open air, no need to query (also handles NAN columns as air).
				if not is_nan(surf) and wy > surf + _cell_size:
					_solid[i] = 0
					continue
				_solid[i] = 1 if _terrain.is_solid(Vector3(wx, wy, wz)) else 0


## Seed the ocean: every VOID cell whose centre is below sea level starts full of water. The sea is a
## known level, so we set it directly (fast) instead of CA-filling the whole seabed from empty; the CA
## then only has to handle dynamics (waves, splashes, rivers meeting the sea, water pouring into caves).
func seed_sea() -> void:
	for iy in range(_dim_y):
		var wy: float = _origin.y + float(iy) * _cell_size
		if wy >= _sea_level:
			break                                       # layers above sea level: nothing to seed
		for iz in range(_dim_z):
			for ix in range(_dim_x):
				var i: int = _idx(ix, iy, iz)
				if _solid[i] == 0 and _water[i] < MAX_MASS:
					_water[i] = MAX_MASS


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


# --- World-space queries (the 2.5D-compatible API the consumers call) --------

func _col_i(w: float, o: float) -> int:
	return clampi(int(round((w - o) / _cell_size)), 0, _dim_x - 1)


## World Y of the water surface at (x, z) — sea, lake, river, or a cavern pool top. NAN if dry.
func surface_y_at(x: float, z: float) -> float:
	return column_surface_y(_col_i(x, _origin.x), _col_i(z, _origin.z))


func is_water_at(x: float, z: float) -> bool:
	return not is_nan(surface_y_at(x, z))


## Total water column depth at (x, z) in world units (sum of cell fills × cell size). 0 if dry.
func depth_at(x: float, z: float) -> float:
	var ix: int = _col_i(x, _origin.x)
	var iz: int = _col_i(z, _origin.z)
	var d: float = 0.0
	for iy in range(_dim_y):
		d += minf(_water[_idx(ix, iy, iz)], MAX_MASS)
	return d * _cell_size


## Inject water at a world point (a spring, rain, a flood surge, a meteor splash).
func add_water_world(pos: Vector3, amount: float) -> void:
	add_water_cell(_col_i(pos.x, _origin.x), _col_i(pos.y, _origin.y), _col_i(pos.z, _origin.z), amount)
