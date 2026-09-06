extends SceneTree

## The probe scripts/check_fly_nav.sh reads. Each arm below is one claim about the rig's motion.

const R_M: float = 6.371e6
const M_KG: float = 5.972e24
const RIDGE_M: float = 2000.0
const DT: float = 1.0 / 60.0
const CELL_M: float = 5120.0
const DIMS: Vector3 = Vector3(3.0, 24.0, 3.0)
const REST_TAUS: float = 5.0             # a released stick is at rest within this many time constants
const REST_FRAC: float = 0.01            # "at rest" = this fraction of the speed it was released at
const DRAG_PX: float = 600.0             # a hard mouse flick, in pixels of drag

var _fail: int = 0


class StubBody:
	extends Node3D

	var ground_r: float = 6.371e6
	var body_mass: float = 5.972e24

	func surface_radius(_dir: Vector3) -> float:
		return ground_r

	func max_surface_radius() -> float:
		return ground_r

	func meshed_resolution_at(_p: Vector3) -> float:
		return 10.0

	func mass() -> float:
		return body_mass


func _say(msg: String) -> void:
	printerr(msg)
	_fail += 1


## Stand the drone `h` metres over the ground on the +Y radial, aimed along +X.
func _place(rig: LAVoxelCameraRig, h: float) -> void:
	var eye: Vector3 = Vector3.UP * (R_M + h)
	rig.place_fly(eye, eye + Vector3.RIGHT * 1000.0)


func _orbital(h: float) -> float:
	return sqrt(LAPhysical.GRAVITATIONAL_CONSTANT * M_KG / (R_M + h))


# --- the speed law ------------------------------------------------------------------------------------
func _check_speed_bands(rig: LAVoxelCameraRig, body: StubBody) -> void:
	# height, floor of the band, ceiling of the band, what a real thing moving that fast is
	var bands: Array = [
		[0.0, 1.0, 10.0, "a person crossing the ground"],
		[100.0, 10.0, 200.0, "a light aircraft over a field"],
		[1.0e4, 1.0e3, 1.0e4, "an airliner's ground track"],
		[4.0e5, 5.0e3, 8.0e3, "a satellite in low orbit"],
	]
	for b: Array in bands:
		var h: float = float(b[0])
		_place(rig, h)
		var v: float = rig.fly_speed(false)
		var want: float = minf(maxf(LAVoxelCameraRig.FLY_SPEED_FLOOR_M_S,
			LAVoxelCameraRig.FLY_SPEED_PER_HEIGHT * h), _orbital(h))
		if absf(v - want) > maxf(1.0e-3, 1.0e-4 * want):
			_say("At %.0f m the cruise speed is %.3f m/s; the height law gives %.3f." % [h, v, want])
		if v < float(b[1]) or v > float(b[2]):
			_say("At %.0f m the drone cruises at %.1f m/s, outside the %.0f-%.0f m/s band of %s."
				% [h, v, b[1], b[2], b[3]])
	# The height is measured from the GROUND UNDER THE EYE, not from the body's radius: raise the ground
	# under a drone at a fixed radius and it must slow down.
	_place(rig, 1.0e4)
	var over_datum: float = rig.fly_speed(false)
	body.ground_r = R_M + RIDGE_M
	var over_ridge: float = rig.fly_speed(false)
	body.ground_r = R_M
	if over_ridge >= over_datum:
		_say("Over a %.0f m ridge the drone cruises at %.1f m/s and over the datum at %.1f: its speed is"
			% [RIDGE_M, over_ridge, over_datum] + " not measured from the ground under it.")


# --- continuity and the coast to rest -----------------------------------------------------------------
func _check_continuity(rig: LAVoxelCameraRig) -> void:
	_place(rig, 1000.0)
	var stick: Vector3 = Vector3(0.0, 0.0, 1.0)
	var push: int = int(round(2.0 / DT))
	var coast: int = int(round(REST_TAUS * LAVoxelCameraRig.FLY_RESPONSE_TAU_S / DT))
	var prev: Vector3 = rig.global_position
	var last_v: float = 0.0                  # the drone starts at rest, so the first frame is a change too
	var worst: float = 0.0
	var cmd_max: float = 0.0
	var release_speed: float = 0.0
	var rest: float = 0.0
	for i in push + coast:
		cmd_max = maxf(cmd_max, rig.fly_speed(false))
		rig.fly_drive(DT, stick if i < push else Vector3.ZERO, false)
		var v: float = (rig.global_position - prev).length() / DT
		worst = maxf(worst, absf(v - last_v))
		last_v = v
		prev = rig.global_position
		if i == push - 1:
			release_speed = v
		if i == push + coast - 1:
			rest = v
	# EVERY FRAME'S CHANGE IS BOUNDED BY THE RESPONSE: the velocity eases toward the commanded one over
	# FLY_RESPONSE_TAU_S, so no frame may move the speed by more than that acceleration times its own dt.
	# This covers the release as well as the push: a stop dead is as discontinuous as a start dead.
	var bound: float = cmd_max / LAVoxelCameraRig.FLY_RESPONSE_TAU_S * DT
	if worst > bound * 1.001:
		_say("One frame changed the speed by %.3f m/s against a bound of %.3f m/s: the drone is not"
			% [worst, bound] + " accelerating, it is being placed.")
	if release_speed <= 0.0:
		_say("The drone never moved under a held stick, so nothing about its motion was measured.")
	# AND A RELEASED STICK COASTS. An exponential decay is at e^-5 of its release speed after five time
	# constants, so a speed above REST_FRAC of the release speed at that moment is not a decay.
	if rest > REST_FRAC * release_speed:
		_say(("Five time constants after the stick was released the drone is still doing %.3f m/s"
			+ " against the %.3f m/s it was released at: it is not coasting to rest.")
			% [rest, release_speed])


# --- the aim, and the wheel ---------------------------------------------------------------------------
func _angle(a: Vector3, b: Vector3) -> float:
	return acos(clampf(a.normalized().dot(b.normalized()), -1.0, 1.0))


func _check_look_ease(rig: LAVoxelCameraRig) -> void:
	_place(rig, 1000.0)
	var start: Vector3 = -rig.global_transform.basis.z
	rig.fly_look_drag(Vector2(DRAG_PX, 0.0))
	var prev: Vector3 = start
	var worst: float = 0.0
	var steps: int = int(round(20.0 * LAVoxelCameraRig.FLY_LOOK_TAU_S / DT))
	for _i in steps:
		rig.fly_drive(DT, Vector3.ZERO, false)
		var now: Vector3 = -rig.global_transform.basis.z
		worst = maxf(worst, _angle(prev, now))
		prev = now
	var total: float = _angle(start, prev)
	if total < 1.0:
		_say("A %.0f pixel drag turned the aim %.3f rad: the mouse-look did not move it." % [DRAG_PX, total])
		return
	# THE AIM EASES AS THE VELOCITY DOES: no frame may turn it by more than the time constant allows.
	var bound: float = total / LAVoxelCameraRig.FLY_LOOK_TAU_S * DT
	if worst > bound * 1.001:
		_say("One frame turned the aim %.4f rad against a bound of %.4f: the mouse-look snaps."
			% [worst, bound])
	if _angle(prev, -rig.global_transform.basis.z) > 1.0e-4:
		_say("The aim was still moving after twenty time constants: it never settled where the drag put it.")


func _check_wheel(rig: LAVoxelCameraRig) -> void:
	_place(rig, 1000.0)
	var base: float = rig.fly_speed(false)
	rig.fly_speed_notch(1.0)
	var up: float = rig.fly_speed(false)
	rig.fly_speed_notch(-1.0)
	rig.fly_speed_notch(-1.0)
	var down: float = rig.fly_speed(false)
	if not (up > base and down < base):
		_say("The wheel set the cruise speed to %.2f up and %.2f down from %.2f: it does nothing."
			% [up, down, base])
	for _i in 200:
		rig.fly_speed_notch(1.0)
	if rig.fly_speed_mult() > LAVoxelCameraRig.FLY_MULT_RANGE * 1.0001:
		_say("The wheel wound the cruise multiplier to %.2f past its declared range of %.2f."
			% [rig.fly_speed_mult(), LAVoxelCameraRig.FLY_MULT_RANGE])
	for _j in 400:
		rig.fly_speed_notch(-1.0)
	if rig.fly_speed_mult() < 1.0 / LAVoxelCameraRig.FLY_MULT_RANGE * 0.9999:
		_say("The wheel wound the cruise multiplier down to %.4f, past 1/%.2f."
			% [rig.fly_speed_mult(), LAVoxelCameraRig.FLY_MULT_RANGE])
	for _k in 200:
		rig.fly_speed_notch(1.0)
	for _m in 200:
		rig.fly_speed_notch(-1.0)


# --- framing the simulated box ------------------------------------------------------------------------
func _check_framing(rig: LAVoxelCameraRig) -> void:
	var site: Vector3 = Vector3.UP
	var size: Vector3 = DIMS * CELL_M
	var centre: Vector3 = Vector3.UP * R_M
	var box: AABB = AABB(centre - 0.5 * size, size)
	var r: float = LAVoxelCameraRig.footprint_radius(box, site)
	var fit: float = rig.fit_distance(r)
	if r <= 0.0 or fit <= 0.0:
		_say("The box footprint measured %.1f m and fits at %.1f m: there was nothing to frame." % [r, fit])
		return
	# THE DRONE STARTS INSIDE THE FOOTPRINT AND LOOKING AWAY, so the press has to turn it AND back it off.
	var eye: Vector3 = (centre + Vector3.RIGHT * (0.5 * r)).normalized() * (R_M + 2000.0)
	rig.place_fly(eye, eye + (eye - centre).normalized() * 1.0e5)
	if rig.is_position_in_frustum(centre):
		_say("The drone already framed the box before the control was pressed: the press proves nothing.")
	if not rig.frame_simulation(site, box):
		_say("The framing refused a body that had said where its surface is.")
		return
	for _i in int(round(30.0 / DT)):
		rig.fly_drive(DT, Vector3.ZERO, false)
	var stood: float = rig.global_position.distance_to(centre)
	if stood < fit * 0.98:
		_say("After the framing the drone stands %.0f m from the box, inside the %.0f m the footprint"
			% [stood, fit] + " needs: it turned but never backed off.")
	if not rig.is_position_in_frustum(centre):
		_say("One press did not put the box centre in the frustum.")
	# THE FOUR GROUND CORNERS, and the margin the framing declares around them.
	var half: float = asin(clampf(LAVoxelCameraRig.FRAME_MARGIN * r / fit, 0.0, 1.0))
	var look: Vector3 = -rig.global_transform.basis.z
	var worst: float = 0.0
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var corner: Vector3 = (centre + Vector3(sx * 0.5 * size.x, 0.0, sz * 0.5 * size.z)) \
				.normalized() * R_M
			if not rig.is_position_in_frustum(corner):
				_say("A ground corner of the footprint is outside the view after the framing.")
			var to: Vector3 = corner - rig.global_position
			if to.length() > 0.0:
				worst = maxf(worst, acos(clampf(to.normalized().dot(look), -1.0, 1.0)))
	if sin(worst) * LAVoxelCameraRig.FRAME_MARGIN > sin(half) * 1.02:
		_say("The footprint reaches %.2f degrees off the view axis against a %.2f degree half-angle:"
			% [rad_to_deg(worst), rad_to_deg(half)] + " the framing left no margin around it.")


var _ran: bool = false


# THE FRUSTUM TEST NEEDS A CAMERA IN A REAL VIEWPORT, and the root is not in the tree until a frame has
# started, so the run happens on the first one rather than in _initialize.
func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	var body: StubBody = StubBody.new()
	root.add_child(body)
	var rig: LAVoxelCameraRig = LAVoxelCameraRig.new()
	root.add_child(rig)
	rig.set_geosync_body(body)
	rig.set_orbit_target(Vector3.ZERO, R_M)
	_check_speed_bands(rig, body)
	_check_continuity(rig)
	_check_look_ease(rig)
	_check_framing(rig)
	_check_wheel(rig)
	print("FLY_NAV={\"failures\":%d, \"tau_s\":%.3f, \"per_height\":%.3f, \"floor_m_s\":%.2f, \"margin\":%.2f}"
		% [_fail, LAVoxelCameraRig.FLY_RESPONSE_TAU_S, LAVoxelCameraRig.FLY_SPEED_PER_HEIGHT,
			LAVoxelCameraRig.FLY_SPEED_FLOOR_M_S, LAVoxelCameraRig.FRAME_MARGIN])
	rig.queue_free()
	body.queue_free()
	quit(0 if _fail == 0 else 1)
	return true
