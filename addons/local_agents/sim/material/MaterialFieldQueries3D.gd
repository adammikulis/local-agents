class_name LAMaterialFieldQueries3D
extends RefCounted

const CellVolScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCellVolume3D.gd")

## LAMaterialFieldQueries3D: the READ-ONLY query accessors of the dense 3D MaterialField3D, factored

# Basin depth (world units) mapped to a 0..1 salinity band. NOT a simulated solute.
const SALT_FULL_DEPTH: float = 22.0
const BRACKISH_FLOOR: float = 0.35
const DUST_PRESENT: float = 0.001      # gauge floor: airborne dust mass per cell
const MOLTEN_MIN: float = 0.0001       # gauge floor: lava mass per cell
const FIRE_PRESENT: float = 0.02       # gauge floor: fraction of a cell's usable O2 burned this step

var _f = null                                            # back-reference to the owning LAMaterialField3D

var _molten_step: int = -1
var _molten_magma: int = 0
var _molten_lava: int = 0
var _molten_live: bool = false
var _fire_step: int = -1
var _fire_max: float = 0.0
var _fire_count: int = 0
var _fire_live: bool = false


func setup(field) -> void:
	_f = field


## True when `name`'s readback landed on the most recent GPU drain, so the CPU mirror is current. A
## demand-gated channel (LAMaterialSphereGPU3D.SITUATIONAL_CHANNELS) is absent from any drain nobody asked
## for, and its mirror then holds a stale or never-written zero.
func _mirror_live(name: String) -> bool:
	if _f == null or _f._gpu == null:
		return false
	var got = _f._gpu._cached.get(name, null)
	return got is PackedFloat32Array and got.size() == _f._cell_count


# --- Cell resolver (world -> linear cell) ------------------------------------
func _cell_at(pos: Vector3) -> int:
	return _f.world_to_cell(pos)


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
	return CellVolScript.weighted(_f._water, CellVolScript.of(_f), _f._solid, false)


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
		if _f._solid[i] != 0:
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
		if _f._solid[i] == 0 and _f._water[i] >= _f.RENDER_MIN:
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
## lift, not the ground layer. Single 3D sample; returns 0.0 outside the shell or before readback.
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


## LOCAL horizontal wind at a world point, as world XZ — the tangential drift a storm cell rides. Sampled
## where the storm actually is, which is the only place its steering wind means anything.
func wind_at(world_pos: Vector3) -> Vector2:
	var v: Vector3 = wind3_at(world_pos.x, world_pos.y, world_pos.z)
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


# --- MINERAL: airborne dust opacity + the molten phase ------------------------------------------------
# The mineral conservation totals (rock_fill/sediment/susp/dust/mineral) live in
# LAMaterialFieldMineralBudget3D — one probe-read pass, both masks, and the drift.

## Volume-mean airborne dust — the opacity LASystemOrbits turns into insolation. A PHYSICAL consumer of the
## dust mirror, not a gauge, so it keeps its own channel resident.
func avg_atmos_dust() -> float:
	if _f._cell_count <= 0:
		return 0.0
	if _f._gpu != null and _f._gpu.has_method("request_channel"):
		_f._gpu.request_channel("dust")
	var vol: PackedFloat32Array = CellVolScript.of(_f)
	if vol.size() != _f._cell_count or _f._dust.size() != _f._cell_count:
		return 0.0
	var mass: float = 0.0
	var span: float = 0.0
	for c in _f._cell_count:
		var w: float = vol[c]
		mass += _f._dust[c] * w
		span += w
	return mass / span if span > 0.0 else 0.0


## Molten rock (lava) over ALL cells — mask-free: add_lava injects into a still-solid vent, and lava lingers
## the instant a cell crosses to derived-solid, so an open-only sum would drop mass that physically exists.
func lava_total() -> float:
	return CellVolScript.weighted(_f._lava, CellVolScript.of(_f), _f._solid, false)


## magma_cells / lava_cells, plus `molten_live`: whether the demand-gated `lava` readback landed on the last
## drain. Without it a zero here cannot be told from a channel that never arrived.
func molten_counts() -> Dictionary:
	var step: int = _f._gpu._step_index if _f._gpu != null else -1
	if step >= 0 and step == _molten_step:
		return {"magma_cells": _molten_magma, "lava_cells": _molten_lava, "molten_live": _molten_live}
	_molten_magma = 0
	_molten_lava = 0
	_molten_step = step
	_molten_live = _mirror_live("lava")
	if not _molten_live or _f._lava.size() != _f._cell_count or _f._solid.size() != _f._cell_count:
		return {"magma_cells": 0, "lava_cells": 0, "molten_live": _molten_live}
	for c in _f._cell_count:
		if _f._lava[c] < MOLTEN_MIN:
			continue
		if _f._solid[c] != 0:
			_molten_magma += 1          # confined by rock — magma
		else:
			_molten_lava += 1           # out in the open — lava
	return {"magma_cells": _molten_magma, "lava_cells": _molten_lava, "molten_live": _molten_live}


## Cells holding melt that has NOT reached open ground — magma.
func magma_cell_count() -> int:
	return int(molten_counts()["magma_cells"])


## Cells holding melt that HAS reached open ground — lava.
func lava_cell_count() -> int:
	return int(molten_counts()["lava_cells"])


## Molten rock is standing in open cells, which is what an eruption IS. No timer, no burst state, no actor.
func magma_erupting() -> bool:
	return int(molten_counts()["lava_cells"]) > 0

## Derived-solid (bedrock) cell count — a display/diagnostic (cells whose derived solid flag is set). NOT the mineral
## mass baseline: bedrock is a FRACTIONAL channel (rock_fill), whose mass baseline is rock_fill_total().
func rock_cells() -> int:
	var n: int = 0
	for c in _f._cell_count:
		if _f._solid[c] != 0:
			n += 1
	return n


# --- Combustion FIRE diagnostics -----------------------------------------------------------------------
# The fuel totals live in LAMaterialFieldElementInventory3D: `fuel_all` mask-free, `fuel_open_total` masked.

## Peak burning intensity, burning-cell count, and `fire_live`: whether the demand-gated `fire` readback
## landed on the last drain. One walk, cached per field step.
func fire_stats() -> Dictionary:
	var step: int = _f._gpu._step_index if _f._gpu != null else -1
	if step >= 0 and step == _fire_step:
		return {"fire_peak": _fire_max, "fire_cells": _fire_count, "fire_live": _fire_live}
	_fire_step = step
	_fire_max = 0.0
	_fire_count = 0
	_fire_live = _mirror_live("fire")
	if not _fire_live or _f._fire.size() != _f._cell_count:
		return {"fire_peak": 0.0, "fire_cells": 0, "fire_live": _fire_live}
	for c in _f._cell_count:
		var v: float = _f._fire[c]
		if v > _fire_max:
			_fire_max = v
		if v > FIRE_PRESENT:
			_fire_count += 1
	return {"fire_peak": _fire_max, "fire_cells": _fire_count, "fire_live": _fire_live}


func fire_peak() -> float:
	return float(fire_stats()["fire_peak"])


func fire_cells() -> int:
	return int(fire_stats()["fire_cells"])


func is_burning(node) -> bool:
	if node == null or not _mirror_live("fire") or _f._fire.size() != _f._cell_count:
		return false
	var c: int = _f.world_to_cell(node.global_position)
	return c >= 0 and _f._fire[c] > FIRE_PRESENT


# --- LAVA-TUBE / HOLLOW signature -------------------------------------------
const TUBE_LAVA_NEAR_ZERO: float = 0.05

## Open cells walled in by rock and NOT still lava-filled — a drained tube. Reads `lava`, so it returns 0
## when that channel did not arrive; `molten_live` in the same report says which zero this is.
func enclosed_void_cells(min_solid_nbr: int = 4) -> int:
	if not _mirror_live("lava"):
		return 0
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

## Peak soil fertility over every open cell — above 0 once the decomposer loop deposits nutrient.
func fertility_peak() -> float:
	if _f._fert.size() != _f._cell_count:
		return 0.0
	var m: float = 0.0
	for c in _f._cell_count:
		if _f._solid[c] == 0 and _f._fert[c] > m:
			m = _f._fert[c]
	return m


# --- SEA SURFACE — the free water surface, frozen and open ---------------------------------------------

## True when cell `c` holds water and the cell just outward is open and dry — the free water surface, where
## ice forms. Testing `_solid[c + 1] == 0` alone admits every open cell not capped by rock: the whole ocean
## column and the whole atmosphere.
func _is_sea_surface(c: int, depth: int) -> bool:
	if _f._solid[c] != 0 or _f._water[c] < _f.MIN_MASS:
		return false
	var r: int = c % depth
	if r == depth - 1:
		return true                                   # outermost shell — open sky above
	return _f._solid[c + 1] == 0 and _f._water[c + 1] < _f.MIN_MASS

## Frozen extent and the MEDIAN temperature of the frozen and open halves of the sea surface, in one walk.
## Median, not mean: a handful of undersea-vent cells at hundreds of °C moves a mean and cannot move a
## median, so no cell has to be excluded to keep the number readable.
func sea_surface_stats() -> Dictionary:
	var out: Dictionary = {"sea_ice_cells": 0, "sea_ice_temp": 0.0, "open_sea_cells": 0, "open_sea_temp": 0.0}
	if not _f.is_sphere() or _f._dim_y <= 0:
		return out
	if _f._snow.size() != _f._cell_count or _f._temp.size() != _f._cell_count or _f._water.size() != _f._cell_count:
		return out
	var depth: int = _f._dim_y
	var frozen: PackedFloat32Array = PackedFloat32Array()
	var open: PackedFloat32Array = PackedFloat32Array()
	for c in _f._cell_count:
		if not _is_sea_surface(c, depth):
			continue
		if _f._snow[c] > _f.SNOW_PRESENT:
			frozen.append(_f._temp[c])
		else:
			open.append(_f._temp[c])
	out["sea_ice_cells"] = frozen.size()
	out["sea_ice_temp"] = _median(frozen)
	out["open_sea_cells"] = open.size()
	out["open_sea_temp"] = _median(open)
	return out


func _median(v: PackedFloat32Array) -> float:
	if v.is_empty():
		return 0.0
	v.sort()
	return snappedf(v[v.size() / 2], 0.1)


## Lava body/rind split. Reads `lava`, so it returns zeros when that channel did not arrive; `molten_live`
## in the same report says which zero this is.
func lava_shell_diag() -> Dictionary:
	if not _mirror_live("lava"):
		return {"lava_hot": 0, "lava_interior": 0, "lava_rind": 0, "lava_int_c": 0.0, "lava_rind_c": 0.0}
	if _f._sphere == null or _f._solid.size() != _f._cell_count or _f._lava.size() != _f._cell_count:
		return {"lava_hot": 0, "lava_interior": 0, "lava_rind": 0, "lava_int_c": 0.0, "lava_rind_c": 0.0}
	var nbr: PackedInt32Array = _f._sphere.neighbours
	if nbr.size() != _f._cell_count * 6:
		return {"lava_hot": 0, "lava_interior": 0, "lava_rind": 0, "lava_int_c": 0.0, "lava_rind_c": 0.0}
	var hot: int = 0
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
		if _f._solid[c] != 0 or lv < 0.001 or _f._temp[c] < LAPhysical.BASALT_SOLIDUS_C:
			continue
		if lv >= 0.5:
			thick += 1
		hot += 1
		var base: int = c * 6
		var exposed: int = 0
		for d in range(6):
			var nb: int = nbr[base + d]
			if nb < 0:
				exposed += 1
				continue
			if _f._solid[nb] != 0:
				continue
			if _f._lava[nb] < TUBE_LAVA_NEAR_ZERO or _f._temp[nb] < LAPhysical.BASALT_SOLIDUS_C:
				exposed += 1
		if exposed == 0:
			interior += 1
			int_sum += _f._temp[c]
		else:
			rind += 1
			rind_sum += _f._temp[c]
	return {
		"lava_hot": hot, "lava_interior": interior, "lava_rind": rind,
		"lava_thick": thick, "lava_maxmass": snappedf(maxmass, 0.001),
		"lava_int_c": snappedf(int_sum / float(max(1, interior)), 0.1),
		"lava_rind_c": snappedf(rind_sum / float(max(1, rind)), 0.1),
	}
