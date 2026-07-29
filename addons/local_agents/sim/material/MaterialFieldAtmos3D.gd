class_name LAMaterialFieldAtmos3D
extends RefCounted

## LAMaterialFieldAtmos3D: the ATMOSPHERE derivation of LAMaterialField3D, factored out of the extract-only
## field hub (same pattern as the query / inject / scent / step modules: it holds no per-cell state of its own
## and reaches into the owning field `_f` for the shared arrays).
##
## Nothing here is stored as its own channel. There is ONE conserved atmospheric-water channel (`_moisture`);
## vapor = min(moisture, sat(T)), condensed = max(0, moisture - sat(T)), and the condensed part reads as fog
## (cool + near ground) or cloud (else). Every accessor below recomputes that instantaneously from `_moisture`
## + `_temp`, so cloud/fog/vapor can never drift out of sync with the substrate.
##
## The domain aggregates (cover fractions, cloud-cell count, precipitation proxy, total suspended mass) are
## computed in ONE grid pass and CACHED in the field's slots (`_f._cloud_cover_c` … `_f._moisture_total_c`),
## invalidated by `_f._atmos_dirty` whenever a new moisture/temp field is read back (~10Hz). The cache slots
## stay on the field because the step/snapshot modules set the dirty flag and read `_moisture_total_c`.
## Big-O: one O(cells) pass per SIM step, not per query x per render frame.
##
## Also owns the render COVER-TEXTURE bake (LACoverTextureBaker), folded into the same ~10Hz pass, plus the
## atmosphere shell radii the water-particle renderer places particles against.
## (Explicit types only, no ':=' inferred typing.)

const CoverBakerScript: GDScript = preload("res://addons/local_agents/sim/material/CoverTextureBaker.gd")

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _cover_baker = null                                  # LACoverTextureBaker — bakes the render cover texture


func setup(field) -> void:
	_f = field


## Saturation humidity at temperature `t` — the dewpoint moisture is read against. MUST match the kernel
## constants in atmos_evap/atmos_precip_sphere3d.glsl.
func _sat(t: float) -> float:
	return LAMaterialField3D.SAT_BASE * exp(LAMaterialField3D.SAT_TEMP_GAIN * (t - LAMaterialField3D.EVAP_TEMP_REF))


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
	var rain_threshold: float = LAMaterialField3D.RAIN_MASS_THRESHOLD
	var cover_min: float = LAMaterialField3D.CONDENSE_COVER_MIN
	var fog_max_temp: float = LAMaterialField3D.FOG_MAX_TEMP
	var cloud_n: int = 0
	var fog_n: int = 0
	var precip_n: int = 0
	var total: float = 0.0
	for i in range(cell_count):
		if solid[i] != 0:
			continue
		var aw: float = moisture[i]
		total += aw
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
	var sea_r: float = 248.0
	if _f._terrain != null and _f._terrain.has_method("sea_radius"):
		sea_r = _f._terrain.sea_radius()
	_cover_baker = CoverBakerScript.new()
	_cover_baker.setup(_f._sphere, sea_r, LAMaterialField3D.FOG_MAX_TEMP, LAMaterialField3D.RAIN_MASS_THRESHOLD,
		LAMaterialField3D.SAT_BASE, LAMaterialField3D.SAT_TEMP_GAIN, LAMaterialField3D.EVAP_TEMP_REF)


## Read-only CLIMATE snapshot — the live per-cell moisture/temp/snow/solid readback the biome surface baker
## reduces into a terrain-colour texture (LABiomeShaderController owns the baking; the field just exposes its
## buffers). Empty dict until the field is active. Returns the live arrays (not copies) — the baker only reads
## them, matching how the cover baker consumes the same buffers in-place.
func climate_snapshot() -> Dictionary:
	if _f._cell_count <= 0 or _f._moisture.size() != _f._cell_count or _f._temp.size() != _f._cell_count:
		return {}
	return {
		"moisture": _f._moisture, "temp": _f._temp, "snow": _f._snow,
		"solid": _f._solid, "static": _f._static, "cell_count": _f._cell_count,
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


## Total suspended atmospheric water mass (mass-conservation spot check; used by the SIM_REPORT).
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


# The flat cloud/fog sheet projection (cloud_grid/fog_grid) was a box-era concept, dissolved with the
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
	return LAMaterialField3D.EVAP_TEMP_REF + log(_f._moisture[c] / LAMaterialField3D.SAT_BASE) / LAMaterialField3D.SAT_TEMP_GAIN
