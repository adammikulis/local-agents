class_name LAMaterialAtmosphere
extends RefCounted

## LAMaterialAtmosphere — the ATMOSPHERE concern of the material field (the emergent water cycle).
##
## Split out of LAMaterialField: this module owns the vapor -> cloud/fog -> rain cycle plus wind
## transport. Evaporation off warm water/wet ground feeds a per-cell water-VAPOR layer (written by the
## fluids module); vapor diffuses and drifts downwind; where the air is cool enough that vapor exceeds
## its (temperature-dependent) saturation it CONDENSES into CLOUD density (or, when the SURFACE air is
## itself saturated, into ground-hugging FOG); thick cloud RAINS water back onto the ground and SHADES
## the sun below it (the field's heat step reads the cloud/fog grids for that shading). Clouds forming
## over cool peaks, drifting off warm water, fog pooling in valleys at dawn, and rain feeding rivers all
## fall out of these local rules — nothing is scripted per-case.
##
## It holds NO grid state of its own beyond its transport scratch (`_adelta`), the wind vector and the
## cached cover means; it reaches back into the owning LAMaterialField (`_f`) for the shared grid state
## (`_temp`, `_vapor`, `_cloud`, `_fog`, `_mats`, `_sampled`, `_cell_count`, `_dim`, `_cell_size`, the
## index helpers `_index_at`/`_mat_array`, `sea_level`, `STEP_DT`, `EVAP_TEMP_REF`) and SETS the render
## dirty flag (`_f._liquid_dirty`) when precipitation adds ground water. Behaviour is identical to the
## old inline code. (Explicit types only — no ':=' inferred typing.)

# Material registry (preloaded so cross-file constants resolve without an editor class-scan).
const Mat: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/Materials.gd")

# --- Atmosphere tuning (the vapor -> cloud/fog -> rain cycle) ---
const VAPOR_DIFFUSE: float = 0.14        # isotropic vapor spread per step
const CLOUD_DIFFUSE: float = 0.06        # clouds spread a little too
const SAT_BASE: float = 0.035            # saturation vapor at EVAP_TEMP_REF (lower -> clouds form sooner)
const SAT_TEMP_GAIN: float = 0.055       # warmer air holds exponentially more vapor before condensing
const CONDENSE_RATE: float = 0.30        # fraction of super-saturated vapor -> cloud per step
const CLOUD_REEVAP_RATE: float = 0.08    # fraction of cloud -> vapor per step when air is sub-saturated
const CLOUD_DECAY: float = 0.002         # baseline cloud dissipation per step (keeps it from piling up)
const RAIN_CLOUD_THRESHOLD: float = 0.45 # cloud density above which it precipitates
const RAIN_RATE: float = 0.16            # fraction of above-threshold cloud -> ground water per step
const CLOUD_BASE_ABOVE_SEA: float = 62.0 # world-Y of the rendered cloud sheet, above sea level
## Air at cloud base is this many °C cooler than the surface — clouds condense from vapor that only
## the cooler air aloft can't hold. When the SURFACE air itself is saturated (cool valleys/water at
## dawn), that condensate pools at ground level as FOG instead. Same vapor, two outcomes.
const CLOUD_AIR_COOLING: float = 7.0
const FOG_MAX_TEMP: float = 12.0         # only surfaces cooler than this (°C) pool ground fog
const FOG_BASE_ABOVE_SEA: float = 6.0    # world-Y of the ground-hugging fog sheet, above sea level

var _f = null                            # back-reference to the owning LAMaterialField

var _adelta: PackedFloat32Array = PackedFloat32Array()    # scratch for vapor/cloud transport
var _wind: Vector2 = Vector2.ZERO                         # world XZ wind (from weather) drifting vapor
var _cloud_cover: float = 0.0                             # cached mean cloud density (sun dimming/HUD)
var _fog_cover: float = 0.0                               # cached mean fog density


func setup(field) -> void:
	_f = field
	_adelta = PackedFloat32Array()
	_adelta.resize(_f._cell_count)


# --- Transport ---------------------------------------------------------------

## Move vapor/cloud/fog: isotropic diffusion (symmetric, order-independent, right+up pairs) plus,
## optionally, first-order upwind advection by the wind. Accumulates into _adelta then applies.
func _transport(arr: PackedFloat32Array, diffuse_frac: float, wind_gain: float) -> void:
	var dim: int = _f._dim
	for idx in range(_f._cell_count):
		_adelta[idx] = 0.0
	for j in range(dim):
		var row: int = j * dim
		for i in range(dim):
			var idx: int = row + i
			if _f._sampled[idx] == 0:
				continue
			var q: float = arr[idx]
			if i < dim - 1:
				var ri: int = idx + 1
				if _f._sampled[ri] != 0:
					var f: float = (q - arr[ri]) * diffuse_frac * 0.25
					_adelta[idx] -= f
					_adelta[ri] += f
			if j < dim - 1:
				var ui: int = idx + dim
				if _f._sampled[ui] != 0:
					var f2: float = (q - arr[ui]) * diffuse_frac * 0.25
					_adelta[idx] -= f2
					_adelta[ui] += f2
	if wind_gain > 0.0 and (_wind.x != 0.0 or _wind.y != 0.0):
		var ax: float = clampf(absf(_wind.x) * wind_gain * _f.STEP_DT / _f._cell_size, 0.0, 0.5)
		var az: float = clampf(absf(_wind.y) * wind_gain * _f.STEP_DT / _f._cell_size, 0.0, 0.5)
		var sx: int = 1 if _wind.x > 0.0 else -1
		var sz: int = 1 if _wind.y > 0.0 else -1
		for j2 in range(dim):
			var row2: int = j2 * dim
			for i2 in range(dim):
				var idx2: int = row2 + i2
				if _f._sampled[idx2] == 0:
					continue
				var q2: float = arr[idx2]
				if q2 <= 0.0:
					continue
				if ax > 0.0:
					var ni: int = i2 + sx
					if ni >= 0 and ni < dim:
						var nidx: int = row2 + ni
						if _f._sampled[nidx] != 0:
							var mv: float = q2 * ax
							_adelta[idx2] -= mv
							_adelta[nidx] += mv
				if az > 0.0:
					var nj: int = j2 + sz
					if nj >= 0 and nj < dim:
						var nidx2: int = nj * dim + i2
						if _f._sampled[nidx2] != 0:
							var mv2: float = q2 * az
							_adelta[idx2] -= mv2
							_adelta[nidx2] += mv2
	for idx3 in range(_f._cell_count):
		if _f._sampled[idx3] == 0:
			continue
		var v: float = arr[idx3] + _adelta[idx3]
		if v < 0.0:
			v = 0.0
		arr[idx3] = v


# --- The atmosphere step (vapor -> cloud/fog -> rain) ------------------------

## Vapor drifts/spreads, then per cell: vapor the cool air aloft can't hold CONDENSES into cloud
## (the share the surface air also can't hold pools as ground FOG); sub-saturated air lets cloud/fog
## re-evaporate; thick cloud RAINS water back to the ground. Clouds over cool peaks, fog in valleys
## at dawn, and rain feeding rivers all fall out of this — no per-case scripting.
func step() -> void:
	if _f._cell_count <= 0:
		return
	# Wind carries everything AIRBORNE/AERATED — vapor (gas), cloud and fog (suspended droplets) all
	# drift downwind; liquid WATER is not advected here (it flows by gravity in the fluids module). Fog
	# hugging the ground drifts a little slower (ground drag) via a lower wind gain.
	_transport(_f._vapor, VAPOR_DIFFUSE, 1.0)
	_transport(_f._cloud, CLOUD_DIFFUSE, 1.0)
	_transport(_f._fog, CLOUD_DIFFUSE * 0.5, 0.5)

	var water: PackedFloat32Array = _f._mat_array(Mat.WATER)
	var cloud_sum: float = 0.0
	var fog_sum: float = 0.0
	var rained: bool = false
	for idx in range(_f._cell_count):
		if _f._sampled[idx] == 0:
			continue
		var t: float = _f._temp[idx]
		var vap: float = _f._vapor[idx]
		# Saturation the surface air holds, and the (colder) air at cloud base holds. When the SURFACE
		# air itself saturates, condensation happens at ground level as FOG; when only the cooler air
		# aloft saturates, it forms CLOUD at the base. Same vapor, height decided by where it saturates.
		var sat_surface: float = SAT_BASE * exp(SAT_TEMP_GAIN * (t - _f.EVAP_TEMP_REF))
		var sat_aloft: float = SAT_BASE * exp(SAT_TEMP_GAIN * ((t - CLOUD_AIR_COOLING) - _f.EVAP_TEMP_REF))
		# Fog is a COOL-air phenomenon: warm saturated air over water is just humid (its vapor rises
		# and clouds aloft instead), so only genuinely cool surfaces pool ground fog.
		var cool: float = t < FOG_MAX_TEMP
		if cool and vap > sat_surface:
			var fcond: float = (vap - sat_surface) * CONDENSE_RATE
			_f._vapor[idx] = vap - fcond
			_f._fog[idx] += fcond
		else:
			# Surface sub-saturated: any ground fog re-evaporates back to vapor.
			var fr: float = _f._fog[idx] * CLOUD_REEVAP_RATE
			_f._fog[idx] -= fr
			vap = vap + fr
			if vap > sat_aloft:
				var ccond: float = (vap - sat_aloft) * CONDENSE_RATE
				_f._vapor[idx] = vap - ccond
				_f._cloud[idx] += ccond
			else:
				var cr: float = _f._cloud[idx] * CLOUD_REEVAP_RATE
				_f._cloud[idx] -= cr
				_f._vapor[idx] = vap + cr
		# Baseline dissipation so condensate never piles up forever.
		_f._cloud[idx] *= (1.0 - CLOUD_DECAY)
		_f._fog[idx] *= (1.0 - CLOUD_DECAY)
		# Precipitation: thick cloud rains water back to the ground, closing the cycle.
		if _f._cloud[idx] > RAIN_CLOUD_THRESHOLD:
			var rain: float = (_f._cloud[idx] - RAIN_CLOUD_THRESHOLD) * RAIN_RATE
			_f._cloud[idx] -= rain
			water[idx] += rain
			rained = true
		cloud_sum += _f._cloud[idx]
		fog_sum += _f._fog[idx]
	var denom: float = maxf(1.0, float(_f._sampled_count))
	_cloud_cover = cloud_sum / denom
	_fog_cover = fog_sum / denom
	if rained:
		_f._liquid_dirty = true


# --- Wind + queries ----------------------------------------------------------

## Set the current wind (world XZ) so vapor/cloud drift downwind. Fed from the weather each frame.
func set_wind(w: Vector2) -> void:
	if is_nan(w.x) or is_nan(w.y) or is_inf(w.x) or is_inf(w.y):
		return
	_wind = w


func wind() -> Vector2:
	return _wind


func cloud_at(x: float, z: float) -> float:
	var idx: int = _f._index_at(x, z)
	return _f._cloud[idx] if idx >= 0 else 0.0


func fog_at(x: float, z: float) -> float:
	var idx: int = _f._index_at(x, z)
	return _f._fog[idx] if idx >= 0 else 0.0


## Mean cloud / fog density over sampled cells — drives global sun dimming and HUD/diagnostics.
func avg_cloud_cover() -> float:
	return _cloud_cover


func avg_fog_cover() -> float:
	return _fog_cover


## The raw density grids (flat, index = j*dim+i) for building render textures. Returned by reference;
## the renderer only reads them.
func cloud_grid() -> PackedFloat32Array:
	return _f._cloud


func fog_grid() -> PackedFloat32Array:
	return _f._fog


## Diagnostic: cells whose cloud density is at least min_density.
func cloud_cell_count(min_density: float = 0.05) -> int:
	var n: int = 0
	for idx in range(_f._cell_count):
		if _f._sampled[idx] != 0 and _f._cloud[idx] >= min_density:
			n += 1
	return n


## World Y of the two rendered condensate sheets.
func cloud_base_y() -> float:
	return _f.sea_level + CLOUD_BASE_ABOVE_SEA


func fog_base_y() -> float:
	return _f.sea_level + FOG_BASE_ABOVE_SEA
