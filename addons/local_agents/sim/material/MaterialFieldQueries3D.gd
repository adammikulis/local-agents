class_name LAMaterialFieldQueries3D
extends RefCounted

## LAMaterialFieldQueries3D: the READ-ONLY query accessors of the dense 3D MaterialField3D, factored
## out so the field node stays a thin simulation/composition core (and under the file-size gate). Holds
## NO state of its own: it reaches into the owning LAMaterialField3D (`_f`) for the shared per-cell
## arrays (`_temp`, `_water`, `_solid`, `_static`, `_lava`) plus geometry (`_dim_x/_dim_y/_dim_z`,
## `_cell_size`, `_origin`, `sea_level`) and constants (`MAX_MASS`, `RENDER_MIN`), exactly as the heat /
## atmosphere / lava concern modules do. Every method here is a pure getter that never mutates the field.
## The field exposes each as a thin forwarder so the 2.5D-compatible consumer API is unchanged.
## (Explicit types only, no ':=' inferred typing.)

# Salinity banding (depth-of-sea proxy) — own copies of the field's constants so fish behave identically.
const SALT_FULL_DEPTH: float = 22.0
const BRACKISH_FLOOR: float = 0.35
# PRESENCE FLOOR for the `dust_cells` gauge: the smallest airborne-dust density this counts as "a dusty cell"
# rather than numerical residue. It is a property of the MEASUREMENT, not of dust — there is no physical
# threshold at which a suspension starts existing — so it lives with the gauge that uses it and is deliberately
# not in `material/PhysicalConstants.gd`. *(Corrected 2026-08-03: this said the value "mirrors DUST_MIN in
# activity_sphere3d.glsl:95", which made a gauge's reporting floor look like a copy of a substrate rule bound
# only by a comment. It is not one, and that kernel is being retired on another lane.)*
const DUST_PRESENT: float = 0.001

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


# --- Water CURRENT (the sweep force) -----------------------------------------
# Tuning for the shallow-water drag that moving water exerts on anything standing in it.
const SWEEP_PROBE: float = 6.0        # tangent-plane sample distance for the downhill gradient (~one cell)
const SWEEP_STRENGTH: float = 9.0     # world units/sec of push per (depth × slope) unit — tune vs flood feel
const SWEEP_MIN_WATER: float = 0.12   # below this local water mass (and no sea shell) there's no current

## Local WATER CURRENT force at a world point — the direction + strength moving water pushes anything standing
## in it. It is the shallow-water drag: proportional to how DEEP the water is AND how STEEP the free surface is
## (the terrain's tangent-plane gradient), pointed DOWNHILL. Zero where there's no water or the ground is flat
## — a still pond gives no sweep (you just drown if it's deep), a flooded hillside or a river gives a strong
## downhill shove. No new CA and no new state: derived from the existing water buffer + terrain.surface_radius.
## Returned in world space, tangent to the surface. O(1) + a few radial raycasts, and only paid by actors the
## caller already knows are in water (they gate on is_water_at first).
func water_force_at(pos: Vector3) -> Vector3:
	if _f._water.size() != _f._cell_count or _f._terrain == null or not _f._terrain.has_method("surface_radius"):
		return Vector3.ZERO
	var c: int = _f.world_to_cell(pos)
	var depth: float = _f._water[c] if c >= 0 else 0.0
	if depth < SWEEP_MIN_WATER and not _sea_under(pos):
		return Vector3.ZERO
	var up: Vector3 = pos - _f._origin
	if up.length_squared() < 1.0e-6:
		return Vector3.ZERO
	up = up.normalized()
	# Two tangent axes spanning the local ground plane (pick a stable seed axis away from the radial).
	var t1: Vector3 = up.cross(Vector3.RIGHT)
	if t1.length_squared() < 1.0e-4:
		t1 = up.cross(Vector3.FORWARD)
	t1 = t1.normalized()
	var t2: Vector3 = up.cross(t1).normalized()
	var r_p1: float = _f._terrain.surface_radius((pos + t1 * SWEEP_PROBE) - _f._origin)
	var r_m1: float = _f._terrain.surface_radius((pos - t1 * SWEEP_PROBE) - _f._origin)
	var r_p2: float = _f._terrain.surface_radius((pos + t2 * SWEEP_PROBE) - _f._origin)
	var r_m2: float = _f._terrain.surface_radius((pos - t2 * SWEEP_PROBE) - _f._origin)
	if is_nan(r_p1) or is_nan(r_m1) or is_nan(r_p2) or is_nan(r_m2):
		return Vector3.ZERO
	# Free-surface gradient (approximated by the ground gradient — the water sheet follows the terrain); the
	# current flows toward DECREASING surface radius (downhill).
	var grad: Vector3 = t1 * ((r_p1 - r_m1) / (2.0 * SWEEP_PROBE)) + t2 * ((r_p2 - r_m2) / (2.0 * SWEEP_PROBE))
	var slope: float = grad.length()
	if slope < 1.0e-4:
		return Vector3.ZERO
	var downhill: Vector3 = -grad / slope
	var d: float = maxf(depth, 0.3)          # the sea/lake shell carries a current even where the cell mass reads low
	return downhill * (SWEEP_STRENGTH * d * slope)


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
	#
	# READ `rock_surf_c` AND `rock_q75_c` WITH CARE — they are NOT the rock surface. They are SHELL means at
	# fixed radii, and the outer shells are above the terrain nearly everywhere, so the only solid cells in
	# them are volcanic buildup: a handful of freshly-erupted, still-molten cells. Measured 2026-08-03 with a
	# room-temperature interior (rock_core_c 15.02), the same report read rock_q75_c 596 and rock_surf_c 505 —
	# purely lava, and read naively they say the crust is hotter at the top than at the core.
	# `rock_skin_c` below is the right shape for the question "how hot is the ground": ONE cell per column,
	# each column's own outermost rock, so every column counts once and no shell is empty.
	var top: int = depth - 1
	while top > 0 and shell_n[top] == 0:
		top -= 1
	var surf_rock: float = _shell_mean(shell_sum, shell_n, top)
	var skin_sum: float = 0.0
	var skin_n: int = 0
	for s in range(_f._cell_count / depth):
		var base: int = s * depth
		for r in range(depth - 1, -1, -1):
			if _f._solid[base + r] != 0:
				skin_sum += _f._temp[base + r]
				skin_n += 1
				break
	return {
		"rock_core_c": core, "rock_q25_c": q25, "rock_mid_c": mid,
		"rock_q75_c": q75, "rock_surf_c": surf_rock,
		"rock_skin_c": (skin_sum / float(skin_n)) if skin_n > 0 else 0.0,
		"rock_skin_cells": skin_n,
	}


func _shell_mean(shell_sum: PackedFloat32Array, shell_n: PackedInt32Array, r: int) -> float:
	if r < 0 or r >= shell_n.size() or shell_n[r] == 0:
		return 0.0
	return shell_sum[r] / float(shell_n[r])


## HOT-SPRING gauge (proof the geothermal groundwater→surface heat coupling emerges). Counts OPEN, non-sea
## (dynamic-water, not the static ocean reservoir) surface-water cells whose temperature has been driven well
## above ambient by groundwater surfacing through hot rock — i.e. hot springs / fumaroles. `hotspring_cells` =
## warm discharge (>60°C), `hotspring_boiling` = at or over the BOILING POINT OF WATER, `hotspring_max_c` = the
## hottest such cell. The static-sea exclusion + the 60°C floor keep the ordinary sea and solar-warmed rivers
## out, so a non-zero count is specifically groundwater-carried geothermal heat. Snapshot-time, one O(cells) pass.
##
## THE BOILING THRESHOLD WAS 90.0, described in this comment as "where the evap kernel flashes steam". That was
## false — `atmos_evap_sphere3d.glsl` flashes at BOIL_TEMP 100.0, which is LAPhysical.WATER_BOIL_C — so the
## gauge counted 10 degrees of cells as boiling that the physics did not, and justified it with a claim about a
## kernel it did not match. Corrected 2026-08-03 to read the authority. `hotspring_boiling` counts here are not
## comparable across that change; `hotspring_cells` (>60) is unaffected.
##
## The 60°C warm floor and the 30°C mild floor stay literals on purpose: they are not phase points, they are
## the thresholds a person would call a spring "hot" or "warm" at, and there is no measured property of matter
## behind either.
func hot_spring_stats() -> Dictionary:
	var count: int = _f._cell_count
	if _f._temp.size() != count or _f._water.size() != count or _f._solid.size() != count:
		return {"hotspring_cells": 0, "hotspring_boiling": 0, "hotspring_max_c": 0.0}
	var warm: int = 0        # open, non-sea surface water >60°C (a hot spring)
	var boiling: int = 0     # at/over LAPhysical.WATER_BOIL_C — the same point atmos_evap flashes steam at
	var mild: int = 0        # >30°C with any discharge film (early/faint geothermal signal)
	var spring_wet: int = 0  # open non-sea cells holding ANY discharge film (denominator for the warm fraction)
	var mx: float = 0.0      # hottest open non-sea surface-water cell (the true spring peak, no threshold)
	for i in range(count):
		if _f._solid[i] != 0 or _f._static[i] != 0:
			continue
		if _f._water[i] < 0.01:
			continue
		spring_wet += 1
		var t: float = _f._temp[i]
		if t > mx:
			mx = t
		if t > 30.0:
			mild += 1
		if t > 60.0:
			warm += 1
		if t >= LAPhysical.WATER_BOIL_C:
			boiling += 1
	return {
		"hotspring_cells": warm, "hotspring_boiling": boiling, "hotspring_max_c": snappedf(mx, 0.1),
		"hotspring_mild": mild, "hotspring_wet": spring_wet,
	}


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

## Radial vorticity (the SPIN of the air about the local "up") at a world point. The kernel stores velocity in
## a per-cell TANGENT frame (vel_x along tan_a, vel_z along tan_b, vel_y radial), and adjacent cells do NOT
## share that frame — the frame is face-local and discontinuous at the seams. A curl differences NEIGHBOUR
## velocities, so each neighbour's pair must first be rotated into THIS cell's frame (`rotate_into_neighbour`
## on the neighbour's reverse link) before it means anything. Then the radial curl is the sum over the four
## lateral links of 0.5 * cross2(link direction, that neighbour's velocity), which in a face interior is
## exactly the old d(vel_z)/d(tan_a) − d(vel_x)/d(tan_b) central difference. Sampled a couple of cells aloft
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
	var grid: LASphereGrid = _f._sphere
	var nbr: PackedInt32Array = grid.neighbours
	var curl: float = 0.0
	for l in 4:
		var m: int = nbr[c * 6 + 2 + l]
		if m < 0:
			continue
		var v: Vector2 = grid.rotate_into_neighbour(m, l ^ 1, Vector2(_f._vel_x[m], _f._vel_z[m]))
		var d: Vector2 = grid.link_dir(c, l)
		curl += 0.5 * (d.x * v.y - d.y * v.x)
	return curl


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
# The kernel stores velocity in a per-cell TANGENT FRAME: vel_x along LASphereGrid.tan_a, vel_z along tan_b,
# vel_y along the OUTWARD RADIAL. wind3_at reconstructs a true WORLD-space velocity from that frame so loose
# mass (creatures/debris/sediment) can be advected/flung by it. Two table lookups — O(1), no grid sweep.
#
# CORRECTED 2026-07-30. This used to rebuild the axes from neighbour POSITIONS — `tan_a = pos(nbr[c*6+2]) -
# pos(nbr[c*6+1])` — which was wrong twice over. First, `neighbours` is the INTERNAL table, ordered
# [IN, OUT, A0, A1, B0, B1], not the kernel packing [in, -a, +a, -b, +b, out] those indices assumed, so slot 1
# was the OUTWARD RADIAL neighbour and "tangent A" was built from a lateral minus a radial cell. Second, even
# with the right indices the slot-pair axis is not the frame the kernel stores momentum in: the pairing is a
# 2-factorisation chosen for reciprocity, and its orientation flips between cycles. The frame has its own
# table now, and this reads it.

## Full LOCAL 3D wind velocity (world-space) at a world point. Vector3.ZERO outside the shell / before readback.
func wind3_at(x: float, y: float, z: float) -> Vector3:
	if _f._sphere == null or _f._vel_x.size() != _f._cell_count:
		return Vector3.ZERO
	var c: int = _f.world_to_cell(Vector3(x, y, z))
	if c < 0 or c >= _f._cell_count:
		return Vector3.ZERO
	var grid: LASphereGrid = _f._sphere
	return (_f.cell_radial(c) * _f._vel_y[c]
			+ grid.tangent_a(c) * _f._vel_x[c]
			+ grid.tangent_b(c) * _f._vel_z[c])


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
	var grid: LASphereGrid = _f._sphere
	var c: int = 0
	while c < _f._cell_count:
		if _f._solid[c] == 0:
			var v: Vector3 = grid.tangent_a(c) * _f._vel_x[c] + grid.tangent_b(c) * _f._vel_z[c]
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

## Loose granular regolith (talus/dune sediment) — the "loose" mineral phase. Summed over ALL cells (not just
## open): lithification (D2) and solidify can turn a sediment-bearing cell to bedrock with residual sediment
## still in it, and the slump kernel FREEZES a solidified cell's sediment in place — counting only open cells
## would then LEAK that trapped mass out of the ledger. Sediment is 0 in solid cells at seed, so summing all
## cells equals the old open-only sum until a cell traps some, which is exactly the mass conservation must keep.
func sediment_total() -> float:
	if _f._sediment.size() != _f._cell_count:
		return 0.0
	var sum: float = 0.0
	for c in _f._cell_count:
		sum += _f._sediment[c]
	return sum

## Airborne wind-lofted dust — the "airborne" mineral phase. Summed over ALL cells, like the other four legs.
##
## MASK UNIFIED 2026-08-03. This was the ONE leg of `mineral_total()` that gated on `_f._solid[c] == 0`, so the
## five-leg sum was assembled from two different populations and was not a conserved quantity at all. The
## decisive argument is that `solid` IS `rock_fill`: LASolidDerivePass re-derives the flag from rock_fill >= 0.5
## every step, so masking a mineral leg on solidity makes the ledger's own membership a function of the very
## quantity it measures — a cell crossing 0.5 would move dust in or out of the books with no transfer having
## happened. See LAMaterialFieldMineralBudget3D's header for the full rule.
##
## dust_transport_sphere3d.glsl clears a solid cell's dust each step, so on the DEVICE mask `dust_all` and
## `dust_open` differ only by what crossed the threshold within one step. On the CPU mirror the gap is much
## larger (`_f._solid` is written only by the solidity sample and MineralStamp's scan, while the device re-derives
## it every step): measured 221.62 all-cells against 163.67 open-cells on one --planet-only run, i.e. the old
## open-only mask would still have dropped 58 units even with a live mirror. That clear used to DELETE the
## mass; it now hands it to `sediment` (a conserving transfer between two counted legs), which is what makes
## the mask-free sum honest rather than merely consistent.
func dust_total() -> float:
	if _f._dust.size() != _f._cell_count:
		return 0.0
	var sum: float = 0.0
	for c in _f._cell_count:
		sum += _f._dust[c]
	return sum

## Mean airborne dust across the grid — a 0..~ opacity proxy for how much debris in the air blocks the sun
## (a meteor volley lofts dust → this rises → insolation drops → impact winter). Cheap O(1)-amortised via dust_total.
##
## THIS IS THE WHOLE IMPACT-WINTER MECHANISM (LASystemOrbits._compute_transmission) AND IT READ A DEAD MIRROR
## UNTIL 2026-08-03. `dust` is a SITUATIONAL_CHANNEL: it is only read back from the GPU while something has
## called `request_channel("dust")`, and the only caller was the crater path, which fires on a strike and goes
## cold 20 drains later. So `_f._dust` held the all-zero allocation for essentially every frame of every run,
## `dust_total()` returned 0.00, transmission stayed pinned at 1.0, and no volley could ever dim the sun.
##
## SO THE CONSUMER REQUESTS ITS OWN CHANNEL, HERE. *(Corrected 2026-08-03. This said
## "LAMaterialFieldMineralBudget3D now requests the channel on every report sample … which is what makes this
## live", and that was the defect, not the fix: it made a PHYSICAL mechanism depend on whether a DIAGNOSTIC was
## running. Turning the ledger off — or moving it behind an env gate, as was proposed — would have silently
## switched impact winter back off. A gauge must never be load-bearing for physics.)* `_compute_transmission`
## polls this every 15 process frames and CHANNEL_HOLD_DRAINS is 20, so one request per poll keeps the mirror
## permanently live on its own account.
##
## Measured 2026-08-03, `--planet-only --run-frames=600 --fast=8 --seed=4242 --fixed-fps 60`: `dust_total`
## 0.00 with a dead mirror against 181-217 with a live one, and `atmos_transmission` 0.925-0.927 against
## 0.915-0.919. The dimming is small on a quiet planet — mean dust ~0.0031 against `DUST_OPACITY` 3.5 is ~1%
## opacity — but it is the difference between a mechanism that can fire and one wired to a constant zero.
func avg_atmos_dust() -> float:
	if _f._cell_count <= 0:
		return 0.0
	# Impact winter is a real consumer of the dust mirror, so it keeps its own channel hot. Without this the
	# only steady requester was the mineral ledger, i.e. a diagnostic.
	if _f._gpu != null and _f._gpu.has_method("request_channel"):
		_f._gpu.request_channel("dust")
	return dust_total() / float(_f._cell_count)


# `dust_cell_count()` was REMOVED here on 2026-08-03, and this note is the stated reason the "unwired code is an
# unfinished job" rule asks for: it was SUPERSEDED, not merely unreferenced. It walked the whole grid counting
# cells over `DUST_PRESENT`, and SIM_REPORT's `dust_cells` now comes from `dusty_cells` in
# LAMaterialFieldMineralBudget3D, which counts them with the same threshold inside the single pass it already
# makes over the dust channel. Wiring the old one back in would add an eleventh O(cells) walk to produce a
# number the ledger has already produced. Reference count before removal, both forms (identifier and `res://`
# path, across .gd/.tscn/.tres/.cfg): one caller, the `LAMaterialField3D.dust_cell_count()` forwarder, which
# went with it, and which was itself a `return 0` stub until this line of work.


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

## Waterborne SUSPENDED sediment over open cells — the "suspended" mineral phase. LIVE as of Stage D: erosion
## pickup scours bedrock into it and M3 SETTLE drops it back to loose sediment, so it now carries real transient
## mass mid-transport and MUST be counted or the ledger under-reports (rock_fill dropped, susp uncounted).
func susp_total() -> float:
	if _f._susp.size() != _f._cell_count:
		return 0.0
	var sum: float = 0.0
	for c in _f._cell_count:
		sum += _f._susp[c]
	return sum

## The ONE mineral total: Σ bedrock(rock_fill) + molten(lava) + loose(sediment) + suspended(susp) + airborne(dust),
## every leg over EVERY cell (the unified inclusion rule — see dust_total above and
## LAMaterialFieldMineralBudget3D's header). Must stay BOUNDED net of the vent's declared mantle source — this
## is the unification's proof object. Every phase transfer (scour rock→susp, settle susp→sediment, slump,
## weather rock→sediment, lithify sediment→rock, M5/M6 lava↔rock) moves mass between two counted legs.
##
## COST NOTE: five separate O(cells) walks. Kept because one caller still reaches for an individual getter —
## `LAEventTracker.gd:156` calls `lava_total()`. *(Corrected 2026-08-03: this said "LAEventTracker and the save
## controller reach for the individual getters". The save controller does not, and neither does
## `VoxelInputController`, which reads `rock_fill_total`/`mineral_total` out of the SNAPSHOT dictionary.)*
## SIM_REPORT does NOT come through here any more — LAMaterialFieldMineralBudget3D
## computes all five legs plus both masks plus the drift in ONE pass, behind the report's heavy-cadence gate.
## Prefer that module for anything on a per-frame path.
func mineral_total() -> float:
	return rock_fill_total() + lava_total() + sediment_total() + dust_total() + susp_total()


# --- Combustion FUEL / FIRE diagnostics (read the seeded + GPU-consumed fuel channel and the fire channel) ----

## Total flammable fuel mass over every open cell — >0 once seeded; DROPS as a fire burns it to ash, recovers
## as biomass regrows it (the fuel seed module's refill). The spot check that combustion has fuel to ignite.
func fuel_total() -> float:
	if _f._fuel.size() != _f._cell_count:
		return 0.0
	var sum: float = 0.0
	for c in _f._cell_count:
		if _f._solid[c] == 0:
			sum += _f._fuel[c]
	return sum

## Peak burning intensity over the field (0 = nothing on fire; up to ~1 for a raging cell). >0 proves ignition.
func fire_peak() -> float:
	if _f._fire.size() != _f._cell_count:
		return 0.0
	var m: float = 0.0
	for c in _f._cell_count:
		if _f._fire[c] > m:
			m = _f._fire[c]
	return m

## Count of cells currently burning (fire intensity over the kernel's FIRE_MIN ignition floor).
func fire_cells() -> int:
	if _f._fire.size() != _f._cell_count:
		return 0
	var n: int = 0
	for c in _f._cell_count:
		if _f._fire[c] > 0.02:
			n += 1
	return n


# --- LAVA-TUBE / HOLLOW signature -------------------------------------------
# A lava tube is an OPEN cell (rock_fill < 0.5 ⇒ derived-solid == 0, and no molten lava sitting in it — it has
# DRAINED) that is walled in by SOLID rock on most of its faces. Count them: an emergent tube/hollow interior
# shows up as a nonzero population of "open cell with ≥ min_solid_nbr solid neighbours". With uniform own-cell
# cooling a stalled flow freezes into a SOLID PLUG (no enclosed voids, ≈ 0); with shell-first edge-cooling the
# rind solidifies around a still-molten core that then drains → a hollow remains → this count rises. Pure O(cells)
# snapshot read (polled at report time only), no grid sweep per frame.
const TUBE_LAVA_NEAR_ZERO: float = 0.05

func enclosed_void_cells(min_solid_nbr: int = 4) -> int:
	if _f._sphere == null or _f._solid.size() != _f._cell_count or _f._lava.size() != _f._cell_count:
		return 0
	var nbr: PackedInt32Array = _f._sphere.neighbours
	if nbr.size() != _f._cell_count * 6:
		return 0
	var n: int = 0
	for c in range(_f._cell_count):
		if _f._solid[c] != 0:
			continue                                    # cell itself must be OPEN (rock_fill < 0.5)
		if _f._lava[c] >= TUBE_LAVA_NEAR_ZERO:
			continue                                    # still lava-filled — not yet a drained hollow
		var base: int = c * 6
		var sn: int = 0
		for d in range(6):
			var nb: int = nbr[base + d]
			if nb >= 0 and _f._solid[nb] != 0:
				sn += 1
		if sn >= min_solid_nbr:
			n += 1
	return n


# --- Soil FERTILITY (decomposer output: detritus → fungus → CO₂ + fertility) — read the GPU fert channel -------

## Soil nutrient density at a world point (plants grow faster on rich ground). 0 outside the shell / before readback.
func fertility_at(pos: Vector3) -> float:
	if _f._fert.size() != _f._cell_count:
		return 0.0
	var c: int = _f.world_to_cell(pos)
	return _f._fert[c] if c >= 0 else 0.0

## Peak soil fertility over every open cell — >0 once the decomposer loop deposits nutrient (was hardcoded 0).
func fertility_peak() -> float:
	if _f._fert.size() != _f._cell_count:
		return 0.0
	var m: float = 0.0
	for c in _f._cell_count:
		if _f._solid[c] == 0 and _f._fert[c] > m:
			m = _f._fert[c]
	return m


# --- SEA ICE — emergent frozen sea surface (polar caps / winter sea ice) --------------------------------------
# A "sea-surface" cell is a static-sea cell (`_static==1`, so it is the calm seeded ocean, not a perched lake or
# dynamic river) whose OUTWARD radial neighbour (c+1 in the contiguous column c = s*depth + r) is NOT static —
# i.e. the topmost sea layer, the air/water interface where sea ice forms. Sea ice is just the `_snow` (frozen
# H₂O) channel accumulated on that cell by the freeze reaction — no separate buffer. These getters split the
# frozen vs open sea so SIM_REPORT proves caps are EMERGENT (cold poles freeze, warm tropics stay open), not
# global. Sphere-only (needs the contiguous radial column layout); returns 0 in box mode.

## True if linear cell `c` is the topmost layer of the static sea (the freezable sea surface).
func _is_sea_surface(c: int, depth: int) -> bool:
	if _f._static[c] == 0 or _f._solid[c] != 0:
		return false
	var r: int = c % depth
	if r == depth - 1:
		return true                                   # outermost shell — nothing above it
	return _f._static[c + 1] == 0                     # the cell just outward is air → this is the surface

## Count of sea-surface cells frozen over (snow/ice depth past SNOW_PRESENT) — the emergent sea-ice extent.
func sea_ice_cell_count() -> int:
	if not _f.is_sphere() or _f._dim_y <= 0 or _f._snow.size() != _f._cell_count:
		return 0
	var depth: int = _f._dim_y
	var n: int = 0
	for c in _f._cell_count:
		if _is_sea_surface(c, depth) and _f._snow[c] > _f.SNOW_PRESENT:
			n += 1
	return n

## Mean temperature of the FROZEN sea-surface cells — should read below the freeze threshold (proves cold-driven).
func sea_ice_temp_avg() -> float:
	if not _f.is_sphere() or _f._dim_y <= 0 or _f._snow.size() != _f._cell_count:
		return 0.0
	var depth: int = _f._dim_y
	var sum: float = 0.0
	var n: int = 0
	for c in _f._cell_count:
		if _is_sea_surface(c, depth) and _f._snow[c] > _f.SNOW_PRESENT:
			sum += _f._temp[c]
			n += 1
	return sum / float(n) if n > 0 else 0.0

## Mean temperature of the OPEN (unfrozen) sea-surface cells — should read ABOVE the frozen mean (warm sea stays
## liquid). Together with sea_ice_temp_avg this shows ice tracks temperature, not latitude. Excludes lava/geothermal
## anomalies (a handful of undersea-vent cells at hundreds of °C would otherwise swamp the mean).
const OPEN_SEA_TEMP_CAP: float = 100.0   # ignore boiling-hot vent cells — not representative open water
func open_sea_temp_avg() -> float:
	if not _f.is_sphere() or _f._dim_y <= 0 or _f._snow.size() != _f._cell_count:
		return 0.0
	var depth: int = _f._dim_y
	var sum: float = 0.0
	var n: int = 0
	for c in _f._cell_count:
		if _is_sea_surface(c, depth) and _f._snow[c] <= _f.SNOW_PRESENT and _f._temp[c] < OPEN_SEA_TEMP_CAP:
			sum += _f._temp[c]
			n += 1
	return sum / float(n) if n > 0 else 0.0
# Shell-first DIAGNOSTIC (proof the differential cooling fires). Classifies live lava cells (lava ≥ near-zero,
# temp ≥ solidus) as INTERIOR (0 exposed faces — every open neighbour is hot lava, or all neighbours solid) vs
# RIND (≥1 exposed face — borders open air/void or a cold cell), and reports how many of each plus their mean
# temperature. If the mechanism works, interior cells outnumber-or-outlast the rind and run HOTTER than rind
# cells (the rind sheds heat faster). Snapshot-time only.
func lava_shell_diag() -> Dictionary:
	if _f._sphere == null or _f._solid.size() != _f._cell_count or _f._lava.size() != _f._cell_count:
		return {"lava_live": 0, "lava_interior": 0, "lava_rind": 0, "lava_int_c": 0.0, "lava_rind_c": 0.0}
	var nbr: PackedInt32Array = _f._sphere.neighbours
	if nbr.size() != _f._cell_count * 6:
		return {"lava_live": 0, "lava_interior": 0, "lava_rind": 0, "lava_int_c": 0.0, "lava_rind_c": 0.0}
	var live: int = 0
	var interior: int = 0
	var rind: int = 0
	var int_sum: float = 0.0
	var rind_sum: float = 0.0
	var thick: int = 0            # lava cells carrying a substantial body (>= 0.5 mass) — the tube prerequisite
	var maxmass: float = 0.0      # peak per-cell lava mass anywhere (how deep does the flow ever get?)
	for c in range(_f._cell_count):
		var lv: float = _f._lava[c]
		if lv > maxmass and _f._solid[c] == 0:
			maxmass = lv
		if _f._solid[c] != 0 or lv < 0.001 or _f._temp[c] < 800.0:
			continue
		if lv >= 0.5:
			thick += 1
		live += 1
		var base: int = c * 6
		var exposed: int = 0
		for d in range(6):
			var nb: int = nbr[base + d]
			if nb < 0:
				exposed += 1
				continue
			if _f._solid[nb] != 0:
				continue
			if _f._lava[nb] < TUBE_LAVA_NEAR_ZERO or _f._temp[nb] < 800.0:
				exposed += 1
		if exposed == 0:
			interior += 1
			int_sum += _f._temp[c]
		else:
			rind += 1
			rind_sum += _f._temp[c]
	return {
		"lava_live": live, "lava_interior": interior, "lava_rind": rind,
		"lava_thick": thick, "lava_maxmass": snappedf(maxmass, 0.001),
		"lava_int_c": snappedf(int_sum / float(max(1, interior)), 0.1),
		"lava_rind_c": snappedf(rind_sum / float(max(1, rind)), 0.1),
	}
