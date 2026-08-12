class_name LAMaterialFieldClimateSwing3D
extends RefCounted


const BANDS: int = LAMaterialFieldReport3D.CLIMATE_BANDS       # 15 degrees per band, equator-first
const STATIONS_PER_BAND: int = 8                               # longitude spread within a band
const LONG_DAYS: int = 8                                       # rotations held in the long window
## A sample that jumps more than this much sun-angle has under-sampled the rotation and the day boundary it
const ALIAS_LIMIT: float = PI * 0.5
## Process frames between siting attempts while there is still no land to site on (pre-spawn, or a headless
## field with no terrain). Without it a world that never grows ground pays two full-grid scans per report.
const SITE_RETRY_FRAMES: int = 60


var _f = null
var _cells: PackedInt32Array = PackedInt32Array()      # station cell index
var _band: PackedInt32Array = PackedInt32Array()       # station -> latitude band
var _sited: bool = false
var _site_frame: int = -1_000_000                      # process frame of the last siting attempt

# Per-station accumulators for the rotation in progress.
var _day_min: PackedFloat32Array = PackedFloat32Array()
var _day_max: PackedFloat32Array = PackedFloat32Array()
var _day_seen: PackedInt32Array = PackedInt32Array()

# Per-station ring of the last LONG_DAYS completed rotations (min and max of each). `_ring_ok` marks which
# slots hold a real observation: a station buried by lava or an impact contributes nothing to that day.
var _ring_min: PackedFloat32Array = PackedFloat32Array()
var _ring_max: PackedFloat32Array = PackedFloat32Array()
var _ring_ok: PackedByteArray = PackedByteArray()
var _ring_head: int = 0
var _ring_filled: int = 0

var _diurnal: Array = []                               # last completed rotation's MEDIAN station range, per band
var _diurnal_max: Array = []                           # and its worst single station — the outlier, kept visible
var _long: Array = []                                  # median range over the ring, per band

# Day tracking, from the swept sun angle.
var _prev_sun: Vector3 = Vector3.ZERO
var _swept: float = 0.0
var _days: int = 0
var _samples: int = 0
var _samples_this_day: int = 0
var _samples_per_day: float = 0.0
var _alias: int = 0
var _day_start_s: float = -1.0
var _day_start_field_s: float = -1.0
var _day_period_s: float = 0.0
var _day_period_field_s: float = 0.0

# Season.
var _subsolar_lat: float = 0.0
var _subsolar_min: float = 1.0e20
var _subsolar_max: float = -1.0e20


func setup(field) -> void:
	_f = field
	_diurnal.resize(BANDS)
	_diurnal_max.resize(BANDS)
	_long.resize(BANDS)
	for b in BANDS:
		_diurnal[b] = 0.0
		_diurnal_max[b] = 0.0
		_long[b] = 0.0


## One observation. Called from the report provider, so its cadence is whatever the snapshot cadence is;
## `swing_samples_per_day` reports what that worked out to, which is the number that says whether the diurnal
## range below is resolved or aliased.
func sample() -> void:
	if _f == null or _f._grid == null or _f._cell_count <= 0:
		return
	if not _sited:
		var frame: int = int(Engine.get_process_frames())
		if frame - _site_frame < SITE_RETRY_FRAMES:
			return
		_site_frame = frame
		_site_stations()
		if not _sited:
			return
	_samples += 1
	_samples_this_day += 1
	_read_stations()
	_advance_day()


func report() -> Dictionary:
	var clock: LASimClock = LASimClock.active()
	return {
		# Equator-first, matching `clim_lat_mean`: [0] is 0-15 degrees, [BANDS-1] is 75-90. Duplicated so the
		# emitted snapshot is a value, not a live reference this module goes on mutating.
		"swing_diurnal_c": _diurnal.duplicate(),
		"swing_diurnal_max_c": _diurnal_max.duplicate(),
		"swing_long_c": _long.duplicate(),
		"swing_days": _days,
		"swing_long_window_days": _ring_filled,
		"swing_samples": _samples,
		"swing_day_s": snappedf(_day_period_s, 0.01),
		"swing_day_field_s": snappedf(_day_period_field_s, 0.01),
		"swing_samples_per_day": snappedf(_samples_per_day, 0.1),
		"swing_alias_samples": _alias,
		# Sub-solar latitude: the season, in degrees, and its running extremes — the planet's obliquity as
		"swing_subsolar_lat": snappedf(_subsolar_lat, 0.01),
		"swing_subsolar_min": snappedf(_subsolar_min if _subsolar_min < 1.0e19 else 0.0, 0.01),
		"swing_subsolar_max": snappedf(_subsolar_max if _subsolar_max > -1.0e19 else 0.0, 0.01),
		"swing_season": clock.season() if clock != null else "",
		"swing_stations": _cells.size(),
	}


# --- Stations ----------------------------------------------------------------------------------------------

func _site_stations() -> void:
	var cc: int = _f._cell_count
	var solid: PackedByteArray = _f._solid
	if solid.size() != cc:
		return
	var axis: Vector3 = LAMaterialFieldReport3D.PLANET_SPIN_AXIS.normalized()
	var counts: PackedInt32Array = PackedInt32Array()
	counts.resize(BANDS)
	var band_of: PackedInt32Array = PackedInt32Array()
	band_of.resize(cc)
	for c in cc:
		band_of[c] = -1
		if solid[c] != 0:
			continue
		var lo: int = LAFieldGeometry.below(_f, c)
		if lo < 0 or solid[lo] == 0:
			continue                                     # not ground: no rock beneath
		var p: Vector3 = _f.cell_world_pos_linear(c) - _f.centre()
		var radius: float = p.length()
		if radius < 0.001:
			continue
		var lat: float = absf(rad_to_deg(asin(clampf(p.dot(axis) / radius, -1.0, 1.0))))
		var b: int = clampi(int(lat / (90.0 / float(BANDS))), 0, BANDS - 1)
		band_of[c] = b
		counts[b] += 1
	var stride: PackedInt32Array = PackedInt32Array()
	stride.resize(BANDS)
	for b in BANDS:
		stride[b] = maxi(1, counts[b] / STATIONS_PER_BAND)
	var seen: PackedInt32Array = PackedInt32Array()
	seen.resize(BANDS)
	var taken: PackedInt32Array = PackedInt32Array()
	taken.resize(BANDS)
	for c in cc:
		var b: int = band_of[c]
		if b < 0:
			continue
		var idx: int = seen[b]
		seen[b] = idx + 1
		if taken[b] >= STATIONS_PER_BAND or idx % stride[b] != 0:
			continue
		taken[b] += 1
		_cells.append(c)
		_band.append(b)
	var n: int = _cells.size()
	if n <= 0:
		return                                           # no land yet (pre-spawn) — try again next sample
	_day_min.resize(n)
	_day_max.resize(n)
	_day_seen.resize(n)
	_ring_min.resize(n * LONG_DAYS)
	_ring_max.resize(n * LONG_DAYS)
	_ring_ok.resize(n * LONG_DAYS)
	_reset_day()
	_sited = true


func _read_stations() -> void:
	var temp: PackedFloat32Array = _f._temp
	var solid: PackedByteArray = _f._solid
	var cc: int = _f._cell_count
	if temp.size() != cc or solid.size() != cc:
		return
	for i in _cells.size():
		var c: int = _cells[i]
		# A station can be buried by lava, an impact or rock growth — `solid` is re-derived every step. Skip
		# it while that lasts rather than recording a rock temperature as a surface air temperature.
		if solid[c] != 0:
			continue
		var t: float = temp[c]
		if _day_seen[i] == 0:
			_day_min[i] = t
			_day_max[i] = t
			_day_seen[i] = 1
			continue
		_day_min[i] = minf(_day_min[i], t)
		_day_max[i] = maxf(_day_max[i], t)


func _reset_day() -> void:
	for i in _cells.size():
		_day_seen[i] = 0
		_day_min[i] = 0.0
		_day_max[i] = 0.0


# --- The day, and the season -------------------------------------------------------------------------------

## Accumulate the sun's swept angle about the spin axis in the FIELD frame and close a day at a full turn.
## The sub-solar latitude is computed in the WORLD frame, where the spin does not enter it.
func _advance_day() -> void:
	var sun_world: Vector3 = Vector3.ZERO
	if _f._sun_light != null:
		sun_world = _f._sun_light.global_transform.basis.z
	if sun_world.length() < 0.001:
		return                                           # no sun in the scene: no day, and nothing to measure
	sun_world = sun_world.normalized()
	var world_axis: Vector3 = LAMaterialFieldReport3D.PLANET_SPIN_AXIS.normalized()
	_subsolar_lat = rad_to_deg(asin(clampf(sun_world.dot(world_axis), -1.0, 1.0)))
	_subsolar_min = minf(_subsolar_min, _subsolar_lat)
	_subsolar_max = maxf(_subsolar_max, _subsolar_lat)

	var axis: Vector3 = _f.dir_to_field(world_axis).normalized()
	var cur: Vector3 = _f.dir_to_field(sun_world)
	cur = (cur - axis * cur.dot(axis))                   # project onto the equatorial plane: the daily component
	if cur.length() < 0.001:
		return                                           # sun over the pole — no azimuth to sweep
	cur = cur.normalized()
	if _prev_sun.length() < 0.001:
		_prev_sun = cur
		_day_start_s = _clock_s()
		_day_start_field_s = LASimReport.gauge_cur("field_sim_s", 0.0)
		return
	var step: float = atan2(axis.dot(_prev_sun.cross(cur)), _prev_sun.dot(cur))
	_prev_sun = cur
	if absf(step) > ALIAS_LIMIT:
		_alias += 1
	_swept += absf(step)
	if _swept < TAU:
		return
	_swept -= TAU
	_close_day()


func _clock_s() -> float:
	var clock: LASimClock = LASimClock.active()
	return clock.elapsed() if clock != null else 0.0


## A rotation completed: publish the diurnal range, push each station's day into the long ring, recompute the
## long-window range, and start the next day.
func _close_day() -> void:
	var n: int = _cells.size()
	var per_band: Array = []
	for b in BANDS:
		per_band.append(PackedFloat32Array())
	for i in n:
		var slot: int = i * LONG_DAYS + _ring_head
		if _day_seen[i] == 0:
			_ring_ok[slot] = 0                           # buried this rotation — contribute nothing, not a zero
			continue
		var ranges: PackedFloat32Array = per_band[_band[i]]
		ranges.append(_day_max[i] - _day_min[i])
		per_band[_band[i]] = ranges
		_ring_min[slot] = _day_min[i]
		_ring_max[slot] = _day_max[i]
		_ring_ok[slot] = 1
	for b in BANDS:
		_diurnal[b] = _median(per_band[b])
		_diurnal_max[b] = _peak(per_band[b])
	_ring_head = (_ring_head + 1) % LONG_DAYS
	_ring_filled = mini(_ring_filled + 1, LONG_DAYS)
	_recompute_long()

	var now_s: float = _clock_s()
	var now_field: float = LASimReport.gauge_cur("field_sim_s", 0.0)
	if _day_start_s >= 0.0:
		_day_period_s = now_s - _day_start_s
		_day_period_field_s = now_field - _day_start_field_s
	_day_start_s = now_s
	_day_start_field_s = now_field
	_samples_per_day = float(_samples_this_day)
	_samples_this_day = 0
	_days += 1
	_reset_day()


## Median of a band's station ranges — the robust statistic (see the header: one lava-overrun station moved a
## band's mean by 40x the signal). Empty band -> 0.0, which is what "no stations here" should read as.
func _median(vals: PackedFloat32Array) -> float:
	var n: int = vals.size()
	if n <= 0:
		return 0.0
	var s: PackedFloat32Array = vals.duplicate()
	s.sort()
	return snappedf(s[n / 2], 0.01)


## The band's WORST station range. Kept beside the median because an eruption at a weather station is a real
## event that should be visible, just not averaged into a climate statistic.
func _peak(vals: PackedFloat32Array) -> float:
	var hi: float = 0.0
	for v in vals:
		hi = maxf(hi, v)
	return snappedf(hi, 0.01)


## Long-window range per band: over the completed rotations still in the ring, each station's own extreme
## high minus its own extreme low, averaged across the band's stations. Exceeding the diurnal range is what a
## seasonal (or secular) drift looks like; equalling it means nothing is happening but day and night.
func _recompute_long() -> void:
	var n: int = _cells.size()
	var per_band: Array = []
	for b in BANDS:
		per_band.append(PackedFloat32Array())
	for i in n:
		var lo: float = 1.0e20
		var hi: float = -1.0e20
		for d in LONG_DAYS:
			var slot: int = i * LONG_DAYS + d
			if _ring_ok[slot] == 0:
				continue
			lo = minf(lo, _ring_min[slot])
			hi = maxf(hi, _ring_max[slot])
		if lo > 1.0e19:
			continue
		var ranges: PackedFloat32Array = per_band[_band[i]]
		ranges.append(hi - lo)
		per_band[_band[i]] = ranges
	for b in BANDS:
		_long[b] = _median(per_band[b])
