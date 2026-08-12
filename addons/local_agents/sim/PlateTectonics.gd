class_name LAPlateTectonics
extends Node


const PLATE_COUNT: int = 9
const EVENT_PERIOD: float = 7.0          # seconds between tectonic events (a slow geological drumbeat — not disaster spam)
const SAMPLES_PER_EVENT: int = 10        # boundary points sampled per event; the best-fitting one erupts/quakes
const BOUNDARY_PROBE: float = 0.06       # angular half-width (radians) for detecting a nearby plate boundary
const CONVERGE_MIN: float = 0.25         # |relative-normal velocity| fraction above which it's convergent/divergent

const GEOLOGIC_TIME_ACCELERATION: float = 3.0e5

static func drift_rate(speed_mm_yr: float, radius: float) -> float:
	var m_per_real_s: float = (speed_mm_yr * 0.001) / LAPhysical.SECONDS_PER_YEAR
	var rad_per_real_s: float = m_per_real_s / maxf(radius, 1.0)
	return rad_per_real_s * LASimClock.REAL_SECONDS_PER_SIM_SECOND * GEOLOGIC_TIME_ACCELERATION
const VOLCANO_CHANCE_CONVERGENT: float = 0.3


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


func _physics_process(delta: float) -> void:
	if not _enabled or _terrain == null or _disasters == null:
		return
	if not _terrain.has_method("surface_point") or not _terrain.has_method("planet_center"):
		return
	# DRIFT: rotate each plate seed about its Euler pole every frame, so the Voronoi boundaries MIGRATE over time
	# and the Ring of Fire slowly moves (was frozen — the seeds were set once in setup and never integrated).
	for i in range(_seeds.size()):
		_seeds[i] = (_seeds[i] as Vector3).rotated((_poles[i] as Vector3).normalized(), float(_rates[i]) * delta)
	# AND HAND THE PLATES TO THE SUBSTRATE, which is the half that did not exist. Rotating the seeds moves the
	# BOUNDARIES; carrying rock_fill and sediment with the same velocity moves the CRUST. Without this the Ring
	# of Fire swept across continents that never moved, which is not plate tectonics — it is a moving label.
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
		_disasters.spawn_earthquake(point)
		if LASimRng.for_domain("planet").randf() < VOLCANO_CHANCE_CONVERGENT:
			_disasters.spawn_volcano(point)
	elif best_kind == "transform":
		_disasters.spawn_earthquake(point)                # the fault ruptures
	else:
		_disasters.spawn_volcano(point)                   # a rift vent: the lid is being pulled apart HERE


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
