class_name LAPlateTectonics
extends Node

## FAKED plate tectonics (the maintainer OK'd faking this one, because true geodynamics is research-grade). The sphere
## is partitioned into N drifting PLATES: a Voronoi partition over random seed directions, each plate slowly
## rotating about its own Euler pole. The plates themselves are scripted, but the GEOLOGY at their boundaries
## EMERGES from the relative-motion kinematics. There is no per-event scripting, just: sample points near plate
## boundaries on a slow cadence, classify the boundary from the two plates' relative velocity, and seed the
## fitting disaster (which is itself an emergent field seed):
##   • CONVERGENT (plates closing) → an arc VOLCANO (subduction melt) + often an EARTHQUAKE.
##   • TRANSFORM (plates grinding past) → an EARTHQUAKE (the fault ruptures).
##   • DIVERGENT (plates pulling apart) → occasionally a rift VENT (volcano).
## As the plates drift, the boundaries migrate, so the Ring of Fire slowly moves. Owned by VoxelWorld (one-line
## add_child); self-ticks on a geological cadence so it's a slow drumbeat, never disaster spam. LA_NO_TECTONICS
## disables it. Explicit types only (no ':=').

const PLATE_COUNT: int = 9
const EVENT_PERIOD: float = 7.0          # seconds between tectonic events (a slow geological drumbeat — not disaster spam)
const SAMPLES_PER_EVENT: int = 10        # boundary points sampled per event; the best-fitting one erupts/quakes
const BOUNDARY_PROBE: float = 0.06       # angular half-width (radians) for detecting a nearby plate boundary
const CONVERGE_MIN: float = 0.25         # |relative-normal velocity| fraction above which it's convergent/divergent
const DRIFT_RATE_MAX: float = 0.02       # max plate angular speed (rad/s) — plates crawl
# ARC VOLCANO at a convergent margin (else just a quake). THIS IS A RARITY ROLL STANDING IN FOR MISSING
# PHYSICS and it is on the list to dissolve — but not yet, and the two comments describing it contradicted
# each other, so here is the actual state.
#
# This line used to say volcanoes "can be frequent again without baking the planet" because subaerial lava
# cools and solidifies, making it a finite heat source. The comment at the call site below said the opposite:
# that the roll is "kept rare so sustained volcanic heat doesn't accumulate and bake the planet". Both were
# written as current fact, 85 lines apart. The value never moved off 0.3 either way, so whichever was right,
# nobody acted on it.
#
# What is true as of 2026-07-30: the premise is real (lava IS a finite heat source now) but the conclusion
# does not follow, because this branch still has NO RADIATIVE SINK. Heat entering the field has nowhere to
# leave, so a sustained source accumulates whether or not each individual flow cools. The sink —
# dT = (absorbed - sigma*eps*T^4)*dt/C — is built on `feature/energy-balance` and has not merged. So the
# call-site comment is the one describing today's code, and this one was aspirational.
#
# REMOVING THIS ROLL IS THE ACCEPTANCE TEST FOR THAT SINK, per the standing rule that a band-aid comes out to
# prove its root is fixed. The measurement that settles it: raise this by a large factor (0.3 -> 1.0, every
# convergent margin erupts) and compare temp_mean and temp_ground_mean at equal field_step across at least
# three runs per arm, quoting eruption counts. If the planet bakes, the sink is not closing; if not, this goes.
const VOLCANO_CHANCE_CONVERGENT: float = 0.3
const VENT_CHANCE_DIVERGENT: float = 0.12       # rift vent

var _terrain = null                      # LAVoxelTerrainService (planet_center/radius, surface_point, sea_radius)
var _disasters = null                    # LAVoxelDisasters (spawn_volcano / spawn_earthquake)

var _seeds: Array = []                   # Array[Vector3] plate seed directions (unit)
var _poles: Array = []                   # Array[Vector3] Euler rotation axis per plate (unit)
var _rates: Array = []                   # Array[float] angular speed per plate (rad/s, signed)
var _cd: float = EVENT_PERIOD
var _enabled: bool = true


func setup(terrain, disasters) -> void:
	_terrain = terrain
	_disasters = disasters
	_enabled = OS.get_environment("LA_NO_TECTONICS") == ""
	for i in range(PLATE_COUNT):
		_seeds.append(_rand_unit())
		_poles.append(_rand_unit())
		# Signed crawl rate, biased away from zero so every plate actually moves.
		var r: float = LASimRng.for_domain("planet").randf_range(0.35, 1.0) * DRIFT_RATE_MAX
		_rates.append(r if LASimRng.for_domain("planet").randf() < 0.5 else -r)


## THE TECTONIC DRUMBEAT RUNS ON THE PHYSICS CLOCK, not the render clock, and that is what makes a seeded run
## reproducible. It used to be `_process`, so `_cd` counted down on RENDER-frame delta while this scene runs at
## 2-3 fps with variable frame times — the number of tectonic events in a fixed `--run-frames=N` therefore
## depended on how long each frame happened to take. Measured before this change, three runs at the SAME
## `--seed=4242`: 2, 7 and 3 impacts and 2, 4 and 0 eruptions. `field_step` was 746 in every one of them, which
## is the tell: the field's own clock is stable across runs and only the render-driven consumers wandered.
## (That 746 belongs to THAT run configuration and is not a constant of the sim. The current acceptance
## configuration — `--run-frames=600 --fast=8 --no-fauna --fixed-fps 60` — gives `field_step` 590, measured
## over eleven runs on 2026-08-03. Quote the flags beside the number, or the next reader A/Bs against the
## wrong horizon.)
func _physics_process(delta: float) -> void:
	if not _enabled or _terrain == null or _disasters == null:
		return
	if not _terrain.has_method("surface_point") or not _terrain.has_method("planet_center"):
		return
	# DRIFT: rotate each plate seed about its Euler pole every frame, so the Voronoi boundaries MIGRATE over time
	# and the Ring of Fire slowly moves (was frozen — the seeds were set once in setup and never integrated).
	for i in range(_seeds.size()):
		_seeds[i] = (_seeds[i] as Vector3).rotated((_poles[i] as Vector3).normalized(), float(_rates[i]) * delta)
	_cd -= delta
	if _cd > 0.0:
		return
	_cd = EVENT_PERIOD
	_fire_boundary_event()


# Sample several random directions; for each that sits on a plate boundary, classify it; act on the strongest
# convergent/transform (Ring-of-Fire) candidate, else a divergent vent. One event per call (throttled).
func _fire_boundary_event() -> void:
	var best_dir: Vector3 = Vector3.ZERO
	var best_kind: String = ""
	var best_score: float = 0.0
	for i in range(SAMPLES_PER_EVENT):
		var p: Vector3 = _rand_unit()
		var a: int = _plate_of(p)
		var b: int = _other_plate_near(p, a)
		if b < 0:
			continue                                     # interior of a plate — no boundary here
		# Relative velocity of the two plates at p, and the boundary normal (from B's seed toward A's seed).
		var v_rel: Vector3 = _plate_velocity(a, p) - _plate_velocity(b, p)
		var normal: Vector3 = _tangent(p, (_seeds[a] as Vector3) - (_seeds[b] as Vector3))
		if normal.length() < 1.0e-5 or v_rel.length() < 1.0e-6:
			continue
		normal = normal.normalized()
		var converge: float = -v_rel.dot(normal)          # >0 A closes on B, <0 they part
		var speed: float = v_rel.length()
		var conv_frac: float = converge / maxf(speed, 1.0e-6)
		var kind: String = ""
		var score: float = 0.0
		if conv_frac > CONVERGE_MIN:
			kind = "convergent"; score = converge
		elif conv_frac < -CONVERGE_MIN:
			kind = "divergent"; score = speed * 0.4       # rifts are lower-priority than the Ring of Fire
		else:
			kind = "transform"; score = speed             # grinding faults
		if score > best_score:
			best_score = score
			best_dir = p
			best_kind = kind
	if best_kind == "" or best_dir == Vector3.ZERO:
		return
	var point: Vector3 = _terrain.surface_point(best_dir)
	if is_nan(point.x):
		return
	if best_kind == "convergent":
		# Quakes are the routine signature of a convergent margin; a full arc VOLCANO is the rare, dramatic
		# event. It is kept rare because the field has no radiative sink yet, so sustained volcanic heat
		# accumulates with nowhere to go — see the constant's own comment for why that is a stand-in awaiting
		# `feature/energy-balance`, and for the measurement that decides when this roll can be deleted.
		_disasters.spawn_earthquake(point)
		if LASimRng.for_domain("planet").randf() < VOLCANO_CHANCE_CONVERGENT:
			_disasters.spawn_volcano(point)
	elif best_kind == "transform":
		_disasters.spawn_earthquake(point)                # the fault ruptures
	else:
		if LASimRng.for_domain("planet").randf() < VENT_CHANCE_DIVERGENT:
			_disasters.spawn_volcano(point)               # a rift vent


# Which plate a unit direction belongs to: the nearest seed by angle (Voronoi on the sphere).
func _plate_of(dir: Vector3) -> int:
	var best: int = 0
	var best_dot: float = -2.0
	for i in range(_seeds.size()):
		var d: float = dir.dot(_seeds[i])
		if d > best_dot:
			best_dot = d
			best = i
	return best


# The nearest DIFFERENT plate found in a small ring around `dir` — i.e. a boundary is close by. -1 if `dir` is
# well inside plate `own` (every ring sample belongs to the same plate).
func _other_plate_near(dir: Vector3, own: int) -> int:
	var t1: Vector3 = _tangent(dir, Vector3.RIGHT)
	if t1.length() < 1.0e-4:
		t1 = _tangent(dir, Vector3.FORWARD)
	t1 = t1.normalized()
	var t2: Vector3 = dir.cross(t1).normalized()
	var best: int = -1
	var best_dot: float = -2.0
	for k in range(6):
		var ang: float = TAU * float(k) / 6.0
		var off: Vector3 = (dir + (t1 * cos(ang) + t2 * sin(ang)) * BOUNDARY_PROBE).normalized()
		var pk: int = _plate_of(off)
		if pk != own:
			var dp: float = dir.dot(_seeds[pk])       # keep the NEAREST differing plate (correct at triple junctions)
			if dp > best_dot:
				best_dot = dp
				best = pk
	return best


# Surface velocity of plate `k` at unit point `p` from its Euler rotation (ω × p).
func _plate_velocity(k: int, p: Vector3) -> Vector3:
	return (_poles[k] as Vector3).cross(p) * float(_rates[k])


# Project vector `v` into the tangent plane at unit point `p`.
func _tangent(p: Vector3, v: Vector3) -> Vector3:
	return v - p * v.dot(p)


func _rand_unit() -> Vector3:
	return LASimRng.for_domain("planet").rand_dir()
