class_name LAMaterialAtmosphere3D
extends RefCounted

## LAMaterialAtmosphere3D — the ATMOSPHERE (emergent water cycle) of the dense 3D MaterialField3D.
##
## The 2.5D LAMaterialAtmosphere had ONE air layer per XZ column, so it could only *fake* height: it
## compared the surface air's saturation to a hardcoded "cloud base is N °C cooler" offset to decide
## whether condensate became ground fog or a cloud sheet. This module drops that trick. In the dense 3D
## field EVERY cell already carries a real temperature (the heat module applies conduction + an altitude
## lapse, so upper cells are genuinely cooler), so condensation is decided per cell from that cell's OWN
## temperature via the dewpoint curve. Humid air is buoyant and RISES; when it reaches the naturally
## cooler cells aloft its vapor passes its dewpoint and condenses as CLOUD; cool cells resting against
## the terrain / sea pool that condensate as FOG. Cloud-forms-aloft and fog-forms-low therefore EMERGE
## from local rules over real altitude — nothing is scripted per case.
##
## Holds NO grid state of its own beyond transport scratch, the 2D projection grids the renderer reads,
## the wind vector, and cached cover means. It reaches into the owning LAMaterialField3D (`_f`) for the
## shared per-cell arrays (`_temp`, `_vapor`, `_cloud`, `_fog`, `_solid`, `_water`, `_static`), the
## dims/geometry (`_dim_x/_dim_y/_dim_z`, `_cell_count`, `_cell_size`, `_origin`, `_sea_level`), and its
## constants (`MAX_MASS`, `STEP_DT`). Mirrors LAMaterialHeat3D's shape: `setup(field)` stores `_f`;
## `step()` operates on `_f`'s arrays with scratch buffers. (Explicit types only — no ':=' inferred typing.)

# --- Dewpoint / condensation tuning (own copies of the 2.5D constants; see LAMaterialAtmosphere) ---
const SAT_BASE: float = 0.06              # saturation vapor at EVAP_TEMP_REF (lower -> condenses sooner)
const SAT_TEMP_GAIN: float = 0.055        # warmer air holds exponentially more vapor before condensing
const EVAP_TEMP_REF: float = 22.0         # reference temperature the saturation curve is anchored at
const CONDENSE_RATE: float = 0.30         # fraction of past-dewpoint (super-saturated) vapor -> condensate/step
const CLOUD_REEVAP_RATE: float = 0.12     # fraction of cloud/fog -> vapor/step when the air is sub-saturated
const CLOUD_DECAY: float = 0.006          # baseline condensate dissipation/step (keeps it from piling up forever)
const RAIN_CLOUD_THRESHOLD: float = 0.45  # cloud density above which a cell precipitates
const RAIN_RATE: float = 0.16             # fraction of above-threshold cloud -> ground water/step

# --- Transport tuning (3D generalisation of the 2.5D diffusion + wind, plus buoyant rise) ---
const VAPOR_DIFFUSE: float = 0.14         # isotropic vapor spread per step
const CLOUD_DIFFUSE: float = 0.06         # clouds spread a little too
const FOG_DIFFUSE: float = 0.03           # fog spreads least (ground-hugging, sluggish)
const DIFF6: float = 1.0 / 6.0            # per-neighbour weight for the 6-neighbour isotropic diffusion
const VAPOR_RISE: float = 0.10            # share of a cell's vapor convected UP each step (humid air rises)
const CLOUD_RISE: float = 0.04            # clouds drift up too, but slower than the vapor feeding them
const VAPOR_WIND_GAIN: float = 1.0        # horizontal wind advection gain for vapor
const CLOUD_WIND_GAIN: float = 1.0        # ...for cloud
const FOG_WIND_GAIN: float = 0.5          # ...for fog (ground drag: drifts slower)

# --- Humidity source + phase placement ---
const EVAP_RATE: float = 0.02             # vapor added per step at a warm exposed water surface (humidity source)
const WATER_MIN: float = 0.05             # a cell counts as "wet" (an evaporating water surface) above this
const FOG_MAX_TEMP: float = 12.0          # only cells cooler than this (°C) pool condensate as ground FOG
const FOG_GROUND_CELLS: int = 2           # a cell is "near the ground" if solid/water lies within this many cells below

# --- Rendered-sheet heights (the CloudLayer draws a flat sheet at these; unchanged from 2.5D) ---
const CLOUD_BASE_ABOVE_SEA: float = 62.0  # world-Y of the rendered cloud sheet, above sea level
const FOG_BASE_ABOVE_SEA: float = 6.0     # world-Y of the ground-hugging fog sheet, above sea level

const MIN_VAPOR: float = 1.0e-6           # dewpoint guard: vapor at/below this has no meaningful dewpoint
const SAT_EPS: float = 1.0e-9             # divide-by-zero guard for relative humidity

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _adelta: PackedFloat32Array = PackedFloat32Array()   # scratch for one transport pass
var _cloud_col: PackedFloat32Array = PackedFloat32Array()# per-XZ column max cloud (renderer 2D projection)
var _fog_col: PackedFloat32Array = PackedFloat32Array()  # per-XZ column max fog (renderer 2D projection)
var _wind: Vector2 = Vector2.ZERO                        # world XZ wind (x=+X, y=+Z) drifting airborne matter
var _cloud_cover: float = 0.0                            # cached mean cloud density (sun dimming / HUD)
var _fog_cover: float = 0.0                              # cached mean fog density


func setup(field) -> void:
	_f = field
	_adelta = PackedFloat32Array()
	_adelta.resize(_f._cell_count)
	var layer: int = _f._dim_x * _f._dim_z
	_cloud_col = PackedFloat32Array()
	_cloud_col.resize(layer)
	_fog_col = PackedFloat32Array()
	_fog_col.resize(layer)


# --- Transport ---------------------------------------------------------------

## Move one airborne field (vapor / cloud / fog): 6-neighbour isotropic diffusion (symmetric +X/+Y/+Z
## pairs so it is order-independent), plus buoyant UPWARD advection (humid air rises) and horizontal
## upwind advection by the wind. All accumulated into `_adelta`, then applied. Matter only moves between
## non-solid cells (rock is a wall to air just as it is to water).
func _transport(arr: PackedFloat32Array, diffuse_frac: float, rise_frac: float, wind_gain: float) -> void:
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var solid: PackedByteArray = _f._solid
	for k in range(_f._cell_count):
		_adelta[k] = 0.0

	# 1) DIFFUSION — forward pairs only (+X, +Z, +Y); the back-neighbour gets the opposite flux, so the
	# exchange is symmetric and the result is independent of iteration order.
	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					continue
				var q: float = arr[i]
				if ix < dx - 1:
					var ri: int = i + 1
					if solid[ri] == 0:
						var fx: float = (q - arr[ri]) * diffuse_frac * DIFF6
						_adelta[i] -= fx
						_adelta[ri] += fx
				if iz < dz - 1:
					var rz: int = i + dx
					if solid[rz] == 0:
						var fz: float = (q - arr[rz]) * diffuse_frac * DIFF6
						_adelta[i] -= fz
						_adelta[rz] += fz
				if iy < dy - 1:
					var ru: int = i + layer
					if solid[ru] == 0:
						var fy: float = (q - arr[ru]) * diffuse_frac * DIFF6
						_adelta[i] -= fy
						_adelta[ru] += fy

	# 2) BUOYANT RISE — a share of each cell's matter is convected straight up into the void cell above
	# (this is what lifts humid air to the cool heights where it condenses into cloud).
	if rise_frac > 0.0:
		for iy in range(dy - 1):
			for iz in range(dz):
				for ix in range(dx):
					var i2: int = (iy * dz + iz) * dx + ix
					if solid[i2] != 0:
						continue
					var q2: float = arr[i2]
					if q2 <= 0.0:
						continue
					var iu: int = i2 + layer
					if solid[iu] != 0:
						continue
					var mv: float = q2 * rise_frac
					_adelta[i2] -= mv
					_adelta[iu] += mv

	# 3) HORIZONTAL WIND — first-order upwind advection in world XZ (drifts clouds/vapor downwind).
	if wind_gain > 0.0 and (_wind.x != 0.0 or _wind.y != 0.0):
		var cs: float = _f._cell_size
		var ax: float = clampf(absf(_wind.x) * wind_gain * _f.STEP_DT / cs, 0.0, 0.5)
		var az: float = clampf(absf(_wind.y) * wind_gain * _f.STEP_DT / cs, 0.0, 0.5)
		var sx: int = 1 if _wind.x > 0.0 else -1
		var sz: int = 1 if _wind.y > 0.0 else -1
		for iy in range(dy):
			for iz in range(dz):
				for ix in range(dx):
					var i3: int = (iy * dz + iz) * dx + ix
					if solid[i3] != 0:
						continue
					var q3: float = arr[i3]
					if q3 <= 0.0:
						continue
					if ax > 0.0:
						var nx: int = ix + sx
						if nx >= 0 and nx < dx:
							var nix: int = i3 + sx
							if solid[nix] == 0:
								var mvx: float = q3 * ax
								_adelta[i3] -= mvx
								_adelta[nix] += mvx
					if az > 0.0:
						var nz: int = iz + sz
						if nz >= 0 and nz < dz:
							var niz: int = i3 + sz * dx
							if solid[niz] == 0:
								var mvz: float = q3 * az
								_adelta[i3] -= mvz
								_adelta[niz] += mvz

	for k2 in range(_f._cell_count):
		if solid[k2] != 0:
			continue
		var v: float = arr[k2] + _adelta[k2]
		arr[k2] = v if v > 0.0 else 0.0


# --- The 3D atmosphere step (evaporation -> transport -> dewpoint condensation -> rain) --------------

## One atmosphere step:
##   1) EVAPORATION feeds humidity: a warm, exposed water surface releases vapor into its own cell.
##   2) TRANSPORT drifts/rises/spreads vapor, cloud and fog in 3D.
##   3) DEWPOINT CONDENSATION per void cell: vapor past that cell's dewpoint condenses (into FOG if the
##      cell is cool AND near the ground, else into CLOUD aloft); sub-saturated air re-evaporates it.
##   4) PRECIPITATION: cells whose cloud exceeds the threshold rain water toward the ground.
## Clouds forming aloft over cool heights, fog pooling in cool low cells, and rain feeding the water all
## fall out of these local rules — no per-case scripting.
func step() -> void:
	if _f._cell_count <= 0:
		return
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var solid: PackedByteArray = _f._solid
	var temp: PackedFloat32Array = _f._temp
	var vapor: PackedFloat32Array = _f._vapor
	var cloud: PackedFloat32Array = _f._cloud
	var fog: PackedFloat32Array = _f._fog
	var water: PackedFloat32Array = _f._water
	var stat: PackedByteArray = _f._static
	var max_mass: float = _f.MAX_MASS

	# 1) EVAPORATION (humidity source). A wet cell with open air above (the air/water interface) releases
	# vapor into its own cell, more when warm. Buried water (rock or full water directly above) does not
	# evaporate, so only surfaces — sea top, lake/river top, wet cavern floors under air — feed humidity.
	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var wi: int = (iy * dz + iz) * dx + ix
				if solid[wi] != 0:
					continue
				if water[wi] <= WATER_MIN and stat[wi] == 0:
					continue
				var open_above: bool = true
				if iy < dy - 1:
					var au: int = wi + layer
					open_above = solid[au] == 0 and water[au] < max_mass * 0.5
				if not open_above:
					continue
				var warmth: float = clampf(temp[wi] / EVAP_TEMP_REF, 0.0, 2.0)
				vapor[wi] += EVAP_RATE * warmth

	# 2) TRANSPORT — vapor rises fastest, cloud drifts up slower, fog hugs the ground (no rise, ground drag).
	_transport(vapor, VAPOR_DIFFUSE, VAPOR_RISE, VAPOR_WIND_GAIN)
	_transport(cloud, CLOUD_DIFFUSE, CLOUD_RISE, CLOUD_WIND_GAIN)
	_transport(fog, FOG_DIFFUSE, 0.0, FOG_WIND_GAIN)

	# Reset the renderer's 2D projections for this step's column maxima.
	for c in range(layer):
		_cloud_col[c] = 0.0
		_fog_col[c] = 0.0

	# 3) + 4) CONDENSATION + PRECIPITATION per void cell.
	var cloud_sum: float = 0.0
	var fog_sum: float = 0.0
	var void_cells: int = 0
	for iy2 in range(dy):
		for iz2 in range(dz):
			for ix2 in range(dx):
				var i: int = (iy2 * dz + iz2) * dx + ix2
				if solid[i] != 0:
					continue
				void_cells += 1
				var t: float = temp[i]
				var vap: float = vapor[i]
				# Dewpoint saturation for THIS cell's real temperature. Warmer cells hold exponentially
				# more vapor; the cool cells aloft (heat's lapse) hold little, so rising humid air passes
				# its dewpoint up there and condenses. No hardcoded "cloud base" offset — real altitude.
				var sat: float = SAT_BASE * exp(SAT_TEMP_GAIN * (t - EVAP_TEMP_REF))
				if vap > sat:
					# Past the dewpoint: condense a fraction of the excess. It pools as FOG when this cell
					# is cool AND resting near the terrain/sea; otherwise it forms CLOUD (mid-air aloft).
					var cond: float = (vap - sat) * CONDENSE_RATE
					vapor[i] = vap - cond
					if t < FOG_MAX_TEMP and _near_ground(i, iy2, dy, layer, solid, water, stat):
						fog[i] += cond
					else:
						cloud[i] += cond
				else:
					# Sub-saturated: the air can hold more, so existing condensate re-evaporates to vapor.
					var fr: float = fog[i] * CLOUD_REEVAP_RATE
					var cr: float = cloud[i] * CLOUD_REEVAP_RATE
					fog[i] -= fr
					cloud[i] -= cr
					vapor[i] = vap + fr + cr
				# Baseline dissipation so condensate never accumulates without bound.
				cloud[i] *= (1.0 - CLOUD_DECAY)
				fog[i] *= (1.0 - CLOUD_DECAY)
				# PRECIPITATION — thick cloud rains its excess as water toward the ground (into the cell
				# below when that is open, so the water CA's gravity carries the drop down and it joins the
				# surface water / rivers / sea). Closes the cycle.
				if cloud[i] > RAIN_CLOUD_THRESHOLD:
					var rain: float = (cloud[i] - RAIN_CLOUD_THRESHOLD) * RAIN_RATE
					cloud[i] -= rain
					var target: int = i
					if iy2 > 0:
						var ib: int = i - layer
						if solid[ib] == 0:
							target = ib
					water[target] += rain
				cloud_sum += cloud[i]
				fog_sum += fog[i]
				var col: int = iz2 * dx + ix2
				if cloud[i] > _cloud_col[col]:
					_cloud_col[col] = cloud[i]
				if fog[i] > _fog_col[col]:
					_fog_col[col] = fog[i]

	var denom: float = maxf(1.0, float(void_cells))
	_cloud_cover = cloud_sum / denom
	_fog_cover = fog_sum / denom


# A cell is "near the ground" (so its condensate pools as fog) if solid rock, standing water, or the
# static sea lies within FOG_GROUND_CELLS cells directly below it — i.e. it rests on the terrain/sea.
func _near_ground(i: int, iy: int, dy: int, layer: int, solid: PackedByteArray, water: PackedFloat32Array, stat: PackedByteArray) -> bool:
	for d in range(1, FOG_GROUND_CELLS + 1):
		var jy: int = iy - d
		if jy < 0:
			return true                                  # bottom of the world reads as ground
		var jb: int = i - d * layer
		if solid[jb] != 0 or stat[jb] != 0 or water[jb] > WATER_MIN:
			return true
	return false


# --- Wind --------------------------------------------------------------------

## Set the current wind (world XZ; x=+X, y=+Z) so airborne matter drifts downwind. Fed from the weather.
func set_wind(w: Vector2) -> void:
	if is_nan(w.x) or is_nan(w.y) or is_inf(w.x) or is_inf(w.y):
		return
	_wind = w


func wind() -> Vector2:
	return _wind


# --- Index helpers (world -> grid cell) --------------------------------------

func _cix(x: float) -> int:
	return clampi(int(round((x - _f._origin.x) / _f._cell_size)), 0, _f._dim_x - 1)


func _ciz(z: float) -> int:
	return clampi(int(round((z - _f._origin.z) / _f._cell_size)), 0, _f._dim_z - 1)


func _ciy(y: float) -> int:
	return clampi(int(round((y - _f._origin.y) / _f._cell_size)), 0, _f._dim_y - 1)


# Topmost non-solid cell of a column (its sky-exposed surface), or 0 if the column is solid to the top.
func _surface_iy(ix: int, iz: int) -> int:
	for iy in range(_f._dim_y - 1, -1, -1):
		if _f._solid[(iy * _f._dim_z + iz) * _f._dim_x + ix] == 0:
			return iy
	return 0


# Cell index for a world (x, z) and optional world y; NAN y resolves to the column's exposed surface cell.
func _query_index(x: float, z: float, y: float) -> int:
	var ix: int = _cix(x)
	var iz: int = _ciz(z)
	var iy: int = _ciy(y) if not is_nan(y) else _surface_iy(ix, iz)
	return (iy * _f._dim_z + iz) * _f._dim_x + ix


# --- Humidity / dewpoint queries ---------------------------------------------

## Relative humidity at a cell = vapor / saturation-at-that-cell's-temperature. 1.0 means the air is
## exactly at its dewpoint (saturated); above 1.0 it is super-saturated and condensing. NAN y uses the
## surface column cell.
func relative_humidity_at(x: float, z: float, y: float = NAN) -> float:
	var idx: int = _query_index(x, z, y)
	var t: float = _f._temp[idx]
	var sat: float = SAT_BASE * exp(SAT_TEMP_GAIN * (t - EVAP_TEMP_REF))
	return _f._vapor[idx] / maxf(SAT_EPS, sat)


## Dewpoint (°C) at a cell: the temperature at which the cell's CURRENT vapor would exactly saturate.
## Invert the saturation curve  sat = SAT_BASE * exp(SAT_TEMP_GAIN * (T - EVAP_TEMP_REF))  for T at
## sat = vapor  ->  T = EVAP_TEMP_REF + ln(vapor / SAT_BASE) / SAT_TEMP_GAIN. Guarded for vapor <= 0.
func dewpoint_at(x: float, z: float, y: float = NAN) -> float:
	var idx: int = _query_index(x, z, y)
	var vap: float = _f._vapor[idx]
	if vap < MIN_VAPOR:
		vap = MIN_VAPOR                                  # dry air: report the (very cold) floor dewpoint
	return EVAP_TEMP_REF + log(vap / SAT_BASE) / SAT_TEMP_GAIN


# --- Condensate queries (2.5D-compatible signatures the renderer / rain layer call) ------------------

## Max cloud density in the XZ column at (x, z) — the thickest cloud overhead (drives rain / dimming).
func cloud_at(x: float, z: float) -> float:
	var ix: int = _cix(x)
	var iz: int = _ciz(z)
	var m: float = 0.0
	for iy in range(_f._dim_y):
		var c: float = _f._cloud[(iy * _f._dim_z + iz) * _f._dim_x + ix]
		if c > m:
			m = c
	return m


## Max fog density in the XZ column at (x, z) (fog lives in the low cells).
func fog_at(x: float, z: float) -> float:
	var ix: int = _cix(x)
	var iz: int = _ciz(z)
	var m: float = 0.0
	for iy in range(_f._dim_y):
		var g: float = _f._fog[(iy * _f._dim_z + iz) * _f._dim_x + ix]
		if g > m:
			m = g
	return m


## Mean cloud / fog density over void cells — global sun dimming and HUD/diagnostics.
func avg_cloud_cover() -> float:
	return _cloud_cover


func avg_fog_cover() -> float:
	return _fog_cover


## Flat 2D (XZ) density projections for the CloudLayer render textures — index = iz * dim_x + ix, each
## entry the column's max cloud/fog. Sized dim_x * dim_z so it matches the renderer's dim*dim texture
## (the field's XZ dims are equal). Returned by reference; the renderer only reads them.
func cloud_grid() -> PackedFloat32Array:
	return _cloud_col


func fog_grid() -> PackedFloat32Array:
	return _fog_col


## Diagnostic: number of void cells whose cloud density is at least min_density.
func cloud_cell_count(min_density: float = 0.05) -> int:
	var n: int = 0
	for i in range(_f._cell_count):
		if _f._solid[i] == 0 and _f._cloud[i] >= min_density:
			n += 1
	return n


## World Y of the two rendered condensate sheets (above the field's sea level).
func cloud_base_y() -> float:
	return _f._sea_level + CLOUD_BASE_ABOVE_SEA


func fog_base_y() -> float:
	return _f._sea_level + FOG_BASE_ABOVE_SEA
