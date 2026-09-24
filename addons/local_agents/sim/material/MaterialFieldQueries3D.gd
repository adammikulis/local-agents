class_name LAMaterialFieldQueries3D
extends RefCounted

## LAMaterialFieldQueries3D: the READ-ONLY query accessors of the dense 3D MaterialField3D, factored

const MOLTEN_MIN: float = 0.0001 * LAPhysical.ROCK_DENSITY_KG_M3 / LAPhysical.MOLAR_MASS_CASIO3_KG_MOL  # gauge floor, mol/m^3

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


## True when `name`'s readback landed on the most recent GPU drain, so the mirror is current. A
## demand-gated channel is absent from any drain nobody asked for, and its mirror then holds an older value.
func _mirror_live(name: String) -> bool:
	return _f != null and _f._mirrors != null and _f._mirrors.live(name)


# --- Water queries -----------------------------------------------------------

## True where there is drinkable water at a world point. False outside the box / before readback.
## LIQUID water in a cell, in channel units: the h2o it holds times the share the ladder says is liquid.
func liquid_at(c: int) -> float:
	if c < 0:
		return 0.0
	return maxf(_f._mirrors.at("h2o", c), 0.0) * clampf(_f._mirrors.at("h2o_liquid", c), 0.0, 1.0)


## FROZEN water in a cell, same units.
func ice_at(c: int) -> float:
	if c < 0:
		return 0.0
	return maxf(_f._mirrors.at("h2o", c), 0.0) * clampf(_f._mirrors.at("h2o_solid", c), 0.0, 1.0)


## WATER VAPOUR in a cell, same units.
func vapour_at(c: int) -> float:
	if c < 0:
		return 0.0
	return maxf(_f._mirrors.at("h2o", c), 0.0) * clampf(_f._mirrors.at("h2o_vapour", c), 0.0, 1.0)


func is_water_at(pos: Vector3) -> bool:
	var c: int = _f.world_to_cell(pos)
	return c >= 0 and liquid_at(c) >= _f.MIN_MASS


## Liquid h2o over every cell, mask-free, in the channel's own amount unit.
func total_water() -> float:
	return row_f("water_liquid_total")


# --- Temperature query -------------------------------------------------------

## Temperature °C at a world point. NAN outside the box or in a cell that holds no matter: neither has a
## temperature to read.
func temp_at(pos: Vector3) -> float:
	var c: int = _f.world_to_cell(pos)
	if c < 0 or not (_f._mirrors.at("rho_bulk", c) > 0.0):
		return NAN
	return _f._mirrors.at("temp", c)


## Pressure at a world point, Pa. NAN outside the box or before the first readback.
func pressure_at(pos: Vector3) -> float:
	var c: int = _f.world_to_cell(pos)
	return _f._mirrors.at("pressure", c) if c >= 0 else NAN


# --- Diagnostics -------------------------------------------------------------

## Mean rock temperature at five radii, plus the SKIN: the outermost rock of every column. A sample
## no cell fell in is null: a mean over nothing is not zero degrees.
func rock_radial_profile() -> Dictionary:
	var out: Dictionary = {}
	for tag: String in LAReduceHeatRows.PROFILE_SAMPLES:
		out["rock_%s_c" % tag] = _row_mean("rock_%s_sum" % tag, "rock_%s_n" % tag)
	out["rock_skin_c"] = _row_mean("rock_skin_sum", "rock_skin_cells")
	out["rock_skin_cells"] = row_v("rock_skin_cells", true)
	return out


## A reduced SUM over a reduced COUNT, or null when either is absent or the count is zero.
func _row_mean(sum_key: String, n_key: String):
	var r: Dictionary = reduced()
	if not r.has(sum_key) or not r.has(n_key):
		return null
	var n: float = float(r[n_key])
	return snappedf(float(r[sum_key]) / n, 0.1) if n > 0.0 else null


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
	if _f._grid == null:
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
	if _f._grid == null:
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
	if _f._grid == null:
		return Vector3.ZERO
	var c: int = _f.world_to_cell(pos)
	if c < 0 or liquid_at(c) <= 0.0:
		return Vector3.ZERO
	var v: Vector3 = LAFieldGeometry.velocity(_f, c)
	var speed: float = v.length()
	if speed <= 0.0:
		return Vector3.ZERO
	# Mass density of the moving water, kg/m^3: its amount (mol/m^3) times its molar mass.
	var rho: float = float(LASubstances.table().get("h2o", {}).get("molar_mass", 0.0)) * liquid_at(c)
	return v.normalized() * (0.5 * rho * speed * speed)


# --- Emergent WIND as a real momentum/force (read back from the GPU velocity field) ------------------

## Full 3D wind velocity at a world point, m/s. The velocity channels are the grid's own axes, so there is
## no basis to rotate through. Vector3.ZERO outside the box / before readback.
func wind3_at(x: float, y: float, z: float) -> Vector3:
	if _f._grid == null:
		return Vector3.ZERO
	var c: int = _f.world_to_cell(Vector3(x, y, z))
	if c < 0:
		return Vector3.ZERO
	return LAFieldGeometry.velocity(_f, c)


## THE FASTEST AIR IN THE BOX, m/s, off the reduction. NAN when it has not run: a maximum over nothing is
## not zero wind. This is a scalar the field can honestly answer; a direction is a LOCAL question and
## wind3_at is where it is asked.
func wind_speed_max() -> float:
	return row_f("wind_speed_max")


## Cells the solid derive left open, from the same reduction. -1 when it has not run.
func open_cells() -> int:
	var solid: int = row_n("solid_cells")
	return _f._cell_count - solid if solid >= 0 else -1


# --- MINERAL: airborne opacity + the molten state. Totals live in LAMaterialFieldLedger3D. -------------

## Volume fraction of the cell that is wind-borne mineral: the amount times its derived airborne share.
func airborne_at(c: int) -> float:
	if c < 0:
		return 0.0
	return maxf(_f._mirrors.at("silicate", c), 0.0) \
		* clampf(_f._mirrors.at("silicate_susp_air", c), 0.0, 1.0)


## Volume fraction of the cell that is molten mineral.
func melt_at(c: int) -> float:
	if c < 0:
		return 0.0
	return maxf(_f._mirrors.at("silicate", c), 0.0) \
		* clampf(_f._mirrors.at("silicate_melt", c), 0.0, 1.0)


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
	if node == null or not _mirror_live("fire"):
		return false
	var c: int = _f.world_to_cell(node.global_position)
	return c >= 0 and _f._mirrors.at("fire", c) > 0.0


# --- LAVA-TUBE / HOLLOW signature -------------------------------------------
const TUBE_MELT_NEAR_ZERO: float = 0.05 * LAPhysical.ROCK_DENSITY_KG_M3 / LAPhysical.MOLAR_MASS_CASIO3_KG_MOL  # mol/m^3

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
	var c: int = _f.world_to_cell(pos)
	return _f._mirrors.at("fert", c) if c >= 0 else 0.0

## Peak soil fertility over every open cell — above 0 once the decomposer loop deposits nutrient.
func fertility_peak() -> float:
	return row_f("fert_peak")


# --- SEA SURFACE — the free water surface, frozen and open ---------------------------------------------

## Frozen extent and the MEAN temperature of the frozen and open halves of the free water surface, off
## the rows LAReduceWaterRows declares over the surface class the derive publishes.
func sea_surface_stats() -> Dictionary:
	return {
		"sea_ice_cells": row_v("sea_ice_cells", true),
		"sea_ice_temp_mean": _row_mean("sea_ice_temp_sum", "sea_ice_cells"),
		"open_sea_cells": row_v("open_sea_cells", true),
		"open_sea_temp_mean": _row_mean("open_sea_temp_sum", "open_sea_cells"),
	}


## Melt body/rind split, every part of it reduced on the device: the interior is walled by rock or by
## more of the same melt, the rind is not.
func lava_shell_diag() -> Dictionary:
	var mx: Variant = row_v("lava_maxmass", false)
	return {"lava_hot": row_v("lava_hot", true), "lava_thick": row_v("lava_thick", true),
		"lava_maxmass": snappedf(float(mx), 0.001) if mx != null else null,
		"lava_interior": row_v("lava_interior", true), "lava_rind": row_v("lava_rind", true),
		"lava_int_c": _row_mean("lava_interior_sum", "lava_interior"),
		"lava_rind_c": _row_mean("lava_rind_sum", "lava_rind")}


