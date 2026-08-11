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

# ===== HOW FAST THE PLATES GO, AND WHY IT IS NO LONGER A NUMBER ANYONE TYPED ===============================
#
# This used to be `DRIFT_RATE_MAX = 0.02` rad/s, commented "plates crawl", with nothing behind it. It is now
# DERIVED from the measured speed of real plates (LAPhysical.PLATE_SPEED_MIN/MAX_MM_PER_YEAR, 10-100 mm/yr
# from space geodesy) through this planet's radius and this simulation's own clock, times ONE declared
# acceleration. Each plate draws its speed from between the two real endpoints, so the spread ACROSS plates is
# the real observed spread rather than a randf_range someone picked.
#
# GEOLOGIC_TIME_ACCELERATION is the one number here that is a CHOICE, and it is stated as one instead of being
# hidden inside an angular rate. Geology is precisely the slow-emergent phenomenon CLAUDE.md's iterate-fast
# rule is about: the field's clock says one step stands for 43.2 REAL seconds, so a 600-frame run is 9.6 real
# hours, in which a real plate moves 4e-5 millimetres. Nothing observable happens on the honest clock — just as
# nothing observable happens to a forest in nine hours. So tectonic time is run faster by a declared factor,
# and every rate below is the real one multiplied by it. That is a different thing from inventing a rate.
#
# IT IS ALSO WHY THE TWO WEATHERING RECORDS IN GeoRecords.gd ARE SMALL AND SHOULD BE. Chemical denudation of
# real basalt runs ~17 micrometres a year, so even 808 accelerated years lowers a surface by 14 mm against a
# cell that stands for 500 model metres of depth. Weathering being nearly invisible next to plate motion is
# the correct RATIO — on Earth those two differ by about three orders of magnitude — not a sign either is
# mis-set. Anything that makes weathering visible in one run has broken the ratio.
#
# THE VALUE IS THE SMALLEST ONE THAT MAKES THE PHENOMENON MEASURABLE, which is the only defensible rule for a
# number like this: an acceleration perturbs everything downstream of it, so it should be as small as the
# question allows. At 3e5 a 600-frame run at --fast=8 covers 590 steps x 43.2 s x 3e5 = 242 accelerated years,
# in which a median plate (50 mm/yr) travels 12 m — three quarters of a cell. That is plainly resolved:
# measured against the SAME build with LA_NO_PLATE_ADVECT=1, `crust_moved` 3187 against 305 and the SDF stamp's
# rock_grows/rock_shrinks 1441/1122 against 49/240.
#
# BIGGER VALUES WERE TRIED AND MEASURED, and both failed on the same mechanism — the crust CHURNS faster than
# the rest of the substrate can respond, and the run stops being a planet:
#   1e7 (25 cells/run):  `crust_moved` 20381 of 32792 bedrock, `rock_shrinks` 8096 against a baseline 101, and
#                        `temp_ground_p50` 17.6 -> 74.8 C.
#   1e6 (2.5 cells/run): `rock_cells` 29720 against 31787 with the crust held still — 2000 cells of crust
#                        OPENED, because a margin in continuous motion holds a wide band of partially-filled
#                        cells and `solid` is derived as rock_fill >= 0.5, so half that band reads as void.
#                        `hotspring_cells` 1000 against 309 as the opened crust exposed the seeded geotherm,
#                        and `water_total` 209 against 1358 as the ocean flashed to steam behind it.
# At 3e5 that cascade does not start: `rock_cells` 32303, at or slightly above both the baseline (32038) and
# the held-still control (31787). The residual cost is honest and is recorded in HANDOFF.md rather than
# smoothed over: `water_total` 587 against a baseline 1416, `temp_mean` +2.8 C.
#
# NONE OF THAT IS A FAULT IN THE TRANSPORT, which conserves mineral exactly at every value tried
# (`mineral_drift` 0.0). It is the binary solidity threshold meeting a continuously moving margin, and fixing
# THAT is what would let this be turned up.
const GEOLOGIC_TIME_ACCELERATION: float = 3.0e5

## Angular speed (radians per sim-clock second) of a plate moving `speed_mm_yr` at the surface of a body of
## radius `radius`, with geologic time accelerated. Horizontal world units are read as metres. Chain:
## mm/yr -> m per simulated second -> rad per simulated second -> rad per sim-clock second (the field's fixed
## step quantum) -> times the acceleration above.
static func drift_rate(speed_mm_yr: float, radius: float) -> float:
	var m_per_real_s: float = (speed_mm_yr * 0.001) / LAPhysical.SECONDS_PER_YEAR
	var rad_per_real_s: float = m_per_real_s / maxf(radius, 1.0)
	var real_s_per_sim_s: float = LAMaterialFieldSphereStep3D.real_seconds_per_sim_second()
	return rad_per_real_s * real_s_per_sim_s * GEOLOGIC_TIME_ACCELERATION
# Probability of an arc volcano at a convergent margin (else a quake). A rarity roll standing in for missing
# physics: melt should emerge from crustal thinning plus the geotherm, with no boundary classifier at all.
const VOLCANO_CHANCE_CONVERGENT: float = 0.3

# A divergent margin always vents — a spreading ridge erupts along its whole length, it is not a lottery. The
# throttle is the drumbeat: one event per EVENT_PERIOD, best-scoring candidate only, and divergent margins
# score lowest (speed * 0.4 against a transform's speed).

var _terrain = null                      # LAVoxelTerrainService (planet_center/radius, surface_point, sea_radius)
var _disasters = null                    # LAVoxelDisasters (spawn_volcano / spawn_earthquake)
var _field = null                        # LAMaterialField3D — the substrate the crust is carried in

var _seeds: Array = []                   # Array[Vector3] plate seed directions (unit)
var _poles: Array = []                   # Array[Vector3] Euler rotation axis per plate (unit)
var _rates: Array = []                   # Array[float] angular speed per plate (rad per simulated second, signed)
var _cd: float = EVENT_PERIOD
var _enabled: bool = true
var _table: PackedFloat32Array = PackedFloat32Array()   # the packed plate table pushed to the field each frame


func setup(terrain, disasters, field = null) -> void:
	_terrain = terrain
	_disasters = disasters
	_field = field
	_enabled = OS.get_environment("LA_NO_TECTONICS") == ""
	# Plate speeds come from the REAL observed range, one draw per plate, so the fast plates and the slow ones
	# differ the way Earth's do. The radius is the body's own, so the same real speeds give the right angular
	# rate on any size of planet.
	var radius: float = 0.0
	if _terrain != null and _terrain.has_method("planet_radius"):
		radius = float(_terrain.planet_radius())
	if radius <= 1.0:
		radius = 500.0
	for i in range(PLATE_COUNT):
		_seeds.append(_rand_unit())
		_poles.append(_rand_unit())
		var mm_yr: float = LASimRng.for_domain("planet").randf_range(
			LAPhysical.PLATE_SPEED_MIN_MM_PER_YEAR, LAPhysical.PLATE_SPEED_MAX_MM_PER_YEAR)
		var r: float = drift_rate(mm_yr, radius)
		_rates.append(r if LASimRng.for_domain("planet").randf() < 0.5 else -r)
	_table.resize(PLATE_COUNT * 8)


## The tectonic drumbeat runs on the physics clock, never the render clock, so a seeded run is reproducible.
func _physics_process(delta: float) -> void:
	if not _enabled or _terrain == null or _disasters == null:
		return
	if not _terrain.has_method("surface_point") or not _terrain.has_method("planet_center"):
		return
	# Drift: rotate each plate seed about its Euler pole, so the Voronoi boundaries migrate.
	for i in range(_seeds.size()):
		_seeds[i] = (_seeds[i] as Vector3).rotated((_poles[i] as Vector3).normalized(), float(_rates[i]) * delta)
	# Hand the plates to the substrate: rotating the seeds moves the boundaries, carrying rock_fill and
	# sediment at the same velocity moves the crust.
	_push_plates()
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
		_disasters.spawn_volcano(point)                   # a rift vent: the lid is being pulled apart HERE


## Pack the live plate kinematics and hand them to the field, whose PlateAdvectPass carries rock_fill and
## sediment with the velocity they imply. PLATE_STRIDE floats per plate — seed.xyz, rate, pole.xyz, pad —
## matching plate_advect_sphere3d.glsl. Rebuilt each frame into ONE reused array (no per-frame allocation);
## the seeds are what changed, and they change every frame.
func _push_plates() -> void:
	if _field == null or not _field.has_method("set_plate_motion"):
		return
	if _table.size() != _seeds.size() * 8:
		_table.resize(_seeds.size() * 8)
	for i in range(_seeds.size()):
		var s: Vector3 = (_seeds[i] as Vector3).normalized()
		var p: Vector3 = (_poles[i] as Vector3).normalized()
		var b: int = i * 8
		_table[b + 0] = s.x
		_table[b + 1] = s.y
		_table[b + 2] = s.z
		_table[b + 3] = float(_rates[i])
		_table[b + 4] = p.x
		_table[b + 5] = p.y
		_table[b + 6] = p.z
		_table[b + 7] = 0.0
	_field.set_plate_motion(_table)


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
