class_name LACreatureProfile
extends RefCounted


static var on: bool = false
static var _registered: bool = false
static var _us: Dictionary = {}
static var _last_frame: int = 0


static func ensure() -> bool:
	if not _registered:
		_registered = true
		on = bool(Engine.get_meta("la_prof", false)) or OS.has_environment("LA_PROF")
		if on:
			LASimReport.register(LACreatureProfile.report)
	return on


## Credit the microseconds elapsed since `t0` to `bucket`. Only called behind an `if prof:` guard.
static func add(bucket: String, t0: int) -> void:
	_us[bucket] = int(_us.get(bucket, 0)) + (Time.get_ticks_usec() - t0)


## SIM_REPORT provider: average ms per physics frame in each bucket since the last report, then reset.
static func report() -> Dictionary:
	var now: int = int(Engine.get_physics_frames())
	var f: int = maxi(now - _last_frame, 1)
	_last_frame = now
	var out: Dictionary = {}
	for k in _us.keys():
		out["%s_ms" % k] = (float(_us[k]) / 1000.0) / float(f)
	_us = {}
	return out
