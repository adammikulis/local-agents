class_name LAMaterialFieldQueries3D
extends RefCounted

## LAMaterialFieldQueries3D: the READ-ONLY query accessors of the dense 3D MaterialField3D, factored

const MOLTEN_MIN: float = 0.0001       # gauge floor: molten mineral volume fraction per cell
const FIRE_PRESENT: float = 0.02       # gauge floor: fraction of a cell's usable O2 burned this step

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _reduce = null                                       # the field's own ReducePass, found once


func setup(field) -> void:
	_f = field


## The reduce pass's last drained rows. Empty before the first drain and when the GPU field is absent.
func reduced() -> Dictionary:
	if _f == null or _f._gpu == null:
		return {}
	if _reduce == null:
		var names: PackedStringArray = _f._gpu._pass_names
		for i in names.size():
			if names[i] == "ReducePass":
				_reduce = _f._gpu._passes[i]
				break
	return _reduce.latest() if _reduce != null else {}


## A reduced row, or NAN. Never 0.0: a total of zero and a total nobody measured differ.
func row_f(key: String) -> float:
	var r: Dictionary = reduced()
	return float(r[key]) if r.has(key) else NAN


## A reduced count, or -1. A count is never negative, so a caller cannot read the absence as an answer.
func row_n(key: String) -> int:
	var r: Dictionary = reduced()
	return int(round(float(r[key]))) if r.has(key) else -1


## A reduced count for a dictionary the report publishes, or null.
func row_v(key: String, as_count: bool):
	var r: Dictionary = reduced()
	if not r.has(key):
		return null
	return int(round(float(r[key]))) if as_count else float(r[key])


## True when `name`'s readback landed on the most recent GPU drain, so the CPU mirror is current. A
## demand-gated channel (LAMaterialSphereGPU3D.SITUATIONAL_CHANNELS) is absent from any drain nobody asked
## for, and its mirror then holds a stale or never-written zero.
func _mirror_live(name: String) -> bool:
	if _f == null or _f._gpu == null:
		return false
	var got = _f._gpu._cached.get(name, null)
	return got is PackedFloat32Array and got.size() == _f._cell_count


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


## Liquid h2o over every cell, mask-free, in the channel's own amount unit.
func total_water() -> float:
	return row_f("water_liquid_total")


# --- Temperature query -------------------------------------------------------

## Temperature °C at a world point (a mild default outside the shell). Sphere-native single 3D read.
func temp_at(pos: Vector3) -> float:
	if _f._temp.size() != _f._cell_count:
		return _f.INITIAL_TEMP
	var c: int = _f.world_to_cell(pos)
	return _f._temp[c] if c >= 0 else _f.INITIAL_TEMP


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


## Open cells holding surface water, how many of those are warm / boiling, and the hottest of them. The
## peak is gated on the cell holding water, so it is the hottest WATER rather than the hottest cell.
func hot_spring_stats() -> Dictionary:
	var mx = row_v("hotspring_max_c", false)
	return {
		"hotspring_cells": row_v("hotspring_cells", true),
		"hotspring_boiling": row_v("hotspring_boiling", true),
		"hotspring_max_c": snappedf(float(mx), 0.1) if mx != null else null,
		"hotspring_mild": row_v("hotspring_mild", true),
		"hotspring_wet": row_v("hotspring_wet", true),
	}


## The rock's own decay power, W, and the radial temperature gradient it is observed to produce, deg C per
## metre. The reduce rows hold a difference across one cell, so the cell edge is the divisor.
func geotherm_stats() -> Dictionary:
	var out: Dictionary = {"geo_radiogenic_w": null, "geo_grad_c_per_m": null,
		"geo_grad_max_c_per_m": null, "geo_grad_pairs": row_v("geo_grad_pairs", true)}
	var dt_s: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	var j = row_v("radiogenic", false)
	if j != null and dt_s > 0.0:
		out["geo_radiogenic_w"] = float(j) / dt_s
	var dx: float = float(_f._cell_size) if _f != null else 0.0
	if dx <= 0.0:
		return out
	var pairs = out["geo_grad_pairs"]
	var sum = row_v("geo_grad_sum", false)
	if pairs != null and int(pairs) > 0 and sum != null:
		out["geo_grad_c_per_m"] = float(sum) / (float(pairs) * dx)
	var mx = row_v("geo_grad_max", false)
	if mx != null:
		out["geo_grad_max_c_per_m"] = float(mx) / dx
	return out


func wet_cell_count() -> int:
	return row_n("wet_cells")


func peak_heat() -> float:
	return row_f("open_temp_max")


## Open cells at or over the one temperature the `hot_cells` row counts. There is one such row, so a caller
## naming a different threshold gets -1: the reduction did not measure it.
func hot_cell_count(threshold: float = 60.0) -> int:
	var declared: float = float(LAReduceRecords.row("hot_cells").get("threshold", NAN))
	if threshold != declared:
		push_error("hot_cell_count(%s): the hot_cells row counts at %s °C and the device reduced nothing "
			% [threshold, declared] + "else. Add a row or read the declared one.")
		return -1
	return row_n("hot_cells")


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


## Domain-mean horizontal wind over every open cell, as world XZ. Two reduced sums over the velocity
## channels; NAN when the reduction has not run, because a mean of nothing is not zero wind.
func wind() -> Vector2:
	var n: int = open_cells()
	if n <= 0:
		return Vector2(NAN, NAN)
	return Vector2(row_f("wind_x_sum") / float(n), row_f("wind_z_sum") / float(n))


## Cells the solid derive left open, from the same reduction. -1 when it has not run.
func open_cells() -> int:
	var solid: int = row_n("solid_cells")
	return _f._cell_count - solid if solid >= 0 else -1


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


## Mean airborne mineral over every cell — the opacity LASystemOrbits turns into insolation. The grid is
## uniform, so the volume weight cancels between the sum and the cell count and the mean is the bare one.
func avg_airborne_mineral() -> float:
	if _f._cell_count <= 0:
		return NAN
	return row_f("airborne_mineral_sum") / float(_f._cell_count)


## Molten mineral over ALL cells — mask-free: melt lingers the instant a cell crosses to derived-solid, so
## an open-only sum would drop matter that physically exists.
func melt_total() -> float:
	return row_f("melt_total")


## Open cells whose silicate times its water-suspended share is a real load in transit. The load that counts
## is declared once, as the suspended_cells row's threshold, so no caller can name a different one. -1 when
## the reduction has not run.
func suspended_cell_count() -> int:
	return row_n("suspended_cells")


## magma_cells / lava_cells, plus `molten_live`: whether the device reduced them at all. Without it a zero
## here cannot be told from a reduction that never ran.
func molten_counts() -> Dictionary:
	var r: Dictionary = reduced()
	return {
		"magma_cells": row_v("magma_cells", true),
		"lava_cells": row_v("lava_cells", true),
		"molten_live": r.has("magma_cells") and r.has("lava_cells"),
	}


## Cells holding melt that has NOT reached open ground — magma.
func magma_cell_count() -> int:
	return row_n("magma_cells")


## Cells holding melt that HAS reached open ground — lava.
func lava_cell_count() -> int:
	return row_n("lava_cells")


## Molten rock is standing in open cells, which is what an eruption IS. No timer, no burst state, no actor.
## False also when the row is absent; `molten_live` beside it in the same report says which false this is.
func magma_erupting() -> bool:
	return lava_cell_count() > 0


# --- Combustion FIRE diagnostics. Fuel totals live in LAMaterialFieldLedger3D. ------------------------

## Peak intensity, burning-cell count, and whether the device reduced them at all.
func fire_stats() -> Dictionary:
	var r: Dictionary = reduced()
	return {
		"fire_peak": row_v("fire_peak", false),
		"fire_cells": row_v("fire_cells", true),
		"fire_live": r.has("fire_peak") and r.has("fire_cells"),
	}


func fire_peak() -> float:
	return row_f("fire_peak")


func fire_cells() -> int:
	return row_n("fire_cells")


func is_burning(node) -> bool:
	if node == null or not _mirror_live("fire") or _f._fire.size() != _f._cell_count:
		return false
	var c: int = _f.world_to_cell(node.global_position)
	return c >= 0 and _f._fire[c] > FIRE_PRESENT


# --- LAVA-TUBE / HOLLOW signature -------------------------------------------
const TUBE_MELT_NEAR_ZERO: float = 0.05

## Open cells walled in by rock and NOT still melt-filled — a drained tube. One row per wall count, and the
## kernel binds the neighbour table; null when the reduction has not run.
func enclosed_void_cells(min_solid_nbr: int = 4):
	var key: String = "enclosed_void%d" % min_solid_nbr
	if LAReduceRecords.row(key).is_empty():
		push_error("enclosed_void_cells(%d): no such row. The device reduces the wall counts declared in "
			% min_solid_nbr + "LAReduceRecords and nothing else.")
		return null
	return row_v(key, true)


# --- Soil FERTILITY (decomposer output: detritus → fungus → CO₂ + fertility) — read the GPU fert channel -------

## Soil nutrient density at a world point (plants grow faster on rich ground). 0 outside the shell / before readback.
func fertility_at(pos: Vector3) -> float:
	if _f._fert.size() != _f._cell_count:
		return 0.0
	var c: int = _f.world_to_cell(pos)
	return _f._fert[c] if c >= 0 else 0.0

## Peak soil fertility over every open cell — above 0 once the decomposer loop deposits nutrient.
func fertility_peak() -> float:
	return row_f("fert_peak")


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


## Melt body/rind split. The three body rows are reduced on the device, so they stand whether or not the
## silicate mirror arrived. The interior/rind split asks each cell's six neighbours for THEIR melt, which no
## reduce row can express, so it walks the mirror and publishes null when the mirror is absent.
func lava_shell_diag() -> Dictionary:
	var mx: Variant = row_v("lava_maxmass", false)
	var out: Dictionary = {"lava_hot": row_v("lava_hot", true), "lava_thick": row_v("lava_thick", true),
		"lava_maxmass": snappedf(float(mx), 0.001) if mx != null else null,
		"lava_interior": null, "lava_rind": null, "lava_int_c": null, "lava_rind_c": null}
	if not _mirror_live("silicate") or _f._silicate_melt.size() != _f._cell_count:
		return out
	if _f._grid == null or _f._solid.size() != _f._cell_count or _f._temp.size() != _f._cell_count:
		return out
	# The melt depth that makes a cell part of the body, read back from the row the device counted with.
	var nbr: PackedInt32Array = _f._grid.neighbours
	var body: float = float(LAReduceRecords.row("lava_hot").get("threshold", NAN))
	if nbr.size() != _f._cell_count * 6 or is_nan(body):
		return out
	var interior: int = 0
	var rind: int = 0
	var int_sum: float = 0.0
	var rind_sum: float = 0.0
	for c in range(_f._cell_count):
		var lv: float = melt_at(c)
		if _f._solid[c] != 0 or lv < body or _f._silicate_melt[c] <= 0.0:
			continue
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
	out["lava_interior"] = interior
	out["lava_rind"] = rind
	out["lava_int_c"] = snappedf(int_sum / float(interior), 0.1) if interior > 0 else null
	out["lava_rind_c"] = snappedf(rind_sum / float(rind), 0.1) if rind > 0 else null
	return out


# Whole-grid mirrors. No reduction reads these — a total is a row of LAReduceRecords. Their consumers are
# the ones that need the value of EVERY cell: the water surface mesh, the albedo bake, the climate texture.
func _liquid_mirror() -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	if _f._h2o.size() != _f._cell_count:
		return out
	out.resize(_f._cell_count)
	for c in _f._cell_count:
		out[c] = liquid_at(c)
	return out
