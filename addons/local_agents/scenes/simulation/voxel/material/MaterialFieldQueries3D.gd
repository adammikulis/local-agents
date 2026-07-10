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


# --- Cell resolver (world -> linear cell) ------------------------------------
# Sphere-native: the ONE world→cell seam is the field's world_to_cell (cubed-sphere gnomonic lookup; box mode
# clamps). Every query below indexes the linear cell it returns and null-guards c < 0 (outside the shell), so
# a read anywhere off the +Y pole is a safe default, never an out-of-bounds PackedByteArray access.
func _cell_at(pos: Vector3) -> int:
	return _f.world_to_cell(pos)


# True where the seeded SEA/lake shell sits over the ground beneath `pos` — the sphere replacement for the box
# "column has sea water" test, using the field's own water buffer (cheap, no terrain raycast). Samples the top
# sea layer along pos's radial (just under the sea surface, then one cell deeper to straddle it): over an ocean
# basin those cells are open seeded water (mass ≥ MIN_MASS); over land they are inside solid rock (dry). The
# shallow (near-surface) sample is what catches the topmost seeded layer — sampling a full cell down misses
# shallow basins whose floor sits between the two depths. O(1): a couple of world_to_cell lookups, no scan.
func _sea_under(pos: Vector3) -> bool:
	if _f._terrain == null or not _f._terrain.has_method("sea_radius") or _f._water.size() != _f._cell_count:
		return false
	var sea_r: float = _f._terrain.sea_radius()
	if sea_r <= 0.0:
		return false
	var radial: Vector3 = pos - _f._origin
	if radial.length_squared() < 1.0e-6:
		return false
	var dir: Vector3 = radial.normalized()
	var depths: PackedFloat32Array = PackedFloat32Array([sea_r - 0.5, sea_r - _f._cell_size])
	for rr in depths:
		if rr <= 0.0:
			continue
		var sc: int = _f.world_to_cell(_f._origin + dir * rr)
		if sc >= 0 and _f._water[sc] >= _f.MIN_MASS:
			return true
	return false


# --- Water queries -----------------------------------------------------------

## True where there is drinkable water at a world point: water in the cell the point sits in (a river, a
## rain puddle, a pool it stands in) OR the sea/lake shell over the ground beneath it (a creature at the
## shoreline above the water film). Sphere-native — no XZ column. False outside the shell / before readback.
func is_water_at(pos: Vector3) -> bool:
	if _f._water.size() != _f._cell_count:
		return false
	var c: int = _f.world_to_cell(pos)
	if c >= 0 and _f._water[c] >= _f.MIN_MASS:
		return true
	return _sea_under(pos)


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

## Temperature °C at a world point (a mild default outside the shell). Sphere-native single 3D read.
func temp_at(pos: Vector3) -> float:
	if _f._temp.size() != _f._cell_count:
		return _f.INITIAL_TEMP
	var c: int = _f.world_to_cell(pos)
	return _f._temp[c] if c >= 0 else _f.INITIAL_TEMP


# --- Ocean / salinity --------------------------------------------------------

## True where the ground beneath a world point is below the sea shell (open salt ocean / a sea basin). Uses the
## terrain surface radius directly (ground below sea level ⇒ ocean), which is exact for any basin depth — storms
## call this a bounded number of times, so the raycast cost is fine (vs. is_water_at's cheap per-cell sampling).
func is_ocean_at(pos: Vector3) -> bool:
	if _f._terrain != null and _f._terrain.has_method("sea_radius") and _f._terrain.has_method("surface_radius"):
		var sea_r: float = _f._terrain.sea_radius()
		if sea_r <= 0.0:
			return false
		var radial: Vector3 = pos - _f._origin
		if radial.length_squared() < 1.0e-6:
			return false
		var sr: float = _f._terrain.surface_radius(radial.normalized())
		return not is_nan(sr) and sr < sea_r
	return _sea_under(pos)


## Salinity 0 (fresh inland water) .. brackish shallows .. 1 (deep salt ocean); NAN if dry. On the sphere
## the basin depth is (sea_radius − solid_surface_radius) along the point's radial.
func salinity_at(pos: Vector3) -> float:
	if _f._terrain != null and _f._terrain.has_method("sea_radius") and is_ocean_at(pos):
		var sea_r: float = _f._terrain.sea_radius()
		var floor_r: float = sea_r
		if _f._terrain.has_method("surface_radius"):
			var sr: float = _f._terrain.surface_radius(pos - _f._origin)
			if not is_nan(sr):
				floor_r = sr
		return clampf((sea_r - floor_r) / SALT_FULL_DEPTH, BRACKISH_FLOOR, 1.0)
	if is_water_at(pos):
		return 0.0                                       # inland pool (lake/river) = fresh
	return NAN


# --- Diagnostics -------------------------------------------------------------

## Radial rock-temperature profile — mean temp of SOLID cells binned by radial shell r = c % _dim_y
## (r = 0 is the innermost core shell, r = _dim_y - 1 the outermost/surface). Reports the geothermal
## gradient the crust actually carries (core → mid-crust → near-surface rock) so we can see whether the
## crust insulates the hot core from a temperate surface. Sphere-only; snapshot-time, single O(cells) pass.
func rock_radial_profile() -> Dictionary:
	if not _f.is_sphere() or _f._dim_y <= 0 or _f._temp.size() != _f._cell_count:
		return {}
	var depth: int = _f._dim_y
	var shell_sum: PackedFloat32Array = PackedFloat32Array()
	var shell_n: PackedInt32Array = PackedInt32Array()
	shell_sum.resize(depth)
	shell_n.resize(depth)
	for c in range(_f._cell_count):
		if _f._solid[c] == 0:
			continue
		var r: int = c % depth
		shell_sum[r] += _f._temp[c]
		shell_n[r] += 1
	var core: float = _shell_mean(shell_sum, shell_n, 0)
	var q25: float = _shell_mean(shell_sum, shell_n, int(round(float(depth) * 0.25)))
	var mid: float = _shell_mean(shell_sum, shell_n, depth / 2)
	var q75: float = _shell_mean(shell_sum, shell_n, int(round(float(depth) * 0.75)))
	# Near-surface rock = outermost shell that still holds solid cells (walk inward from the rim).
	var top: int = depth - 1
	while top > 0 and shell_n[top] == 0:
		top -= 1
	var surf_rock: float = _shell_mean(shell_sum, shell_n, top)
	return {
		"rock_core_c": core, "rock_q25_c": q25, "rock_mid_c": mid,
		"rock_q75_c": q75, "rock_surf_c": surf_rock,
	}


func _shell_mean(shell_sum: PackedFloat32Array, shell_n: PackedInt32Array, r: int) -> float:
	if r < 0 or r >= shell_n.size() or shell_n[r] == 0:
		return 0.0
	return shell_sum[r] / float(shell_n[r])


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

## Radial vorticity (the SPIN of the air about the local "up") at a world point. On the cubed sphere the
## kernel stores velocity in a per-cell TANGENT basis (vel_x along tangent-a, vel_z along tangent-b, vel_y
## radial), so the vertical-axis curl is d(vel_z)/d(tangent_a) − d(vel_x)/d(tangent_b) across the cell's two
## tangent neighbour-slot pairs — the same neighbour walk wind3_at uses. Sampled a couple of cells aloft
## (the free-stream over the seeded low). Reads the cell + its 4 tangent neighbours only — O(1), no grid sweep.
func vorticity_at(pos: Vector3) -> float:
	if _f._sphere == null or _f._vel_x.size() != _f._cell_count or _f._vel_z.size() != _f._cell_count:
		return 0.0
	var radial: Vector3 = pos - _f._origin
	var aloft: Vector3 = pos
	if radial.length_squared() > 1.0e-6:
		aloft = pos + radial.normalized() * (2.0 * _f._cell_size)
	var c: int = _f.world_to_cell(aloft)
	if c < 0 or c >= _f._cell_count:
		return 0.0
	var nbr: PackedInt32Array = _f._sphere.neighbours
	var a_lo: int = nbr[c * 6 + 1]
	var a_hi: int = nbr[c * 6 + 2]
	var b_lo: int = nbr[c * 6 + 3]
	var b_hi: int = nbr[c * 6 + 4]
	var vz_hi: float = _f._vel_z[a_hi] if a_hi >= 0 else _f._vel_z[c]
	var vz_lo: float = _f._vel_z[a_lo] if a_lo >= 0 else _f._vel_z[c]
	var vx_hi: float = _f._vel_x[b_hi] if b_hi >= 0 else _f._vel_x[c]
	var vx_lo: float = _f._vel_x[b_lo] if b_lo >= 0 else _f._vel_x[c]
	return 0.5 * (vz_hi - vz_lo) - 0.5 * (vx_hi - vx_lo)


## Vertical wind (updraft = outward radial velocity, vel_y) a little above a world point — the convective
## lift feeding a thunderstorm cell. Sampled ~40 units aloft along the radial so it reads the cloud-base
## lift, not the ground layer. Sphere-native single 3D read; 0 outside the shell / before readback.
func updraft_at(pos: Vector3) -> float:
	if _f._sphere == null or _f._vel_y.size() != _f._cell_count:
		return 0.0
	var radial: Vector3 = pos - _f._origin
	var aloft: Vector3 = pos
	if radial.length_squared() > 1.0e-6:
		aloft = pos + radial.normalized() * 40.0
	var c: int = _f.world_to_cell(aloft)
	return _f._vel_y[c] if c >= 0 else 0.0


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

## Mean airborne dust across the grid — a 0..~ opacity proxy for how much debris in the air blocks the sun
## (a meteor volley lofts dust → this rises → insolation drops → impact winter). Cheap O(1)-amortised via dust_total.
func avg_atmos_dust() -> float:
	if _f._cell_count <= 0:
		return 0.0
	return dust_total() / float(_f._cell_count)


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
