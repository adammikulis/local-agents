extends SceneTree

class Body extends Node3D:
	var _body_basis: Basis = Basis.IDENTITY
	func center() -> Vector3: return Vector3.ZERO
	func angular_velocity_rad_s() -> float: return 0.0
	func spin_axis() -> Vector3: return Vector3.UP

var _fails: int = 0

func _claim(ok: bool, message: String) -> void:
	if not ok:
		_fails += 1
		printerr(message)

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	LAProcessSet.declare(LAProcessSet.GRAVITY)
	LABallistics.clear()
	LABallistics.set_system([])
	LABallistics.set_field(null, PackedFloat32Array(), PackedByteArray(), null, [], Basis.IDENTITY, Vector3.ZERO)
	var untracked: int = LABallistics.drop(Vector3.ZERO, Vector3.RIGHT, 0.0, 0.0)
	_claim(LABallistics.trajectory(untracked)["points"].is_empty(), "An unobserved body collected presentation history.")
	LABallistics.release(untracked)
	var id: int = LABallistics.drop(Vector3(4.0, 5.0, 6.0), Vector3(1.0, 2.0, 0.0), 0.0, 0.0)
	LABallistics.track_trajectory(id)
	for _step in 200:
		LABallistics.step(1.0)
	var history: Dictionary = LABallistics.trajectory(id)
	var points: PackedVector3Array = history["points"]
	var times: PackedFloat64Array = history["times"]
	_claim(points.size() > 2 and points.size() <= 96, "Native history is absent or unbounded without render calls.")
	_claim(points[0].is_equal_approx(Vector3(4.0, 5.0, 6.0)) and times[0] == 0.0, "Decimation lost the release endpoint.")
	_claim(points[-1].is_equal_approx(LABallistics.state(id)["position"]) and times[-1] == 200.0, "History lost the latest integrated endpoint.")
	for i in range(1, times.size()):
		_claim(times[i] > times[i - 1], "Trajectory timestamps are not strictly ordered.")
	var turn: Basis = Basis(Vector3.FORWARD, PI / 2.0)
	var shift: Vector3 = Vector3(1000.0, -2000.0, 3000.0)
	LABallistics.set_field(null, PackedFloat32Array(), PackedByteArray(), null, [], turn, shift)
	var moved: PackedVector3Array = LABallistics.trajectory(id)["points"]
	for i in points.size():
		_claim(moved[i].is_equal_approx(shift + turn * points[i]), "A stored trajectory sample did not follow frame rotation and translation.")
	_claim((LABallistics.state(id)["from"] as Vector3).is_equal_approx(moved[0]), "The release point and history disagree after frame movement.")
	LABallistics.release(id)
	_claim(LABallistics.trajectory(id).is_empty(), "Releasing a body retained its history.")
	LABallistics.set_field(null, PackedFloat32Array(), PackedByteArray(), null, [], Basis.IDENTITY, Vector3.ZERO)
	LABallistics.set_system([{"center": Vector3.ZERO, "mass_kg": 1.0e14, "radius_m": 100.0, "frame": true}])
	id = LABallistics.drop(Vector3(0.0, 1000.0, 0.0), Vector3(1.0, 0.0, 0.0), 0.0, 0.0)
	LABallistics.track_trajectory(id)
	for _step in 20:
		LABallistics.step(0.5)
	points = LABallistics.trajectory(id)["points"]
	_claim(points.size() > 2, "Coalesced presentation lost the integrated arc.")
	var chord: Vector3 = points[-1] - points[0]
	var midpoint: Vector3 = points[points.size() >> 1] - points[0]
	_claim(chord.cross(midpoint).length() > 0.01, "Native history flattened a curved flight into a chord.")
	LABallistics.release(id)
	id = LABallistics.drop(Vector3(0.0, 101.0, 0.0), Vector3.DOWN, 0.0, 0.0)
	LABallistics.track_trajectory(id)
	LABallistics.step(5.0)
	var landed: Dictionary = LABallistics.state(id)
	history = LABallistics.trajectory(id)
	points = history["points"]
	times = history["times"]
	_claim(landed["landed"] and float(landed["fall_time_s"]) < 5.0, "The landing control never reached a fractional landing endpoint.")
	_claim(points[-1].is_equal_approx(landed["position"]) and times[-1] == float(landed["fall_time_s"]), "Native history missed the fractional landing endpoint.")
	LABallistics.set_field(null, PackedFloat32Array(), PackedByteArray(), null, [], turn, shift)
	var rest: Vector3 = LABallistics.state(id)["position"]
	_claim(rest.is_equal_approx(shift + turn * points[-1]), "A landed body did not follow the moving ground frame.")
	_claim((LABallistics.trajectory(id)["points"] as PackedVector3Array)[-1].is_equal_approx(rest), "Landed marker and history separated after frame movement.")
	LABallistics.clear()
	LABallistics.set_system([])
	for direction: Vector3 in [Vector3.UP, Vector3(1.0, 1.0, 1.0), Vector3(-1.0, 2.0, 0.5)]:
		var half: Vector3 = Vector3(10.0, 40.0, 20.0)
		var face: Vector3 = LAGridGeometry.radial_box_exit(direction, half)
		var inside: Vector3 = face - direction.normalized() * 0.01
		var outside: Vector3 = face + direction.normalized() * 0.01
		var bounds: AABB = AABB(-half, 2.0 * half)
		_claim(bounds.has_point(inside) and not bounds.has_point(outside), "The radial box crossing does not straddle its boundary.")
	var body: Body = Body.new()
	var probes: LATestMasses = LATestMasses.new()
	root.add_child(body)
	root.add_child(probes)
	probes.setup(body, body)
	id = probes.throw_orb(Vector3(0.0, 100.0, 0.0), Vector3.RIGHT)
	_claim(not LABallistics.trajectory(id)["points"].is_empty(), "A probe did not opt in to native history.")
	LAAblate.adopt("history_probes", probes)
	LAAblate.set_on("history_probes", false)
	_claim(LABallistics.trajectory(id).is_empty() and probes.rows().is_empty(), "Disabling probes retained trajectory ownership.")
	_claim(probes.throw_orb(Vector3.UP, Vector3.RIGHT) < 0, "A disabled probe module released another orb.")
	probes.free()
	body.free()
	LABallistics.clear()
	print("PROBE_HISTORY: " + ("OK" if _fails == 0 else "FAIL"))
	quit(0 if _fails == 0 else 1)
