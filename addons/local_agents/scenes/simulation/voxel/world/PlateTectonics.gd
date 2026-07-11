class_name LAPlateTectonics
extends Node

## FAKED plate tectonics (the maintainer OK'd faking this one — true geodynamics is research-grade). The sphere
## is partitioned into N drifting PLATES: a Voronoi partition over random seed directions, each plate slowly
## rotating about its own Euler pole. The plates themselves are scripted, but the GEOLOGY at their boundaries
## EMERGES from the relative-motion kinematics — no per-event scripting, just: sample points near plate
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
const VOLCANO_CHANCE_CONVERGENT: float = 0.05   # arc volcano at a convergent margin is RARE (else just a quake) —
                                                # kept low so accumulated volcanic heat doesn't bake the planet
const VENT_CHANCE_DIVERGENT: float = 0.04       # rift vent even rarer

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
		var r: float = randf_range(0.35, 1.0) * DRIFT_RATE_MAX
		_rates.append(r if randf() < 0.5 else -r)


func _process(delta: float) -> void:
	if not _enabled or _terrain == null or _disasters == null:
		return
	if not _terrain.has_method("surface_point") or not _terrain.has_method("planet_center"):
		return
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
		# event — kept rare so sustained volcanic heat doesn't accumulate and bake the planet over a long game.
		_disasters.spawn_earthquake(point)
		if randf() < VOLCANO_CHANCE_CONVERGENT:
			_disasters.spawn_volcano(point)
	elif best_kind == "transform":
		_disasters.spawn_earthquake(point)                # the fault ruptures
	else:
		if randf() < VENT_CHANCE_DIVERGENT:
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
	for k in range(6):
		var ang: float = TAU * float(k) / 6.0
		var off: Vector3 = (dir + (t1 * cos(ang) + t2 * sin(ang)) * BOUNDARY_PROBE).normalized()
		var pk: int = _plate_of(off)
		if pk != own:
			return pk
	return -1


# Surface velocity of plate `k` at unit point `p` from its Euler rotation (ω × p).
func _plate_velocity(k: int, p: Vector3) -> Vector3:
	return (_poles[k] as Vector3).cross(p) * float(_rates[k])


# Project vector `v` into the tangent plane at unit point `p`.
func _tangent(p: Vector3, v: Vector3) -> Vector3:
	return v - p * v.dot(p)


func _rand_unit() -> Vector3:
	var v: Vector3 = Vector3(randf() * 2.0 - 1.0, randf() * 2.0 - 1.0, randf() * 2.0 - 1.0)
	while v.length() < 0.05:
		v = Vector3(randf() * 2.0 - 1.0, randf() * 2.0 - 1.0, randf() * 2.0 - 1.0)
	return v.normalized()
