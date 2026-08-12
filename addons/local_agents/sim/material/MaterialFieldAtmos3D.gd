class_name LAMaterialFieldAtmos3D
extends RefCounted

const CellVolScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCellVolume3D.gd")

## LAMaterialFieldAtmos3D: the ATMOSPHERE derivation of LAMaterialField3D, factored out of the extract-only
## vapor = min(moisture, sat(T)), condensed = max(0, moisture - sat(T)), and the condensed part reads as fog

const CoverBakerScript: GDScript = preload("res://addons/local_agents/sim/material/CoverTextureBaker.gd")
# The precipitation threshold has ONE owner (Kessler autoconversion, derived from real air/water densities);
# the report's precip proxy and the render cover bake must read the same number the kernel rains at.

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _cover_baker = null                                  # LACoverTextureBaker — bakes the render cover texture


func setup(field) -> void:
	_f = field


## Saturation humidity at temperature `t` — the dewpoint moisture is read against, and the ONE thing that
## decides how much water this planet's air can hold. Clausius-Clapeyron, owned by LAPhysical and shared with
func _sat(t: float) -> float:
	return LAPhysical.saturation_mass_fraction(t)


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


## Recompute all condensate aggregates in a single grid pass. The fog/cloud split is a temperature proxy
## (cool, T<FOG_MAX_TEMP = fog; warmer = cloud) for the kernel's slot-0 near-ground test, which is not
## replicated on the CPU — these are report/visual metrics only.
func refresh_aggregates() -> void:
	_f._atmos_dirty = false
	# Local (copy-on-write, read-only) handles for the hot loop — same buffers, no per-cell property lookup.
	var cell_count: int = _f._cell_count
	var solid: PackedByteArray = _f._solid
	var moisture: PackedFloat32Array = _f._moisture
	var temp: PackedFloat32Array = _f._temp
	var rain_threshold: float = LAPhaseRecords.rain_threshold()
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
		# MASK-FREE: this is the airborne leg of the conserved h2o_total, so vapour in a cell the derived solid
		# flag now covers is still counted. The cloud/fog/precip COUNTS below are open-cell extents and stay masked.
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
	# Fold the render cover-texture bake into this same ~10Hz condensate pass (the water-particle renderer
	# samples it per particle). Cheap: one extra O(cell_count) reduction over the CPU readback we already have.
	if _f._sphere != null:
		_ensure_cover_baker()
		if _cover_baker != null:
			_cover_baker.bake(_f._moisture, _f._temp, _f._snow, _f._solid, _f._cell_count)


## Lazily build the cover-texture baker (sphere only). Callable before the first bake so the renderer can
## read the atmosphere band radii at setup.
func _ensure_cover_baker() -> void:
	if _cover_baker != null or _f._sphere == null:
		return
	if _f._terrain == null or not _f._terrain.has_method("sea_radius"):
		push_error("LAMaterialFieldAtmos3D: sphere field has no terrain sea_radius — cover baker not built")
		return
	var sea_r: float = _f._terrain.sea_radius()
	_cover_baker = CoverBakerScript.new()
	_cover_baker.setup(_f._sphere, sea_r, LAMaterialField3D.FOG_MAX_TEMP, LAPhaseRecords.rain_threshold())


func climate_snapshot() -> Dictionary:
	if _f._cell_count <= 0 or _f._moisture.size() != _f._cell_count or _f._temp.size() != _f._cell_count:
		return {}
	return {
		"moisture": _f._moisture, "temp": _f._temp, "snow": _f._snow,
		"solid": _f._solid, "cell_count": _f._cell_count,
	}


## The baked 6-layer RGBA cover texture (null until the first atmosphere refresh) — the water-particle
## renderer's field bridge. Plus the atmosphere shell radii it needs to place + classify particles.
func field_cover_texture() -> Texture2DArray:
	return _cover_baker.texture() if _cover_baker != null else null


func atmos_cloud_base_r() -> float:
	_ensure_cover_baker()
	return _cover_baker.cloud_base_r() if _cover_baker != null else _f.sea_level + 62.0


func atmos_fog_top_r() -> float:
	_ensure_cover_baker()
	return _cover_baker.fog_top_r() if _cover_baker != null else _f.sea_level + 16.0


func atmos_fog_lo_r() -> float:
	_ensure_cover_baker()
	return _cover_baker.fog_lo_r() if _cover_baker != null else _f.sea_level


func atmos_outer_r() -> float:
	_ensure_cover_baker()
	return _cover_baker.outer_r() if _cover_baker != null else 330.0


func avg_cloud_cover() -> float:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._cloud_cover_c


func avg_fog_cover() -> float:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._fog_cover_c


## Domain precipitation proxy 0..1 — fraction of open cells whose condensate is over the rain threshold.
func precipitation() -> float:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._precip_c


## Total suspended atmospheric water mass — the AIRBORNE leg of the conserved H₂O ledger (`h2o_total`), summed
## over every OPEN cell per the one inclusion rule documented in LAMaterialFieldLedger3D's header. Computed in
## refresh_aggregates' single grid pass and cached, so this is a cache read, not a scan.
func moisture_total() -> float:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._moisture_total_c


## Count of OPEN cells carrying derived condensate (moisture over saturation) at/above CONDENSE_COVER_MIN.
## Cached with the other atmosphere aggregates (recomputed once per field readback, not per call).
func cloud_cell_count() -> int:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._cloud_cells_c


# CloudLayer sheets — the water-particle renderer samples the baked cover texture instead. cloud_base_y/
# fog_base_y survive as the near-ground radii the derived point queries (cloud_at/fog_at) sample at.
func cloud_base_y() -> float:
	return _f.sea_level + 62.0


func fog_base_y() -> float:
	return _f.sea_level + 6.0


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
	var e: float = _f._moisture[c] * LAPhysical.WATER_DENSITY_KG_M3 * LAPhysical.VAPOUR_GAS_CONST_J_KGK \
		* (_f._temp[c] + LAPhysical.KELVIN_OFFSET)
	var ln_ratio: float = log(maxf(e / LAPhysical.MAGNUS_A_PA, 1.0e-12))
	return LAPhysical.MAGNUS_C_C * ln_ratio / maxf(LAPhysical.MAGNUS_B - ln_ratio, 1.0e-6)
