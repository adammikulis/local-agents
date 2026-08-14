class_name LAMaterialFieldAtmos3D
extends RefCounted

## Atmosphere queries derived from the one `moisture` channel of LAMaterialField3D.

# Kessler (1969) q_crit: the cloud-water mixing ratio above which drops start collecting each other.
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


## SATURATION AMOUNT at `t` °C and `p` Pa, in the h2o channel's own unit.
func _sat(t: float, p_pa: float) -> float:
	var e: float = LAMixtureEnthalpy.vapour_p_at("h2o", t, p_pa)
	if e <= 0.0:
		return 0.0
	var entry: Dictionary = LASubstances.table().get("h2o", {})
	var mm: float = float(entry.get("molar_mass", 0.0))
	var rho: float = float(entry.get("density", 0.0))
	if mm <= 0.0 or rho <= 0.0:
		return 0.0
	return e * mm / (LAPhysical.GAS_CONSTANT_J_MOL_K * maxf(t + LAPhysical.KELVIN_OFFSET, 1.0) * rho)


## Suspended condensate (liquid + ice) at a linear cell, from the shares the ladder derived. 0 in rock.
func _condensed_at(cell: int) -> float:
	if cell < 0 or cell >= _f._cell_count or _f._solid[cell] != 0:
		return 0.0
	return _f._queries.liquid_at(cell) + _f._queries.ice_at(cell)


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


## Take the condensate counts and the mask-free vapour amount off the device. Cloud, fog and rain are three
## thresholds on ONE quantity — the liquid plus frozen share of a cell's h2o — so each is a reduced row and
## none of them walks the grid. Absent rows publish NAN / -1 rather than an empty sky.
func refresh_aggregates() -> void:
	_f._atmos_dirty = false
	var q = _f._queries
	var cell_count: int = _f._cell_count
	var cloud_n: int = q.row_n("cloud_cells")
	var fog_n: int = q.row_n("fog_cells")
	var precip_n: int = q.row_n("precip_cells")
	var inv: float = 1.0 / float(cell_count) if cell_count > 0 else 0.0
	_f._cloud_cells_c = cloud_n
	_f._cloud_cover_c = float(cloud_n) * inv if cloud_n >= 0 else NAN
	_f._fog_cover_c = float(fog_n) * inv if fog_n >= 0 else NAN
	_f._precip_c = float(precip_n) * inv if precip_n >= 0 else NAN
	_f._vapour_total_c = q.row_f("vapour_amount")


func climate_snapshot() -> Dictionary:
	if _f._cell_count <= 0 or _f._h2o.size() != _f._cell_count or _f._temp.size() != _f._cell_count:
		return {}
	return {"temp": _f._temp, "solid": _f._solid, "cell_count": _f._cell_count}


## The atmosphere band radii the water-particle renderer places against, measured from the body centre.
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


## Share of cells precipitating.
func precipitation() -> float:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._precip_c


## Airborne H2O over every cell, no residency mask, in moles.
func vapour_total() -> float:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._vapour_total_c


## Count of cells whose derived condensate is at or above CONDENSE_COVER_MIN.
func cloud_cell_count() -> int:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._cloud_cells_c


# CloudLayer sheets — the water-particle renderer samples the baked cover texture instead.
func cloud_base_y() -> float:
	return _f.sea_radius() + 62.0


func fog_base_y() -> float:
	return _f.sea_radius() + 6.0


## Relative humidity 0..1 near the ground at a world XZ column = vapor / sat(T) = min(moisture, sat)/sat.
func relative_humidity_at(x: float, z: float) -> float:
	var c: int = _f.world_to_cell(Vector3(x, fog_base_y(), z))
	if c < 0 or _f._solid[c] != 0:
		return 0.0
	var s: float = _sat(_f._temp[c], _cell_p(c))
	if s <= 0.0:
		return 0.0
	return clampf(_f._queries.vapour_at(c) / s, 0.0, 1.0)


## Dewpoint °C near the ground at a world XZ column.
func dewpoint_at(x: float, z: float) -> float:
	var c: int = _f.world_to_cell(Vector3(x, fog_base_y(), z))
	if c < 0 or _f._solid[c] != 0 or _f._queries.vapour_at(c) <= 0.0:
		return NAN
	var entry: Dictionary = LASubstances.table().get("h2o", {})
	var mm: float = float(entry.get("molar_mass", 0.0))
	var rho: float = float(entry.get("density", 0.0))
	if mm <= 0.0 or rho <= 0.0:
		return NAN
	# Partial pressure of the vapour the cell holds: n/V = vf * rho / M, then e = (n/V) R T.
	var e: float = _f._queries.vapour_at(c) * rho / mm * LAPhysical.GAS_CONSTANT_J_MOL_K \
		* (_f._temp[c] + LAPhysical.KELVIN_OFFSET)
	# The dewpoint is the boiling point at the vapour's own partial pressure: one curve, inverted.
	return LASubstances.boil_c_at("h2o", e)


## The cell's own air pressure, Pa. Missing means unresolved, and the caller gets zero rather than a guess.
func _cell_p(c: int) -> float:
	if c < 0 or _f._pressure.size() != _f._cell_count:
		return 0.0
	return maxf(_f._pressure[c], 0.0)
