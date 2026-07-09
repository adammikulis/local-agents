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
	if _f._sphere != null:
		var c: int = _f.world_to_cell(Vector3(x, _f.sea_level + 40.0, z))
		return _f._vel_y[c] if (c >= 0 and _f._vel_y.size() == _f._cell_count) else 0.0
	var ix: int = _col_i(x, _f._origin.x)
	var iz: int = _col_i(z, _f._origin.z)
	return _f._vel_y[_aloft_i(ix, iz)]


# --- Emergent WIND as a real momentum/force (read back from the GPU velocity field) ------------------
# On the cubed sphere the kernel stores velocity in a per-cell TANGENT basis: vel_x/vel_z along the two
# tangent slot-pairs (from the neighbour positions), vel_y along the OUTWARD RADIAL. wind3_at reconstructs a
# true WORLD-space velocity from that basis so loose mass (creatures/debris/sediment) can be advected/flung
# by it. Reads only the cell + its 6 neighbours' positions — O(1) per query, no grid sweep.

## Full LOCAL 3D wind velocity (world-space) at a world point. Vector3.ZERO outside the shell / before readback.
func wind3_at(x: float, y: float, z: float) -> Vector3:
	if _f._sphere == null or _f._vel_x.size() != _f._cell_count:
		return Vector3.ZERO
	var c: int = _f.world_to_cell(Vector3(x, y, z))
	if c < 0 or c >= _f._cell_count:
		return Vector3.ZERO
	var radial: Vector3 = _f.cell_radial(c)
	var pos_c: Vector3 = _f.cell_world_pos_linear(c)
	var nbr: PackedInt32Array = _f._sphere.neighbours
	var tan_a: Vector3 = _tangent_axis(c, pos_c, nbr[c * 6 + 2], nbr[c * 6 + 1], radial)
	var tan_b: Vector3 = _tangent_axis(c, pos_c, nbr[c * 6 + 4], nbr[c * 6 + 3], radial)
	return radial * _f._vel_y[c] + tan_a * _f._vel_x[c] + tan_b * _f._vel_z[c]


# Unit tangent axis from the cell toward its +slot neighbour (falling back to −slot, then to any vector
# orthogonal to `radial`), matching the kernel's slot-pair pressure-gradient direction.
func _tangent_axis(c: int, pos_c: Vector3, hi: int, lo: int, radial: Vector3) -> Vector3:
	var d: Vector3 = Vector3.ZERO
	if hi >= 0:
		d = _f.cell_world_pos_linear(hi) - pos_c
	elif lo >= 0:
		d = pos_c - _f.cell_world_pos_linear(lo)
	# Project onto the tangent plane + normalise; degenerate → an arbitrary orthonormal tangent.
	d = d - radial * d.dot(radial)
	if d.length_squared() < 1.0e-8:
		d = radial.cross(Vector3.UP)
		if d.length_squared() < 1.0e-8:
			d = radial.cross(Vector3.RIGHT)
	return d.normalized()


## LOCAL horizontal wind (world XZ) at a world column — the tangential drift a storm cell rides. Sampled a
## little above the sea shell so it reads the free-stream, not the ground layer.
func wind_at(x: float, z: float) -> Vector2:
	var v: Vector3 = wind3_at(x, _f.sea_level + 40.0, z)
	return Vector2(v.x, v.z)


## Domain-average horizontal wind magnitude/direction (ocean swell / HUD). Strided sample (every STRIDE-th
## cell) so it stays O(cells/STRIDE), never a full per-call grid sweep.
func wind() -> Vector2:
	if _f._sphere == null or _f._vel_x.size() != _f._cell_count:
		return Vector2.ZERO
	const STRIDE: int = 97
	var sx: float = 0.0
	var sz: float = 0.0
	var n: int = 0
	var c: int = 0
	while c < _f._cell_count:
		if _f._solid[c] == 0:
			var radial: Vector3 = _f.cell_radial(c)
			var pos_c: Vector3 = _f.cell_world_pos_linear(c)
			var nbr: PackedInt32Array = _f._sphere.neighbours
			var tan_a: Vector3 = _tangent_axis(c, pos_c, nbr[c * 6 + 2], nbr[c * 6 + 1], radial)
			var tan_b: Vector3 = _tangent_axis(c, pos_c, nbr[c * 6 + 4], nbr[c * 6 + 3], radial)
			var v: Vector3 = tan_a * _f._vel_x[c] + tan_b * _f._vel_z[c]
			sx += v.x
			sz += v.z
			n += 1
		c += STRIDE
	if n == 0:
		return Vector2.ZERO
	return Vector2(sx / float(n), sz / float(n))


# --- MINERAL conservation ledger (rock unification) — ONE conserved mineral, phases summed in one mass unit ----
# ROCK is ONE substance whose PHASE (bedrock / molten / loose / suspended / airborne) is a state; every transition
# is a mass transfer between the legs (a full cell of any phase = MAX_MASS = 1.0). mineral_total() must stay BOUNDED
# across frames to within genuine sources/vents — the unification's proof object. Stage B made bedrock FRACTIONAL
# (rock_fill), so the ledger conserves CONTINUOUSLY across the solid boundary (a partial solidify credits fractional
# rock, not a whole fabricated cell). sediment/dust are surface phases (open cells); lava/rock_fill sum ALL cells.

## Loose granular regolith (talus/dune sediment) over open cells — the "loose" mineral phase.
func sediment_total() -> float:
	if _f._sediment.size() != _f._cell_count:
		return 0.0
	var sum: float = 0.0
	for c in _f._cell_count:
		if _f._solid[c] == 0:
			sum += _f._sediment[c]
	return sum

## Airborne wind-lofted dust over open cells — the "airborne" mineral phase.
func dust_total() -> float:
	if _f._dust.size() != _f._cell_count:
		return 0.0
	var sum: float = 0.0
	for c in _f._cell_count:
		if _f._solid[c] == 0:
			sum += _f._dust[c]
	return sum

## Molten rock (lava) over ALL cells — the "molten" phase. Summed everywhere (not just open cells) because add_lava
## can inject lava into a still-solid vent and lava lingers the instant a cell crosses to derived-solid; excluding
## those would leak the ledger. Lava physically exists wherever its mass is, regardless of the derived `solid` flag.
func lava_total() -> float:
	if _f._lava.size() != _f._cell_count:
		return 0.0
	var sum: float = 0.0
	for c in _f._cell_count:
		sum += _f._lava[c]
	return sum

## Derived-solid (bedrock) cell count — a display/diagnostic (cells whose derived solid flag is set). NOT the mineral
## mass baseline anymore: Stage B made bedrock a FRACTIONAL channel (rock_fill), so the mass baseline is rock_fill_total().
func rock_cells() -> int:
	var n: int = 0
	for c in _f._cell_count:
		if _f._solid[c] != 0:
			n += 1
	return n

## Fractional BEDROCK mineral mass over ALL cells — the authoritative "bedrock" phase. Seeded 1.0 per solid cell (so
## the initial value == the old rock_cells() baseline), then conservingly traded with lava by M5 solidify (lava→rock),
## M6 melt and add_lava (rock→lava). Replaces the binary quantum so the solid boundary conserves continuously.
func rock_fill_total() -> float:
	if _f._rock_fill.size() != _f._cell_count:
		return 0.0
	var sum: float = 0.0
	for c in _f._cell_count:
		sum += _f._rock_fill[c]
	return sum

## The ONE mineral total: Σ bedrock(rock_fill) + molten(lava) + loose(sediment) + suspended(susp, dead until Stage D)
## + airborne(dust). Must stay BOUNDED — this is the unification's proof object.
func mineral_total() -> float:
	return rock_fill_total() + lava_total() + sediment_total() + dust_total()
