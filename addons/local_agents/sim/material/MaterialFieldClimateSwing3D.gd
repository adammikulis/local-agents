class_name LAMaterialFieldClimateSwing3D
extends RefCounted

## LAMaterialFieldClimateSwing3D — DOES THIS PLANET HAVE A DAY, AND DOES IT HAVE SEASONS?
##
## Both were unanswerable before this. LASystemOrbits integrates a real tilted orbit and LASimClock names the
## seasons, but NOTHING measured the temperature swing either one produces, so "we have seasons" rested on the
## existence of the code that ought to cause them. That is the same evidentiary mistake as a dead `@export`:
## the mechanism is plumbed, looks correct, and is never observed to do anything.
##
## THE BAND STATISTIC IS A MEDIAN, NOT A MEAN, AND THAT WAS A MEASUREMENT NOT A PREFERENCE. The first run of
## this instrument (seed 4242, 600 frames) reported a diurnal range of 352.67 °C for the 30-45 degree band
## against 4-21 °C for the other five. One of that band's eight stations had been overrun by a lava flow, and
## with eight samples per band a single magmatic station moves the MEAN by forty times the signal. A median
## over eight is unmoved by one outlier and is the same number when there is none, so it costs nothing on a
## quiet planet and does not lie on a volcanic one. `swing_diurnal_max_c` keeps the outlier visible rather
## than throwing it away — an eruption at a weather station is a real event, it is just not a diurnal cycle.
##
## A LATITUDE BAND'S MEAN CANNOT SHOW A DIURNAL CYCLE, AND THIS IS THE WHOLE DESIGN CONSTRAINT. A band circles
## the planet, so at every instant half of it is in daylight and half in night and its mean is nearly flat all
## day. The diurnal range lives at a PLACE, not in an average over longitude. So this module plants WEATHER
## STATIONS: a fixed set of ground cells, chosen once, spread over longitude within each latitude band. The
## field grid is body-local, so a fixed cell index is a fixed place on the planet, and it carries that place
## through day and night exactly as a thermometer bolted to the ground would.
##   * DIURNAL range per band = the mean over that band's stations of each station's own (max - min) within
##     one rotation. That is the meteorological definition, not a max-minus-min over a mixture of places.
##   * LONG range per band = the same over the last LONG_DAYS completed rotations, so seasonal drift shows up
##     as a long range that exceeds the diurnal one.
##
## THE DAY IS MEASURED, NOT ASSUMED, and it had to be, because the two constants that claim to define it
## disagree by a factor of three. `LASimClock.DAY_LENGTH` is 200.0 s; the planet actually turns at
## `LAVoxelWorld.PLANET_SPIN_RATE` 0.10 rad/s, which is a rotation every 62.83 s (the solar kernel's own
## comment says "a ~63 s rotation"). So this tracks the ANGLE THE SUN SWEEPS in the field's frame and calls a
## day a full turn — the same quantity that actually makes the terminator move — and reports the period it
## measures rather than trusting either number.
##
## THE SEASON IS SPIN-INVARIANT AND IS COMPUTED IN THE WORLD FRAME. Sub-solar latitude is
## `asin(dot(sun_hat, spin_axis_hat))`: the planet turning about its own axis does not change it, and only the
## orbit does. Its running min and max ARE the measured axial tilt — the planet's obliquity, read off the
## instrument instead of off the constant that set it up (`PLANET_SPIN_AXIS` is 23.5 degrees off +Y). A year
## is ~670 s against a ~63 s day, so a run has to cover roughly 10 days before the swing means anything, and
## `swing_days` says whether it did.
##
## Costs O(stations) per sample — 48 array reads — plus two full-grid scans ONCE, at station-siting time.
## Bands, the spin axis and the latitude convention are taken from LAMaterialFieldReport3D so the bands here
## are literally the bands `surface_climate()` reports, not a parallel definition that can drift from them.
## (Explicit types only, no ':=' inferred typing.)

const BANDS: int = LAMaterialFieldReport3D.CLIMATE_BANDS       # 15 degrees per band, equator-first
const STATIONS_PER_BAND: int = 8                               # longitude spread within a band
const LONG_DAYS: int = 8                                       # rotations held in the long window
## A sample that jumps more than this much sun-angle has under-sampled the rotation and the day boundary it
## implies is unreliable. Counted rather than hidden: an aliased run must not read as a measured one.
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
# slots hold a real observation: a station buried by lava or an impact contributes NOTHING to that day rather
# than a zero, which would otherwise read as a station that spent a day at 0 C.
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
	if _f == null or _f._sphere == null or _f._cell_count <= 0:
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
		# The measured rotation period, on the two clocks that disagree about it. `swing_day_s` is the
		# scene's own elapsed time (LASimClock, the clock the body spin integrates against); expect ~62.8 s,
		# NOT the 200.0 s LASimClock calls a day. `swing_day_field_s` is how much of the FIELD's simulated
		# time one rotation covers, which is what actually sets the depth of the night-side cooling — and it
		# is not a constant, because the field and the idle clock advance at different rates under `--fast`.
		"swing_day_s": snappedf(_day_period_s, 0.01),
		"swing_day_field_s": snappedf(_day_period_field_s, 0.01),
		"swing_samples_per_day": snappedf(_samples_per_day, 0.1),
		"swing_alias_samples": _alias,
		# Sub-solar latitude: the season, in degrees, and its running extremes — the planet's obliquity as
		# MEASURED. A run shorter than a year cannot reach the full swing; read it against `swing_days`.
		"swing_subsolar_lat": snappedf(_subsolar_lat, 0.01),
		"swing_subsolar_min": snappedf(_subsolar_min if _subsolar_min < 1.0e19 else 0.0, 0.01),
		"swing_subsolar_max": snappedf(_subsolar_max if _subsolar_max > -1.0e19 else 0.0, 0.01),
		"swing_season": clock.season() if clock != null else "",
		"swing_stations": _cells.size(),
	}


# --- Stations ----------------------------------------------------------------------------------------------

## Plant the network, once. Two passes: count the ground-hugging cells per latitude band, then take every
## k-th so the stations spread across the band instead of clustering on whichever face is enumerated first.
##
## GROUND-HUGGING (open, with solid rock directly inward) is `surface_climate()`'s land set and the solar
## kernel's `ground_hug` — where snow deposits and where a creature stands. Latitude uses the same world
## position and the same world spin axis that module uses, so a station's band is its band there too.
## Latitude is invariant under the planet's own rotation (the body turns about that exact axis), so siting
## the network once is exact rather than a snapshot of where things happened to be.
func _site_stations() -> void:
	var cc: int = _f._cell_count
	var depth: int = int(_f._sphere.depth)
	var solid: PackedByteArray = _f._solid
	if depth <= 0 or solid.size() != cc:
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
		var r: int = c % depth
		if r <= 0 or solid[c - 1] == 0:
			continue                                     # not ground: no rock beneath
		var p: Vector3 = _f.cell_world_pos_linear(c) - _f._origin
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

## Accumulate the sun's swept angle about the spin axis IN THE FIELD'S FRAME (where the planet's rotation is
## what moves it), and close a day when it completes a turn. Also updates the sub-solar latitude, which is
## computed in the WORLD frame because there the spin does not enter it at all.
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
