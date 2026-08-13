class_name LAMaterialFieldQueries3D
extends RefCounted

const CellVolScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCellVolume3D.gd")

## LAMaterialFieldQueries3D: the READ-ONLY query accessors of the dense 3D MaterialField3D, factored

# Basin depth (world units) mapped to a 0..1 salinity band. NOT a simulated solute.
const MOLTEN_MIN: float = 0.0001       # gauge floor: molten mineral volume fraction per cell
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


# --- Water queries -----------------------------------------------------------

## True where there is drinkable water at a world point. False outside the box / before readback.
## LIQUID water in a cell, in channel units: the h2o it holds times the share the ladder says is liquid.
func liquid_at(c: int) -> float:
	if c < 0 or _f._h2o.size() != _f._cell_count or _f._h2o_liquid.size() != _f._cell_count:
		return 0.0
	return maxf(_f._h2o[c], 0.0) * clampf(_f._h2o_liquid[c], 0.0, 1.0)


## FROZEN water in a cell, same units.
func ice_at(c: int) -> float:
	if c < 0 or _f._h2o.size() != _f._cell_count or _f._h2o_solid.size() != _f._cell_count:
		return 0.0
	return maxf(_f._h2o[c], 0.0) * clampf(_f._h2o_solid[c], 0.0, 1.0)


## WATER VAPOUR in a cell, same units.
func vapour_at(c: int) -> float:
	if c < 0 or _f._h2o.size() != _f._cell_count or _f._h2o_vapour.size() != _f._cell_count:
		return 0.0
	return maxf(_f._h2o[c], 0.0) * clampf(_f._h2o_vapour[c], 0.0, 1.0)


func is_water_at(pos: Vector3) -> bool:
	if _f._h2o.size() != _f._cell_count:
		return false
	var c: int = _f.world_to_cell(pos)
	return c >= 0 and liquid_at(c) >= _f.MIN_MASS


func water_at_cell(ix: int, iy: int, iz: int) -> float:
	if not _f._in_bounds(ix, iy, iz):
		return 0.0
	return liquid_at(_f._idx(ix, iy, iz))


# --- Water CURRENT (the sweep force) -----------------------------------------
# Tuning for the shallow-water drag that moving water exerts on anything standing in it.


func total_water() -> float:
	return CellVolScript.weighted(_liquid_mirror(), CellVolScript.of(_f), _f._solid, false)


# --- Temperature query -------------------------------------------------------

## Temperature °C at a world point (a mild default outside the shell). Sphere-native single 3D read.
func temp_at(pos: Vector3) -> float:
	if _f._temp.size() != _f._cell_count:
		return _f.INITIAL_TEMP
	var c: int = _f.world_to_cell(pos)
	return _f._temp[c] if c >= 0 else _f.INITIAL_TEMP


# --- Ocean / salinity --------------------------------------------------------

# --- Diagnostics -------------------------------------------------------------

## Radial bins the rock temperature profile is reduced into, between the centre and the outermost rock.
const PROFILE_BINS: int = 16


## Mean rock temperature against distance from the body centre, plus the SKIN: the outermost rock cell of
## every column, found by asking which cells have open air one step up the local vertical.
func rock_radial_profile() -> Dictionary:
	if _f._grid == null or _f._temp.size() != _f._cell_count or _f._solid.size() != _f._cell_count:
		return {}
	var outer: float = 0.0
	for c in _f._cell_count:
		if _f._solid[c] != 0:
			outer = maxf(outer, LAFieldGeometry.radius_of(_f, c))
	if outer <= 0.0:
		return {}
	var bin_sum: PackedFloat32Array = PackedFloat32Array()
	var bin_n: PackedInt32Array = PackedInt32Array()
	bin_sum.resize(PROFILE_BINS)
	bin_n.resize(PROFILE_BINS)
	var skin_sum: float = 0.0
	var skin_n: int = 0
	for c in _f._cell_count:
		if _f._solid[c] == 0:
			continue
		var b: int = clampi(int(LAFieldGeometry.radius_of(_f, c) / outer * float(PROFILE_BINS)), 0, PROFILE_BINS - 1)
		bin_sum[b] += _f._temp[c]
		bin_n[b] += 1
		var hi: int = LAFieldGeometry.above(_f, c)
		if hi >= 0 and _f._solid[hi] == 0:
			skin_sum += _f._temp[c]
			skin_n += 1
	return {
		"rock_core_c": _bin_mean(bin_sum, bin_n, 0),
		"rock_q25_c": _bin_mean(bin_sum, bin_n, PROFILE_BINS / 4),
		"rock_mid_c": _bin_mean(bin_sum, bin_n, PROFILE_BINS / 2),
		"rock_q75_c": _bin_mean(bin_sum, bin_n, PROFILE_BINS * 3 / 4),
		"rock_surf_c": _bin_mean(bin_sum, bin_n, PROFILE_BINS - 1),
		"rock_skin_c": (skin_sum / float(skin_n)) if skin_n > 0 else 0.0,
		"rock_skin_cells": skin_n,
	}


func _bin_mean(bin_sum: PackedFloat32Array, bin_n: PackedInt32Array, b: int) -> float:
	if b < 0 or b >= bin_n.size() or bin_n[b] == 0:
		return 0.0
	return bin_sum[b] / float(bin_n[b])


func hot_spring_stats() -> Dictionary:
	var count: int = _f._cell_count
	if _f._temp.size() != count or _f._h2o.size() != count or _f._solid.size() != count:
		return {"hotspring_cells": 0, "hotspring_boiling": 0, "hotspring_max_c": 0.0}
	var warm: int = 0        # open, non-sea surface water >60°C (a hot spring)
	var boiling: int = 0     # at/over LAPhysical.WATER_BOIL_C — the same point atmos_evap flashes steam at
	var mild: int = 0        # >30°C with any discharge film (early/faint geothermal signal)
	var spring_wet: int = 0  # open non-sea cells holding ANY discharge film (denominator for the warm fraction)
	var mx: float = 0.0      # hottest open non-sea surface-water cell (the true spring peak, no threshold)
	for i in range(count):
		if _f._solid[i] != 0:
			continue
		if liquid_at(i) < 0.01:
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
		if _f._solid[i] == 0 and liquid_at(i) >= _f.RENDER_MIN:
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

## Cells above a point the vortex is measured at — a storm's rotation is aloft, not in the ground layer.
const ALOFT_CELLS: float = 2.0
## Metres above a point the convective updraft is measured at: the cloud base, not the surface layer.
const UPDRAFT_SAMPLE_M: float = 40.0


## Air SPIN about the LOCAL VERTICAL at a world point, 1/s. The vertical is -down, read from gravity; the
## spin is the curl of the velocity field projected onto it.
func vorticity_at(pos: Vector3) -> float:
	if _f._grid == null or _f._vel_x.size() != _f._cell_count:
		return 0.0
	var c: int = _f.world_to_cell(pos)
	if c < 0:
		return 0.0
	var up: Vector3 = LAFieldGeometry.up(_f, c)
	if up == Vector3.ZERO:
		return 0.0
	var aloft: int = _f.world_to_cell(pos + up * (ALOFT_CELLS * _f._cell_size))
	if aloft < 0:
		return 0.0
	return LAFieldGeometry.curl(_f, aloft).dot(LAFieldGeometry.up(_f, aloft))


## Convective lift a little above a world point — the velocity component along the local vertical, m/s.
func updraft_at(pos: Vector3) -> float:
	if _f._grid == null or _f._vel_y.size() != _f._cell_count:
		return 0.0
	var c: int = _f.world_to_cell(pos)
	if c < 0:
		return 0.0
	var up: Vector3 = LAFieldGeometry.up(_f, c)
	if up == Vector3.ZERO:
		return 0.0
	var aloft: int = _f.world_to_cell(pos + up * UPDRAFT_SAMPLE_M)
	if aloft < 0:
		return 0.0
	return LAFieldGeometry.velocity(_f, aloft).dot(LAFieldGeometry.up(_f, aloft))


## Dynamic pressure the moving WATER exerts at a world point, in pascals, along the flow. q = rho v^2 / 2 --
## the pressure a flow puts on anything it meets, so a caller multiplies by its own frontal area. Zero
## where there is no water: a force needs matter to carry it.
func water_force_at(pos: Vector3) -> Vector3:
	if _f._grid == null or _f._h2o.size() != _f._cell_count or _f._vel_x.size() != _f._cell_count:
		return Vector3.ZERO
	var c: int = _f.world_to_cell(pos)
	if c < 0 or liquid_at(c) <= 0.0:
		return Vector3.ZERO
	var v: Vector3 = LAFieldGeometry.velocity(_f, c)
	var speed: float = v.length()
	if speed <= 0.0:
		return Vector3.ZERO
	var rho: float = float(LASubstances.table().get("h2o", {}).get("density", 0.0)) * liquid_at(c)
	return v.normalized() * (0.5 * rho * speed * speed)


# --- Emergent WIND as a real momentum/force (read back from the GPU velocity field) ------------------

## Full 3D wind velocity at a world point, m/s. The velocity channels are the grid's own axes, so there is
## no basis to rotate through. Vector3.ZERO outside the box / before readback.
func wind3_at(x: float, y: float, z: float) -> Vector3:
	if _f._grid == null or _f._vel_x.size() != _f._cell_count:
		return Vector3.ZERO
	var c: int = _f.world_to_cell(Vector3(x, y, z))
	if c < 0:
		return Vector3.ZERO
	return LAFieldGeometry.velocity(_f, c)


## LOCAL horizontal wind at a world point, as world XZ — the tangential drift a storm cell rides. Sampled
## where the storm actually is, which is the only place its steering wind means anything.
func wind_at(world_pos: Vector3) -> Vector2:
	var v: Vector3 = wind3_at(world_pos.x, world_pos.y, world_pos.z)
	return Vector2(v.x, v.z)


## Domain-average horizontal wind magnitude/direction (ocean swell / HUD). Strided sample (every STRIDE-th
## cell) so it stays O(cells/STRIDE), never a full per-call grid sweep.
func wind() -> Vector2:
	if _f._grid == null or _f._vel_x.size() != _f._cell_count:
		return Vector2.ZERO
	const STRIDE: int = 97
	var sx: float = 0.0
	var sz: float = 0.0
	var n: int = 0
	var c: int = 0
	while c < _f._cell_count:
		if _f._solid[c] == 0:
			sx += _f._vel_x[c]
			sz += _f._vel_z[c]
			n += 1
		c += STRIDE
	if n == 0:
		return Vector2.ZERO
	return Vector2(sx / float(n), sz / float(n))


# --- MINERAL: airborne opacity + the molten state. Totals live in LAMaterialFieldLedger3D. -------------

## Volume fraction of the cell that is wind-borne mineral: the amount times its derived airborne share.
func airborne_at(c: int) -> float:
	if c < 0 or _f._silicate.size() != _f._cell_count \
			or _f._silicate_susp_air.size() != _f._cell_count:
		return 0.0
	return maxf(_f._silicate[c], 0.0) * clampf(_f._silicate_susp_air[c], 0.0, 1.0)


## Volume fraction of the cell that is molten mineral.
func melt_at(c: int) -> float:
	if c < 0 or _f._silicate.size() != _f._cell_count \
			or _f._silicate_melt.size() != _f._cell_count:
		return 0.0
	return maxf(_f._silicate[c], 0.0) * clampf(_f._silicate_melt[c], 0.0, 1.0)


## Volume-mean airborne mineral — the opacity LASystemOrbits turns into insolation.
func avg_airborne_mineral() -> float:
	if _f._cell_count <= 0:
		return 0.0
	var vol: PackedFloat32Array = CellVolScript.of(_f)
	if vol.size() != _f._cell_count or _f._silicate_susp_air.size() != _f._cell_count:
		return 0.0
	var amount: float = 0.0
	var span: float = 0.0
	for c in _f._cell_count:
		var w: float = vol[c]
		amount += airborne_at(c) * w
		span += w
	return amount / span if span > 0.0 else 0.0


## Molten mineral over ALL cells — mask-free: melt lingers the instant a cell crosses to derived-solid, so
## an open-only sum would drop matter that physically exists.
func melt_total() -> float:
	return CellVolScript.weighted(_melt_mirror(), CellVolScript.of(_f), _f._solid, false)


## Per-cell molten volume fraction, as an array. Empty when either input mirror is absent.
func _melt_mirror() -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	if _f._silicate.size() != _f._cell_count or _f._silicate_melt.size() != _f._cell_count:
		return out
	out.resize(_f._cell_count)
	for c in _f._cell_count:
		out[c] = melt_at(c)
	return out


## magma_cells / lava_cells, plus `molten_live`: whether the silicate readback landed on the last drain.
## Without it a zero here cannot be told from a channel that never arrived.
func molten_counts() -> Dictionary:
	var step: int = _f._gpu._step_index if _f._gpu != null else -1
	if step >= 0 and step == _molten_step:
		return {"magma_cells": _molten_magma, "lava_cells": _molten_lava, "molten_live": _molten_live}
	_molten_magma = 0
	_molten_lava = 0
	_molten_step = step
	_molten_live = _mirror_live("silicate") and _f._silicate_melt.size() == _f._cell_count
	if not _molten_live or _f._solid.size() != _f._cell_count:
		return {"magma_cells": 0, "lava_cells": 0, "molten_live": _molten_live}
	for c in _f._cell_count:
		if melt_at(c) < MOLTEN_MIN:
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

## Derived-solid (bedrock) cell count — a display/diagnostic. NOT the mineral mass baseline: that is the
## `silicate` amount, whose total is silicate_total.
func rock_cells() -> int:
	var n: int = 0
	for c in _f._cell_count:
		if _f._solid[c] != 0:
			n += 1
	return n


# --- Combustion FIRE diagnostics. Fuel totals live in LAMaterialFieldLedger3D. ------------------------

## Peak intensity, burning-cell count, and whether the demand-gated `fire` readback landed on the last drain.
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
const TUBE_MELT_NEAR_ZERO: float = 0.05

## Open cells walled in by rock and NOT still melt-filled — a drained tube. Reads the melt share, so it
## when that channel did not arrive; `molten_live` in the same report says which zero this is.
func enclosed_void_cells(min_solid_nbr: int = 4) -> int:
	if not _mirror_live("silicate"):
		return 0
	if _f._grid == null or _f._solid.size() != _f._cell_count \
			or _f._silicate_melt.size() != _f._cell_count:
		return 0
	var nbr: PackedInt32Array = _f._grid.neighbours
	if nbr.size() != _f._cell_count * 6:
		return 0
	var n: int = 0
	for c in range(_f._cell_count):
		if _f._solid[c] != 0:
			continue                                    # cell itself must be OPEN
		if melt_at(c) >= TUBE_MELT_NEAR_ZERO:
			continue                                    # still melt-filled — not yet a drained hollow
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

## True when cell `c` holds water and the cell one step UP the local vertical is open and DRY — the free
## water surface, where ice forms. The dryness above is what makes it a surface, not a mid-column cell.
func _is_sea_surface(c: int) -> bool:
	if _f._solid[c] != 0 or liquid_at(c) < _f.MIN_MASS:
		return false
	var hi: int = LAFieldGeometry.above(_f, c)
	if hi < 0:
		return true                                   # the march left the box — open sky above
	return _f._solid[hi] == 0 and liquid_at(hi) < _f.MIN_MASS

## Frozen extent and the MEDIAN temperature of the frozen and open halves of the sea surface, in one walk.
## Median, not mean: a handful of undersea-vent cells at hundreds of °C moves a mean and cannot move a
## median, so no cell has to be excluded to keep the number readable.
func sea_surface_stats() -> Dictionary:
	var out: Dictionary = {"sea_ice_cells": 0, "sea_ice_temp": 0.0, "open_sea_cells": 0, "open_sea_temp": 0.0}
	if _f._grid == null:
		return out
	if _f._h2o.size() != _f._cell_count or _f._temp.size() != _f._cell_count:
		return out
	var frozen: PackedFloat32Array = PackedFloat32Array()
	var open: PackedFloat32Array = PackedFloat32Array()
	for c in _f._cell_count:
		if not _is_sea_surface(c):
			continue
		if ice_at(c) > _f.SNOW_PRESENT:
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


## Melt body/rind split. Reads the silicate mirror, so it returns zeros when it did not arrive;
## in the same report says which zero this is.
func lava_shell_diag() -> Dictionary:
	if not _mirror_live("silicate") or _f._silicate_melt.size() != _f._cell_count:
		return {"lava_hot": 0, "lava_interior": 0, "lava_rind": 0, "lava_int_c": 0.0, "lava_rind_c": 0.0}
	if _f._grid == null or _f._solid.size() != _f._cell_count:
		return {"lava_hot": 0, "lava_interior": 0, "lava_rind": 0, "lava_int_c": 0.0, "lava_rind_c": 0.0}
	var nbr: PackedInt32Array = _f._grid.neighbours
	if nbr.size() != _f._cell_count * 6:
		return {"lava_hot": 0, "lava_interior": 0, "lava_rind": 0, "lava_int_c": 0.0, "lava_rind_c": 0.0}
	var hot: int = 0
	var interior: int = 0
	var rind: int = 0
	var int_sum: float = 0.0
	var rind_sum: float = 0.0
	var thick: int = 0            # melt cells over half a cell deep — the tube prerequisite
	var maxmass: float = 0.0      # peak per-cell molten volume fraction anywhere
	for c in range(_f._cell_count):
		var lv: float = melt_at(c)
		if lv > maxmass and _f._solid[c] == 0:
			maxmass = lv
		if _f._solid[c] != 0 or lv < 0.001 or _f._silicate_melt[c] <= 0.0:
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
			if melt_at(nb) < TUBE_MELT_NEAR_ZERO or _f._silicate_melt[nb] <= 0.0:
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


## The liquid share of every cell, as one array — for the volume-weighted sums that take a whole mirror.
func _liquid_mirror() -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	if _f._h2o.size() != _f._cell_count:
		return out
	out.resize(_f._cell_count)
	for c in _f._cell_count:
		out[c] = liquid_at(c)
	return out


## The vapour share of every cell, as one array — the airborne-substance readers take a whole mirror.
func _vapour_mirror() -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	if _f._h2o.size() != _f._cell_count:
		return out
	out.resize(_f._cell_count)
	for c in _f._cell_count:
		out[c] = vapour_at(c)
	return out


## The frozen share of every cell, as one array — the albedo and cover bakers take a whole mirror.
func _ice_mirror() -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	if _f._h2o.size() != _f._cell_count:
		return out
	out.resize(_f._cell_count)
	for c in _f._cell_count:
		out[c] = ice_at(c)
	return out
