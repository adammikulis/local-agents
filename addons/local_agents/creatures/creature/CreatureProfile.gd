class_name LACreatureProfile
extends RefCounted

## Per-subsystem PROFILING for the LocalAgentCreature hot path (a dev tool), factored out of the main brain.
##
## Gated by Engine meta "la_prof" (default off) or the LA_PROF environment variable, so there is zero meaningful cost
## when off. It accumulates each phase's microseconds across ALL creatures and emits avg ms/physics-frame to
## SIM_REPORT (cr_meta_ms / cr_terrain_ms / cr_glue_ms / cr_think_ms / cr_move_ms), so a headless offscreen
## run prints the creature hot-path breakdown with no GUI profiler.
##
## The first creature to tick calls ensure(), which registers the report provider once (a static Callable, so
## it is not pruned when any one creature frees) and returns whether profiling is on, and the caller keeps that
## in a local so the per-phase guards stay a plain boolean test.
## (Explicit types only, no ':=' inferred typing.)

static var on: bool = false
static var _registered: bool = false
static var _us: Dictionary = {}
static var _last_frame: int = 0


## Register the SIM_REPORT provider on the first call, and report whether profiling is enabled. Called once
## per creature physics tick; the caller holds the result in a local for this frame's phase guards.
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
