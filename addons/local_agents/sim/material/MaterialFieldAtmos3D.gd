class_name LAMaterialFieldAtmos3D
extends RefCounted

const CellVolScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCellVolume3D.gd")

## Atmosphere queries derived from the one `moisture` channel of LAMaterialField3D.
## vapor = min(moisture, sat(T)); condensate = max(0, moisture - sat(T)), split fog/cloud by temperature.

# Kessler (1969) q_crit: the cloud-water mixing ratio above which drops start collecting each other.
# Declared in docs/MODEL_PARAMETERS.md.
const CLOUD_WATER_CRIT_KG_KG: float = 0.5e-3

# Altitudes above the sea surface, model units, at which the renderer places its particle bands.
const CLOUD_BASE_ALT: float = 62.0
const FOG_TOP_ALT: float = 16.0
const FOG_LO_ALT: float = 0.0

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


## The autoconversion threshold in the field's own unit: a fraction of a cell full of liquid water.
static func rain_threshold() -> float:
	return CLOUD_WATER_CRIT_KG_KG * LAPhysical.AIR_DENSITY_KG_M3 / LAPhysical.WATER_DENSITY_KG_M3


## Saturation vapour concentration at `t` °C, mol/m^3. Clausius-Clapeyron, owned by LAPhysical.
func _sat(t: float) -> float:
	return LAPhysical.saturation_vapour_mol_m3(t)


## Suspended condensate (liquid/ice) at a linear cell = the moisture over saturation. 0 for solid/oob cells.
func _condensed_at(cell: int) -> float:
	if cell < 0 or cell >= _f._cell_count or _f._solid[cell] != 0:
		return 0.0
	return maxf(0.0, _f._moisture[cell] - _sat(_f._temp[cell]))


## Cloud density at a world XZ column (0 if unresolved). Cloud = the condensate that is NOT ground fog.
func cloud_at(x: float, z: float) -> float:
	var c: int = _f.world_to_cell(Vector3(x, cloud_base_y(), z))
	if c < 0:
		return 0.0
	return 0.0 if _f._temp[c] < LAMaterialField3D.FOG_MAX_TEMP else _condensed_at(c)


## Fog density at a world XZ column (0 if unresolved). Fog = cool near-ground condensate.
func fog_at(x: float, z: float) -> float:
	var c: int = _f.world_to_cell(Vector3(x, fog_base_y(), z))
	if c < 0:
		return 0.0
	return _condensed_at(c) if _f._temp[c] < LAMaterialField3D.FOG_MAX_TEMP else 0.0


## Recompute the condensate aggregates + the mask-free moisture_total in one grid pass. Fog/cloud split by
## temperature: below FOG_MAX_TEMP = fog, above = cloud. Report/visual metrics.
func refresh_aggregates() -> void:
	_f._atmos_dirty = false
	# Local (copy-on-write, read-only) handles for the hot loop — same buffers, no per-cell property lookup.
	var cell_count: int = _f._cell_count
	var solid: PackedByteArray = _f._solid
	var moisture: PackedFloat32Array = _f._moisture
	var temp: PackedFloat32Array = _f._temp
	var rain_threshold: float = rain_threshold()
	var cover_min: float = LAMaterialField3D.CONDENSE_COVER_MIN
	var fog_max_temp: float = LAMaterialField3D.FOG_MAX_TEMP
	var cloud_n: int = 0
	var fog_n: int = 0
	var precip_n: int = 0
	var vol: PackedFloat32Array = CellVolScript.of(_f)
	if vol.size() != cell_count:
		return
	var total: float = 0.0
	for i in range(cell_count):
		var aw: float = moisture[i]
		# Mask-free, mol: airborne H2O counts every cell, because vapour in a cell the derived solid flag now
		# covers has moved, not vanished. The cloud/fog/precip counts below are open-cell extents and stay masked.
		total += aw * vol[i]
		if solid[i] != 0:
			continue
		var cond: float = aw - _sat(temp[i])
		if cond <= 0.0:
			continue
		if cond > rain_threshold:
			precip_n += 1
		if cond >= cover_min:
			if temp[i] < fog_max_temp:
				fog_n += 1
			else:
				cloud_n += 1
	var inv: float = 1.0 / float(cell_count) if cell_count > 0 else 0.0
	_f._cloud_cells_c = cloud_n
	_f._cloud_cover_c = float(cloud_n) * inv
	_f._fog_cover_c = float(fog_n) * inv
	_f._precip_c = clampf(float(precip_n) * inv * 40.0, 0.0, 1.0)
	_f._moisture_total_c = total


func climate_snapshot() -> Dictionary:
	if _f._cell_count <= 0 or _f._moisture.size() != _f._cell_count or _f._temp.size() != _f._cell_count:
		return {}
	return {
		"moisture": _f._moisture, "temp": _f._temp, "snow": _f._snow,
		"solid": _f._solid, "cell_count": _f._cell_count,
	}


## The atmosphere band radii the water-particle renderer places against, measured from the body centre. Each
## is declared exactly once, here.
func atmos_cloud_base_r() -> float:
	return _f.sea_radius() + CLOUD_BASE_ALT


func atmos_fog_top_r() -> float:
	return _f.sea_radius() + FOG_TOP_ALT


func atmos_fog_lo_r() -> float:
	return _f.sea_radius() + FOG_LO_ALT


## The outermost radius the grid holds: half the box, so no particle is placed where there are no cells.
func atmos_outer_r() -> float:
	var grid: LAVoxelGrid = _f._grid
	return 0.5 * float(grid.max_span()) * grid.cell_size if grid != null else 0.0


func avg_cloud_cover() -> float:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._cloud_cover_c


func avg_fog_cover() -> float:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._fog_cover_c


## Precipitation proxy 0..1 — cells whose condensate is over the rain threshold, as a fraction of ALL cells,
## rescaled by a fitted gain and clamped (see refresh_aggregates).
func precipitation() -> float:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._precip_c


## Airborne H2O over every cell, no residency mask, in moles. Accumulated in refresh_aggregates' single grid
## pass and cached: a cache read, not a scan.
func moisture_total() -> float:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._moisture_total_c


## Count of cells whose derived condensate (moisture over saturation) is at/above CONDENSE_COVER_MIN and
## warmer than FOG_MAX_TEMP. Cached with the other atmosphere aggregates, not recomputed per call.
func cloud_cell_count() -> int:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._cloud_cells_c


# CloudLayer sheets — the water-particle renderer samples the baked cover texture instead. cloud_base_y/
# fog_base_y survive as the near-ground radii the derived point queries (cloud_at/fog_at) sample at.
func cloud_base_y() -> float:
	return _f.sea_radius() + 62.0


func fog_base_y() -> float:
	return _f.sea_radius() + 6.0


## Relative humidity 0..1 near the ground at a world XZ column = vapor / sat(T) = min(moisture, sat)/sat.
func relative_humidity_at(x: float, z: float) -> float:
	var c: int = _f.world_to_cell(Vector3(x, fog_base_y(), z))
	if c < 0 or _f._solid[c] != 0:
		return 0.0
	var s: float = _sat(_f._temp[c])
	if s <= 0.0:
		return 0.0
	return clampf(_f._moisture[c] / s, 0.0, 1.0)


## Dewpoint °C near the ground at a world XZ column — the temperature at which the cell's moisture would
## saturate (invert sat(T)). NAN if unresolved or bone dry.
func dewpoint_at(x: float, z: float) -> float:
	var c: int = _f.world_to_cell(Vector3(x, fog_base_y(), z))
	if c < 0 or _f._solid[c] != 0 or _f._moisture[c] <= 0.0:
		return NAN
	var e: float = _f._moisture[c] * LAPhysical.GAS_CONSTANT_J_MOL_K \
		* (_f._temp[c] + LAPhysical.KELVIN_OFFSET)
	# The dewpoint is the boiling point at the vapour's own partial pressure: one curve, inverted.
	return LASubstances.boil_c_at("h2o", e)
