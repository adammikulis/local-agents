class_name LAMaterialFieldQueries3D
extends RefCounted

## LAMaterialFieldQueries3D — the READ-ONLY query accessors of the dense 3D MaterialField3D, factored
## out so the field node stays a thin simulation/composition core (and under the file-size gate). Holds
## NO state of its own: it reaches into the owning LAMaterialField3D (`_f`) for the shared per-cell
## arrays (`_temp`, `_water`, `_solid`, `_static`, `_lava`) plus geometry (`_dim_x/_dim_y/_dim_z`,
## `_cell_size`, `_origin`, `sea_level`) and constants (`MAX_MASS`, `RENDER_MIN`), exactly as the heat /
## atmosphere / lava concern modules do. Every method here is a pure getter — it never mutates the field.
## The field exposes each as a thin forwarder so the 2.5D-compatible consumer API is unchanged.
## (Explicit types only — no ':=' inferred typing.)

# Salinity banding (depth-of-sea proxy) — own copies of the field's constants so fish behave identically.
const SALT_FULL_DEPTH: float = 22.0
const BRACKISH_FLOOR: float = 0.35

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


# --- Index helpers (world -> grid cell), matching the field's original _col_i clamp behaviour ---
func _col_i(w: float, o: float) -> int:
	return clampi(int(round((w - o) / _f._cell_size)), 0, _f._dim_x - 1)


# Topmost non-solid cell of a column (its sky-exposed surface), or -1 if solid to the top.
func _surface_iy(ix: int, iz: int) -> int:
	for iy in range(_f._dim_y - 1, -1, -1):
		if _f._solid[(iy * _f._dim_z + iz) * _f._dim_x + ix] == 0:
			return iy
	return -1


# --- Water-surface queries ---------------------------------------------------

## Highest world Y that has water in the XZ column at grid (ix, iz), or NAN if the column is dry.
func column_surface_y(ix: int, iz: int) -> float:
	if ix < 0 or ix >= _f._dim_x or iz < 0 or iz >= _f._dim_z:
		return NAN
	for iy in range(_f._dim_y - 1, -1, -1):
		var m: float = _f._water[(iy * _f._dim_z + iz) * _f._dim_x + ix]
		if m >= _f.MIN_MASS:
			var fill: float = clampf(m, 0.0, _f.MAX_MASS)
			return _f._origin.y + (float(iy) + fill - 0.5) * _f._cell_size
	return NAN


## World Y of the water surface at (x, z) — sea, lake, river, or a cavern pool top. NAN if dry.
func surface_y_at(x: float, z: float) -> float:
	return column_surface_y(_col_i(x, _f._origin.x), _col_i(z, _f._origin.z))


func is_water_at(x: float, z: float) -> bool:
	return not is_nan(surface_y_at(x, z))


## Total water column depth at (x, z) in world units (sum of cell fills × cell size). 0 if dry.
func depth_at(x: float, z: float) -> float:
	var ix: int = _col_i(x, _f._origin.x)
	var iz: int = _col_i(z, _f._origin.z)
	var d: float = 0.0
	for iy in range(_f._dim_y):
		d += minf(_f._water[(iy * _f._dim_z + iz) * _f._dim_x + ix], _f.MAX_MASS)
	return d * _f._cell_size


func water_at_cell(ix: int, iy: int, iz: int) -> float:
	if not _f._in_bounds(ix, iy, iz):
		return 0.0
	return _f._water[_f._idx(ix, iy, iz)]


func total_water() -> float:
	var s: float = 0.0
	for i in range(_f._cell_count):
		s += _f._water[i]
	return s


# --- Temperature query -------------------------------------------------------

## Temperature °C at a world point (0 outside the grid). NAN y resolves to the column's exposed surface.
func temp_at(x: float, z: float, y: float = NAN) -> float:
	var ix: int = _col_i(x, _f._origin.x)
	var iz: int = _col_i(z, _f._origin.z)
	var iy: int = _col_i(y, _f._origin.y) if not is_nan(y) else _surface_iy(ix, iz)
	if iy < 0:
		return 0.0
	return _f._temp[(iy * _f._dim_z + iz) * _f._dim_x + ix]


# --- Ocean / salinity --------------------------------------------------------

## True where the ground is below sea level (open ocean under the plane).
func is_ocean_at(x: float, z: float) -> bool:
	var ix: int = _col_i(x, _f._origin.x)
	var iz: int = _col_i(z, _f._origin.z)
	for iy in range(_f._dim_y):
		if _f._origin.y + float(iy) * _f._cell_size >= _f.sea_level:
			break
		if _f._solid[(iy * _f._dim_z + iz) * _f._dim_x + ix] == 0:
			return true
	return false


## Salinity 0 (fresh inland water) .. brackish shallows .. 1 (deep salt ocean); NAN if dry.
func salinity_at(x: float, z: float) -> float:
	if is_ocean_at(x, z):
		var ix: int = _col_i(x, _f._origin.x)
		var iz: int = _col_i(z, _f._origin.z)
		var floor_y: float = _f.sea_level
		for iy in range(_f._dim_y):
			if _f._solid[(iy * _f._dim_z + iz) * _f._dim_x + ix] == 0:
				floor_y = _f._origin.y + float(iy) * _f._cell_size
				break
		return clampf((_f.sea_level - floor_y) / SALT_FULL_DEPTH, BRACKISH_FLOOR, 1.0)
	if is_water_at(x, z):
		return 0.0                                       # inland CA pool (lake/river) = fresh
	return NAN


# --- Diagnostics -------------------------------------------------------------

func wet_cell_count() -> int:
	var n: int = 0
	for i in range(_f._cell_count):
		if _f._solid[i] == 0 and _f._static[i] == 0 and _f._water[i] >= _f.RENDER_MIN:
			n += 1
	return n


func peak_heat() -> float:
	var m: float = 0.0
	for i in range(_f._cell_count):
		if _f._solid[i] == 0 and _f._temp[i] > m:
			m = _f._temp[i]
	return m


func hot_cell_count(threshold: float = 60.0) -> int:
	var n: int = 0
	for i in range(_f._cell_count):
		if _f._solid[i] == 0 and _f._temp[i] >= threshold:
			n += 1
	return n


# --- Storm queries (read the emergent wind field; storm actors track the vortex they seed) -----------

# Sample cell a couple of cells above a column's surface (the free-stream, clear of the ground layer).
func _aloft_i(ix: int, iz: int) -> int:
	var siy: int = clampi(_surface_iy(ix, iz) + 2, 0, _f._dim_y - 1)
	return (siy * _f._dim_z + iz) * _f._dim_x + ix


## Vertical vorticity (curl_y of the horizontal wind) at a world point — the SPIN of the air. A tornado /
## mesocyclone reads as a strong |vorticity|; storm actors scale their funnel + track toward the peak.
func vorticity_at(x: float, z: float) -> float:
	if _f._cell_count <= 0:
		return 0.0
	var ix: int = _col_i(x, _f._origin.x)
	var iz: int = _col_i(z, _f._origin.z)
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	# curl_y = d(vel_z)/dx - d(vel_x)/dz, central differences at the aloft sample plane.
	var vz_hi: float = _f._vel_z[_aloft_i(mini(ix + 1, dx - 1), iz)]
	var vz_lo: float = _f._vel_z[_aloft_i(maxi(ix - 1, 0), iz)]
	var vx_hi: float = _f._vel_x[_aloft_i(ix, mini(iz + 1, dz - 1))]
	var vx_lo: float = _f._vel_x[_aloft_i(ix, maxi(iz - 1, 0))]
	return 0.5 * (vz_hi - vz_lo) - 0.5 * (vx_hi - vx_lo)


## Vertical wind (updraft, +Y) at a column's surface — the convective lift feeding a thunderstorm cell.
func updraft_at(x: float, z: float) -> float:
	if _f._cell_count <= 0:
		return 0.0
	var ix: int = _col_i(x, _f._origin.x)
	var iz: int = _col_i(z, _f._origin.z)
	return _f._vel_y[_aloft_i(ix, iz)]
