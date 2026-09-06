@tool
class_name LAVoxelCameraRig
extends Camera3D


const MIN_DISTANCE: float = 0.5           # closest zoom (units from focus) — right down onto an animal
const MAX_DISTANCE: float = 1400.0        # farthest zoom — pull way out for a whole-world view
const ZOOM_STEP: float = 1.12             # wheel multiplier per notch (bigger = faster zoom) — gentle, slow zoom
const ZOOM_SMOOTH_TIME: float = 0.62
const DRAG_ORBIT_THRESHOLD: float = 3.0
const PAN_SPEED: float = 140.0            # WASD/arrow-key pan, per second, scaled by distance
const DRAG_PAN_SPEED: float = 6.0         # Shift+MMB drag pan, per pixel, scaled by distance
const ORBIT_SENSITIVITY: float = 0.0075   # MMB drag orbit, radians per pixel
const KEY_YAW_SPEED: float = 1.6          # Q/E yaw, radians per second
const EDGE_MARGIN: float = 12.0           # px from a screen edge that triggers edge-scroll
const EDGE_PAN_SPEED: float = 70.0         # edge-scroll pan, per second, scaled by distance
const PITCH_MIN: float = deg_to_rad(15.0) # shallowest downward tilt
const PITCH_MAX: float = deg_to_rad(85.0) # steepest (near top-down) tilt
const RAY_LENGTH: float = 4000.0

const RTS_ALT_MIN: float = 6.0       # closest zoom — down among the creatures
# Where the view opens.
const RTS_ALT_START: float = 95.0
const RTS_ALT_START_CAMPAIGN: float = 40.0

const RTS_PITCH_DEG: float = 50.0
const RTS_PITCH_MIN_DEG: float = 40.0
const RTS_PITCH_MAX_DEG: float = 60.0

const ORBIT_MAX_DISTANCE_MULT: float = 6.0
const ORBIT_DEFAULT_DISTANCE_MULT: float = 2.4   # retained for the (deferred) solar/space framing only
# Clamp elevation shy of the poles so "up" stays world-up without a gimbal flip through the pole.
# The azimuth/elevation chart's own bound. The pole is a point on it, not a place to be kept away from:
# the up-vector degeneracy there is handled where look_at needs it.
const ORBIT_ELEVATION_LIMIT: float = 0.5 * PI
const SURFACE_WALK_SPEED: float = 0.8     # radians/sec of surface sweep at full stick (before the near-zoom taper)

const ARC_LOOK_HEIGHT: float = 2.2
const MIN_EYE_CLEARANCE: float = 6.0      # eye never sits closer than this above the terrain beneath the view
const TERRAIN_FOLLOW_TIME: float = 0.35   # ease time (s) of the terrain-radius follow — smooths ridges under the eye

const PAN_REFERENCE_DISTANCE: float = 100.0
## Bearings the ground is asked about, as a fraction of the half-field of view: the frame is not
## resolved until its coarsest is, or half the picture streams in after the shot.
const FRAME_PROBE_FRAC: Array[float] = [-1.0, -0.5, 0.0, 0.5, 1.0]

var _focus: Vector3 = Vector3.ZERO
var _distance: float = 140.0
var _target_distance: float = 140.0       # wheel-set zoom goal; _distance eases toward it (smooth-zoom glide)
var _zoom_vel: float = 0.0                 # critically-damped spring velocity for the zoom glide
# SUNNYSIDE START: open the orbit view over the lit hemisphere.
var _sun_light: Node3D = null
var _sunnyside_pending: bool = false
var _yaw: float = 0.0
var _pitch: float = deg_to_rad(55.0)
var _panning: bool = false
var _orbiting: bool = false
# LMB/RMB "hold to rotate the planet" drag-orbit.
var _drag_orbiting: bool = false
var _drag_orbit_armed: bool = false
var _drag_orbit_travel: float = 0.0
# Middle-mouse held-drag aims the camera in place: a free-look yaw/pitch offset.
var _aiming: bool = false
var _aim_yaw: float = 0.0
var _aim_pitch: float = 0.0
const AIM_DRAG_SPEED: float = 0.005      # radians of camera-aim per pixel of MMB drag
const AIM_YAW_LIMIT: float = 1.2         # clamp free-look yaw (rad)
const AIM_PITCH_LIMIT: float = 1.0       # clamp free-look pitch (rad)

var _invert_rotate_x: bool = false
var _invert_rotate_y: bool = false

var _orbit_mode: bool = false
var _orbit_center: Vector3 = Vector3.ZERO
var _orbit_radius: float = 0.0            # planet radius (for zoom clamps)
var _orbit_azimuth: float = 0.0           # rotation around the polar axis, radians
var _orbit_elevation: float = deg_to_rad(20.0)  # latitude of the camera, radians (clamped off the poles)
var _orbit_min_distance: float = 0.0
var _orbit_max_distance: float = 0.0
# Constant RTS view pitch, radians.
const SLICE_PITCH_DEG: float = 20.0
const SLICE_STANDOFF_FRAC: float = 1.0 / 3.0   # eye-to-look distance over the box footprint
var _orbit_back: Vector3 = Vector3.ZERO        # tangent the eye stands behind; zero = world up decides

var _rts_pitch: float = deg_to_rad(RTS_PITCH_DEG)
var _smooth_surface_r: float = 0.0
var _ground_ready: bool = false
var _ground_res: float = INF     # coarsest voxel edge of the drawn ground ACROSS THE FRAME
var _ground_res_prev: float = -1.0   # the same, one update ago: equal means the streamer has settled
var _look_res: float = INF       # voxel edge of the ground the gaze lands on
var _aim_distance: float = 0.0   # eye to look point, metres

var _geosync: bool = false
var _geosync_body: Node3D = null
var _geosync_local_dir: Vector3 = Vector3.UP
# --- Solar-system overview: a pulled-back framing that shows the planet + the (visible) sun together.
var _solar_view: bool = false

# A DRONE, NOT A TELEPORT. Presentation constants: none of them reaches the field.
const FLY_SPEED_PER_HEIGHT: float = 0.5   # m/s of cruise per metre of height over the ground (1/s)
const FLY_SPEED_FLOOR_M_S: float = 4.0    # cruise on the deck: a person's running pace
const FLY_BOOST: float = 4.0              # Shift multiplier
const FLY_MULT_RANGE: float = 8.0         # wheel-set cruise multiplier, either side of 1
const FLY_RESPONSE_TAU_S: float = 0.35    # e-folding time of the velocity toward the commanded one
const FLY_LOOK_TAU_S: float = 0.08        # e-folding time of the aim toward the dragged one
const FLY_LOOK_SENS: float = 0.005        # radians per pixel for the hold-drag mouse-look
const FLY_PITCH_LIMIT_DEG: float = 85.0   # steepest aim off the horizon; at 90 the up-vector degenerates
const FRAME_MARGIN: float = 1.2           # framed radius over the subject's own, so it clears the edge
var _fly: bool = false
var _fly_pos: Vector3 = Vector3.ZERO
var _fly_look: Vector3 = Vector3.FORWARD  # world-space unit forward (aim), eased toward the goal
var _fly_look_goal: Vector3 = Vector3.FORWARD
var _fly_vel: Vector3 = Vector3.ZERO      # world m/s, integrated
var _fly_speed_mult: float = 1.0
var _fly_goto: Vector3 = Vector3.ZERO     # a framing's standoff point; the stick cancels it
var _fly_goto_on: bool = false

# A scripted SHOT POSE placed over a site on the body: absolute, and re-solved as the ground arrives.
var _pose: bool = false
var _pose_site: Vector3 = Vector3.ZERO    # body-frame radial of the site the eye stands over
var _pose_alt_m: float = 0.0              # metres above the ground at that site
var _pose_pitch: float = 0.0              # radians from the horizon; negative looks down
var _pose_yaw: float = 0.0                # radians about the site radial, from the framing axis

const TRACK_LERP: float = 3.0             # focus/zoom ease rate toward the target, per second
const TRACK_FOCUS_LIFT: float = 8.0       # keep the focus a touch above the ground foot of the storm
var _track_target: Node3D = null
var _track_distance: float = -1.0         # <0 = keep the current zoom (per the default contract)
var _track_pitch: float = -1.0            # <0 = keep the current pitch

var _pan_limit: float = 0.0


## Current zoom distance (focus→camera).
func get_zoom_distance() -> float:
	return _distance


## Clamp how far the focus can pan from the origin (world half-extent). Set once by VoxelWorld.
func set_pan_limit(limit: float) -> void:
	_pan_limit = maxf(0.0, limit)
	_clamp_focus()
	_update_transform()


## Keep the focus within the pan bound (no-op when unbounded).
func _clamp_focus() -> void:
	if _pan_limit <= 0.0:
		return
	_focus.x = clampf(_focus.x, -_pan_limit, _pan_limit)
	_focus.z = clampf(_focus.z, -_pan_limit, _pan_limit)

# Screen shake (earthquakes, big impacts).
const SHAKE_MAG: float = 1.8
const TRAUMA_DECAY: float = 1.1
var _trauma: float = 0.0
var _shake_applied: Vector3 = Vector3.ZERO
# This rig's own shake stream.
var _shake_rng: LASimRng = LASimRng.make(LASimRng.DEFAULT_SEED, "camera_shake")


## Add camera trauma (0..1).
func add_shake(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


func _ready() -> void:
	current = true
	_focus = Vector3(0.0, 20.0, 0.0)
	_distance = 140.0
	_target_distance = 140.0
	_zoom_vel = 0.0
	_yaw = 0.0
	_pitch = deg_to_rad(55.0)
	_update_transform()
	# Pick up the player's drag-rotate invert toggles and follow live re-applies (skip in the @tool preview).
	if not Engine.is_editor_hint():
		_read_invert_settings()
		var gm: Node = get_node_or_null("/root/GameMode")
		if gm != null and gm.has_signal("settings_applied"):
			var cb: Callable = Callable(self, "_on_settings_applied")
			if not gm.is_connected("settings_applied", cb):
				gm.settings_applied.connect(cb)


## The active LAGameSettings from the GameMode autoload (null in a direct-scene/test launch → defaults kept).
func _game_settings() -> LAGameSettings:
	var gm: Node = get_node_or_null("/root/GameMode")
	if gm != null and gm.get("settings") != null:
		return gm.get("settings")
	return null


## Read the two drag-rotate invert toggles off the live settings so a Save applies them without a relaunch.
func _read_invert_settings() -> void:
	var settings: LAGameSettings = _game_settings()
	if settings != null:
		_invert_rotate_x = settings.invert_rotate_x
		_invert_rotate_y = settings.invert_rotate_y


func _on_settings_applied(_new_settings: LAGameSettings) -> void:
	_read_invert_settings()


## Frame a sweeping 3/4 vista over `center` (the spawn area, at the true surface height).
func frame_vista(center: Vector3) -> void:
	_focus = center + Vector3(0.0, 8.0, 0.0)
	_distance = 34.0
	_yaw = 0.0
	_pitch = deg_to_rad(38.0)
	_clamp_focus()
	_update_transform()


## Frame a wide, high vista over `center` — a whole-island overview (dev/screenshot aid).
func frame_overview(center: Vector3, dist: float = 360.0) -> void:
	if _orbit_mode:
		# In orbit mode this is a whole-planet framing request.
		_orbit_center = center
		_distance = clampf(dist, _orbit_min_distance, _orbit_max_distance)
		_target_distance = _distance
		_zoom_vel = 0.0
		_update_transform()
		return
	_focus = center + Vector3(0.0, 10.0, 0.0)
	_distance = clampf(dist, MIN_DISTANCE, MAX_DISTANCE)
	_yaw = deg_to_rad(35.0)
	_pitch = deg_to_rad(48.0)
	_clamp_focus()
	_update_transform()


func track_target(target: Node3D, distance: float = -1.0, pitch_deg: float = -1.0) -> void:
	_track_target = target
	_track_distance = distance
	_track_pitch = (deg_to_rad(pitch_deg) if pitch_deg > 0.0 else -1.0)


## Stop following (target dissipated, or the player took manual control).
func stop_tracking() -> void:
	_track_target = null
	_track_distance = -1.0
	_track_pitch = -1.0


## Recenter the camera on `point` (auto-select focus, meteor impacts, etc.) at a closer inspection distance.
func focus_on(point: Vector3) -> void:
	_focus = point
	_distance = clampf(40.0, MIN_DISTANCE, MAX_DISTANCE)
	_clamp_focus()
	_update_transform()


func set_orbit_target(center: Vector3, radius: float) -> void:
	_orbit_mode = true
	_orbit_center = center
	_orbit_radius = maxf(1.0, radius)
	_orbit_min_distance = _orbit_radius + RTS_ALT_MIN
	_orbit_max_distance = _effective_orbit_max()
	_distance = clampf(_orbit_radius + _start_altitude(), _orbit_min_distance, _orbit_max_distance)
	_target_distance = _distance                 # keep the smooth-zoom goal in sync with this framing jump
	_zoom_vel = 0.0
	stop_tracking()          # storm-follow is a flat-world concept; drop it on entering orbit
	_update_transform()


## FRAME A SLICE BOX: the eye stands inside it, over the ground under the box centre, looking along the
## box's longest horizontal axis.
func frame_slice(planet_centre: Vector3, planet_radius: float, box: AABB, site_dir: Vector3) -> void:
	var radial: Vector3 = (box.get_center() - planet_centre).normalized()
	if radial.length() < 0.001:
		return
	set_orbit_target(planet_centre, planet_radius)
	# THE BOX IS A REGION OF THE BODY, so the eye holds its BODY-FRAME site and turns with it: the ground
	# below stays the same ground and the sun crosses the sky over it.
	if site_dir.length() > 0.001 and _geosync_body != null and is_instance_valid(_geosync_body):
		_geosync_local_dir = site_dir.normalized()
		_geosync = true
		# The pose is solved at the SITE now, so the terrain-follow ease starts there rather than easing
		# down from whatever radius the opening pose held.
		_smooth_surface_r = 0.0
		_ground_ready = false
	_orbit_elevation = clampf(asin(clampf(radial.y, -1.0, 1.0)), -ORBIT_ELEVATION_LIMIT, ORBIT_ELEVATION_LIMIT)
	_orbit_azimuth = atan2(radial.x, radial.z)
	_sunnyside_pending = false
	# THE BOX'S LOCAL VERTICAL IS ITS EDGE MOST ALIGNED WITH THE RADIAL, whatever the site. Off the body
	# axes that edge still leans into the horizontal, and taken as a candidate it makes the tall column
	# the view axis and the standoff the column's height.
	var up_axis: int = 0
	for i in 3:
		if absf(radial[i]) > absf(radial[up_axis]):
			up_axis = i
	# The horizontal axes are the remaining box edges with the radial projected out; the longest is the
	# view axis.
	var foot: float = 0.0
	var along: Vector3 = Vector3.ZERO
	for i in 3:
		if i == up_axis:
			continue
		var axis: Vector3 = Vector3.ZERO
		axis[i] = 1.0
		var tangent: Vector3 = axis - radial * axis.dot(radial)
		var span: float = box.size[i] * tangent.length()
		if span > foot:
			foot = span
			along = tangent
	if foot <= 0.0 or along.length() < 0.001:
		return
	along = along.normalized()
	_orbit_back = -along
	_rts_pitch = deg_to_rad(SLICE_PITCH_DEG)
	var standoff: float = foot * SLICE_STANDOFF_FRAC
	_distance = clampf(_orbit_radius + standoff * sin(_rts_pitch), _orbit_min_distance, _orbit_max_distance)
	_target_distance = _distance
	_zoom_vel = 0.0
	_update_transform()


## Ask the rig to open over the LIT hemisphere.
func face_sun_on_start(sun_light: Node3D) -> void:
	_sun_light = sun_light
	_sunnyside_pending = _sun_light != null


## Point the orbit view along a world direction (sets azimuth/elevation so the camera sits on that side looking in).
func orient_toward(world_dir: Vector3) -> void:
	if not _orbit_mode or world_dir.length() < 0.001:
		return
	_sunnyside_pending = false          # an explicit aim (e.g. onto the campaign herd) wins over deferred sunnyside
	var d: Vector3 = world_dir.normalized()
	_orbit_elevation = clampf(asin(clampf(d.y, -1.0, 1.0)), -ORBIT_ELEVATION_LIMIT, ORBIT_ELEVATION_LIMIT)
	_orbit_azimuth = atan2(d.x, d.z)
	_update_transform()


## THE CEILING IS A MULTIPLE OF THE BODY, WHICH IS WHAT A ZOOM MULTIPLIER MEANS. Read as an altitude in
## metres it collapsed to a couple of hundred, so the widest view a sandbox could reach stood lower than
## its own mountains and no camera could ever see the world it was on.
func _effective_orbit_max() -> float:
	return _orbit_radius * clampf(LAGameProgression.zoom_ceiling_mult(),
		LAGameProgression.BASELINE_ZOOM_MULT, ORBIT_MAX_DISTANCE_MULT)


## The altitude ceiling that follows from it.
func _effective_alt_max() -> float:
	return maxf(RTS_ALT_MIN, _effective_orbit_max() - _orbit_radius)


## Altitude the view opens at: campaign starts close (working a curated patch).
func _start_altitude() -> float:
	var prog: LAGameProgression = LAGameProgression.active()
	if prog != null and not prog.is_sandbox():
		return RTS_ALT_START_CAMPAIGN
	return RTS_ALT_START


## Leave orbit mode and return to the flat fly camera (kept for completeness / mode toggles).
func clear_orbit_target() -> void:
	_orbit_mode = false
	_update_transform()


## True while orbiting a planet centre.
func is_orbit_mode() -> bool:
	return _orbit_mode


## Rebuild the camera transform from the focus/distance/yaw/pitch state.
func _update_transform() -> void:
	if _fly:
		_update_fly_transform()
		return
	if _orbit_mode:
		_update_orbit_transform()
		return
	var b: Basis = Basis.from_euler(Vector3(-_pitch, _yaw, 0.0))
	global_position = _focus + b * Vector3(0.0, 0.0, _distance)
	look_at(_focus, Vector3.UP)
	# Push the far plane out with zoom so the (now horizon-spanning) ocean isn't clipped when pulled way out.
	far = clampf(_distance * 12.0, 4000.0, 20000.0)


## HOW FAR AN EYE `h` ABOVE A SPHERE OF RADIUS R CAN SEE: the tangent length sqrt(h(2R + h)), which is
## the horizon at the surface and the far limb from space. The near plane follows it, because a depth
## buffer stretched from centimetres to the horizon resolves neither end.
func _horizon_far(h: float) -> float:
	return maxf(sqrt(h * (2.0 * _orbit_radius + h)), 4000.0)


func _apply_depth_range(h: float) -> void:
	far = _horizon_far(h)
	near = clampf(far * 1.0e-5, 0.05, 2.0)


## Unit world radial (planet centre → camera) from the azimuth/elevation pair. This is the FREE-mode pose.
func _radial_from_azel() -> Vector3:
	var e: float = clampf(_orbit_elevation, -ORBIT_ELEVATION_LIMIT, ORBIT_ELEVATION_LIMIT)
	return Vector3(cos(e) * sin(_orbit_azimuth), sin(e), cos(e) * cos(_orbit_azimuth))


func _rts_altitude() -> float:
	return clampf(_distance - _orbit_radius, RTS_ALT_MIN, _effective_alt_max())


func _approach_t() -> float:
	var span: float = maxf(_effective_alt_max() - RTS_ALT_MIN, 0.0001)
	return clampf(1.0 - (_rts_altitude() - RTS_ALT_MIN) / span, 0.0, 1.0)


func _update_orbit_transform() -> void:
	# The solar overview writes its own absolute pose; never overwrite it with the RTS ground pose.
	if _solar_view:
		return
	var radial: Vector3
	if _geosync and _geosync_body != null and is_instance_valid(_geosync_body):
		radial = (_geosync_body.global_transform.basis * _geosync_local_dir).normalized()
	else:
		_orbit_elevation = clampf(_orbit_elevation, -ORBIT_ELEVATION_LIMIT, ORBIT_ELEVATION_LIMIT)
		radial = _radial_from_azel()
	var up: Vector3 = Vector3.UP if absf(radial.dot(Vector3.UP)) < 0.985 else Vector3.RIGHT
	var upn: Vector3 = radial                                   # radial normal at the ground point
	var ceiling: float = _ceiling_radius()
	if is_nan(ceiling):
		_ground_ready = false
		return
	# THE POSE IS A FUNCTION OF GROUND THAT EXISTS. While the body cannot say where its surface is, the
	# eye waits over the ceiling, above every hill this body can have.
	var look_r: float = _surface_radius_at(radial)
	var look_known: bool = not is_nan(look_r)
	var look_res: float = INF if not look_known else _ground_resolution_at(_orbit_center + radial * look_r)
	_look_res = look_res
	if look_known and not _ground_ready:
		_smooth_surface_r = 0.0                                 # the ease smooths ridges, not the drop off the hold
	var base_r: float = _eased_surface_radius(look_r if look_known else ceiling)
	var surface_pt: Vector3 = _orbit_center + radial * base_r
	var back: Vector3 = _orbit_back - radial * _orbit_back.dot(radial)   # a tangent "behind" the eye
	if back.length() < 0.01:
		back = up - radial * up.dot(radial)
	if back.length() < 0.01:
		back = Vector3.RIGHT - radial * Vector3.RIGHT.dot(radial)
	back = back.normalized()
	var alt: float = _rts_altitude()
	var look_pt: Vector3 = surface_pt + upn * ARC_LOOK_HEIGHT   # gaze at creature height
	var rise: float = maxf(alt - ARC_LOOK_HEIGHT, 0.1)          # vertical run from the look target up to the eye
	var eye_back: float = rise / maxf(tan(_rts_pitch), 0.0001)
	var pos: Vector3 = look_pt + upn * rise + back * eye_back
	# THE FLOOR IS THE GROUND UNDER THE EYE, NOT UNDER THE GAZE. Measured under the look point, a ridge
	# standing between the two put the eye inside it.
	var pos_off: Vector3 = pos - _orbit_center
	var eye_dir: Vector3 = pos_off.normalized() if pos_off.length() > 0.001 else radial
	var eye_r: float = _surface_radius_at(eye_dir)
	_ground_res_prev = _ground_res
	_ground_res = maxf(_frame_ground_res(look_pt, pos, back.cross(upn)),
		INF if is_nan(eye_r) else _ground_resolution_at(_orbit_center + eye_dir * eye_r))
	var min_r: float = (ceiling if is_nan(eye_r) else eye_r) + MIN_EYE_CLEARANCE
	if pos_off.length() < min_r:
		pos = _orbit_center + eye_dir * min_r
	_ground_ready = look_known and not is_nan(eye_r)
	global_position = pos
	_aim_distance = pos.distance_to(look_pt)
	global_basis = Basis.looking_at(look_pt - pos, upn)
	# FREE-LOOK aim offset (MMB drag): pivot the camera in place on top of the orbit pose, without moving the globe.
	if not is_zero_approx(_aim_yaw) or not is_zero_approx(_aim_pitch):
		rotate_object_local(Vector3.UP, _aim_yaw)
		rotate_object_local(Vector3.RIGHT, _aim_pitch)
	_apply_depth_range(maxf(pos.distance_to(_orbit_center) - base_r, 1.0))


## Wire the planet body (VoxelWorld's `_body`) so GEOSYNC can read its rotating frame.
func set_geosync_body(body: Node3D) -> void:
	_geosync_body = body


func set_geosync(on: bool) -> void:
	if on == _geosync:
		return
	if on and _geosync_body != null and is_instance_valid(_geosync_body):
		_fly = false
		var world_radial: Vector3 = _radial_from_azel()
		_geosync_local_dir = (_geosync_body.global_transform.basis.inverse() * world_radial).normalized()
		_geosync = true
	else:
		if _geosync_body != null and is_instance_valid(_geosync_body):
			var wr: Vector3 = (_geosync_body.global_transform.basis * _geosync_local_dir).normalized()
			_orbit_elevation = asin(clampf(wr.y, -1.0, 1.0))
			_orbit_azimuth = atan2(wr.x, wr.z)
		_geosync = false
	_update_transform()


func is_geosync() -> bool:
	return _geosync


## Solar-system overview: drop into a MANUAL pulled-back framing (planet + sun in one shot).
func set_solar_view(pos: Vector3, look_target: Vector3, orbit_dist: float) -> void:
	_solar_view = true
	_geosync = false
	_fly = false
	global_position = pos
	look_at(look_target, Vector3.UP)
	_distance = orbit_dist
	_target_distance = orbit_dist
	_zoom_vel = 0.0
	_orbit_max_distance = maxf(_orbit_max_distance, orbit_dist * 2.0)
	far = clampf(orbit_dist * 4.0, 4000.0, 80000.0)


## Leave the solar overview and drop back to the RTS working altitude.
func set_planet_view() -> void:
	_solar_view = false
	_orbit_max_distance = _effective_orbit_max()
	_distance = clampf(_orbit_radius + _start_altitude(), _orbit_min_distance, _orbit_max_distance)
	_target_distance = _distance
	_zoom_vel = 0.0
	_update_transform()


func set_rts_pitch_deg(deg: float) -> void:
	_rts_pitch = deg_to_rad(clampf(deg, RTS_PITCH_MIN_DEG, RTS_PITCH_MAX_DEG))
	if _orbit_mode:
		_update_transform()


## The current RTS view pitch in degrees.
func rts_pitch_deg() -> float:
	return rad_to_deg(_rts_pitch)


func is_solar_view() -> bool:
	return _solar_view


func set_fly(on: bool) -> void:
	_pose = false
	if on == _fly:
		return
	if on:
		_fly = true
		_geosync = false
		_solar_view = false
		_fly_pos = global_position
		var fwd: Vector3 = -global_transform.basis.z
		_fly_look = fwd.normalized() if fwd.length() > 0.001 else Vector3.FORWARD
		_fly_rest()
		_update_fly_transform()
	else:
		_fly = false
		var radial: Vector3 = _fly_pos - _orbit_center
		if radial.length() > 0.001:
			var rn: Vector3 = radial.normalized()
			_orbit_elevation = clampf(asin(clampf(rn.y, -1.0, 1.0)), -ORBIT_ELEVATION_LIMIT, ORBIT_ELEVATION_LIMIT)
			_orbit_azimuth = atan2(rn.x, rn.z)
			_distance = clampf(radial.length(), _orbit_min_distance, _orbit_max_distance)
		_update_transform()


func is_fly() -> bool:
	return _fly


## Directly place the drone (verification aid / scripted framing): position + a look target, then rebuild.
func place_fly(pos: Vector3, look_target: Vector3) -> void:
	_fly = true
	_pose = false
	_geosync = false
	_solar_view = false
	_fly_pos = pos
	var d: Vector3 = look_target - pos
	if d.length() > 0.001:
		_fly_look = d.normalized()
	_fly_rest()
	_update_fly_transform()


## A SHOT POSE: the eye `alt_m` metres over the ground at the framed site, aimed `pitch_deg` from the
## horizon (negative looks down) and turned `yaw_deg` about the site's radial from the framing axis.
func place_pose(alt_m: float, pitch_deg: float, yaw_deg: float) -> void:
	_pose_site = _pose_site_dir()
	_pose_alt_m = maxf(alt_m, MIN_EYE_CLEARANCE)
	_pose_pitch = deg_to_rad(pitch_deg)
	_pose_yaw = deg_to_rad(yaw_deg)
	_pose = true
	_fly = true
	_geosync = false
	_solar_view = false
	_smooth_surface_r = 0.0
	_ground_ready = false
	_ground_res = INF
	_ground_res_prev = -1.0
	_look_res = INF
	_solve_pose()


## The site the pose stands over, in the BODY's own frame: the slice box's, or the opening framing's.
func _pose_site_dir() -> Vector3:
	if _pose and _pose_site.length() > 0.001:
		return _pose_site
	if _geosync and _geosync_local_dir.length() > 0.001:
		return _geosync_local_dir.normalized()
	var radial: Vector3 = _radial_from_azel()
	if _geosync_body == null or not is_instance_valid(_geosync_body):
		return radial
	return (_geosync_body.global_transform.basis.inverse() * radial).normalized()


func _pose_world_radial() -> Vector3:
	if _geosync_body == null or not is_instance_valid(_geosync_body):
		return _pose_site
	return (_geosync_body.global_transform.basis * _pose_site).normalized()


## Re-solved every frame: the ground arrives under a standing eye, and the pose's altitude is measured
## from that ground, not from the ceiling the eye waits over while the body has not said where it is.
func _solve_pose() -> void:
	var radial: Vector3 = _pose_world_radial()
	var ceiling: float = _ceiling_radius()
	if is_nan(ceiling):
		_ground_ready = false
		return
	var site_r: float = _surface_radius_at(radial)
	var known: bool = not is_nan(site_r)
	var base_r: float = _eased_surface_radius(site_r if known else ceiling)
	var site: Vector3 = _orbit_center + radial * base_r
	var eye: Vector3 = _orbit_center + radial * (base_r + _pose_alt_m)
	var axis: Vector3 = -_orbit_back if _orbit_back.length() > 0.001 else Vector3.UP
	var heading: Vector3 = axis - radial * axis.dot(radial)
	if heading.length() < 0.001:
		heading = Vector3.RIGHT - radial * Vector3.RIGHT.dot(radial)
	heading = heading.normalized().rotated(radial, _pose_yaw)
	_fly_pos = eye
	_fly_look = (heading * cos(_pose_pitch) + radial * sin(_pose_pitch)).normalized()
	_fly_rest()
	var look_pt: Vector3 = _pose_look_point(eye, _fly_look, base_r)
	var right: Vector3 = _fly_look.cross(radial)
	right = right.normalized() if right.length() > 0.001 else heading
	_ground_res_prev = _ground_res
	_look_res = _ground_resolution_at(look_pt)
	_ground_res = maxf(_frame_ground_res(look_pt, eye, right), _ground_resolution_at(site))
	_ground_ready = known and is_finite(_look_res)
	_aim_distance = eye.distance_to(look_pt)
	_update_fly_transform()


## The ground the pose composes around: where the view ray meets the body, or the horizon along the
## heading when it meets nothing. Both land ON the surface, which is what the streamer is asked about.
func _pose_look_point(eye: Vector3, dir: Vector3, r: float) -> Vector3:
	var o: Vector3 = eye - _orbit_center
	var b: float = o.dot(dir)
	var disc: float = b * b - (o.dot(o) - r * r)
	var t: float = sqrt(maxf(o.dot(o) - r * r, 0.0))
	if disc > 0.0 and -b - sqrt(disc) > 0.0:
		t = -b - sqrt(disc)
	var p: Vector3 = (eye + dir * t) - _orbit_center
	return _orbit_center + (p.normalized() if p.length() > 0.001 else o.normalized()) * r


## Local radial "up" at the drone's position (away from the planet core).
func _fly_radial_up() -> Vector3:
	var r: Vector3 = _fly_pos - _orbit_center
	return r.normalized() if r.length() > 0.001 else Vector3.UP


func _update_fly_transform() -> void:
	global_position = _fly_pos
	var up: Vector3 = _fly_radial_up()
	if absf(_fly_look.dot(up)) > 0.999:
		up = Vector3.UP if absf(_fly_look.dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
	# AIM ALONG THE DIRECTION, NEVER AT A NEARBY POINT. Standing 6371 km from the origin, a target one
	# metre ahead rounds back onto the eye in fp32 and look_at() refuses, leaving the last orientation.
	global_basis = Basis.looking_at(_fly_look, up)
	# The depth range is the eye's height over the body. Where the terrain cannot say where its surface
	# is, the DECLARED radius stands in: a NAN here puts the far plane at NAN and the frame draws nothing.
	var ground_r: float = _surface_radius_at(up)
	_apply_depth_range(maxf(_fly_pos.distance_to(_orbit_center)
		- (_orbit_radius if is_nan(ground_r) else ground_r), 1.0))


## Hold-drag mouse-look: the drag turns the GOAL; the aim eases onto it over FLY_LOOK_TAU_S.
func fly_look_drag(rel: Vector2) -> void:
	_pose = false                             # a hand on the mouse ends the scripted framing too
	var up: Vector3 = _fly_radial_up()
	var goal: Vector3 = _fly_look_goal.rotated(up, -rel.x * FLY_LOOK_SENS).normalized()
	var right: Vector3 = goal.cross(up)
	if right.length() > 0.001:
		goal = goal.rotated(right.normalized(), -rel.y * FLY_LOOK_SENS).normalized()
	_fly_look_goal = _pitch_limited(goal)


## The aim held off the local poles, where the up-vector the basis is built from degenerates.
func _pitch_limited(dir: Vector3) -> Vector3:
	var up: Vector3 = _fly_radial_up()
	var lim: float = sin(deg_to_rad(FLY_PITCH_LIMIT_DEG))
	var s: float = dir.dot(up)
	if absf(s) <= lim:
		return dir
	var flat: Vector3 = dir - up * s
	if flat.length() < 0.001:
		return _fly_look
	return (flat.normalized() * sqrt(maxf(0.0, 1.0 - lim * lim)) + up * (lim if s > 0.0 else -lim)).normalized()


## THE EYE'S HEIGHT OVER THE GROUND BENEATH IT, metres. With no return from the terrain it is measured
## off the body's declared surface instead, the way an altimeter reads the datum with no radar echo.
func fly_height_m() -> float:
	var ground_r: float = _surface_radius_at(_fly_radial_up())
	var base: float = _orbit_radius if is_nan(ground_r) else ground_r
	return maxf(0.0, _fly_pos.distance_to(_orbit_center) - base)


## Circular orbital speed at the eye's own radius: nothing passes this body faster and stays near it.
## INF while no body has measured a mass, which is a missing measurement, not a ceiling of zero.
func fly_orbital_speed() -> float:
	if not _body_answers("mass"):
		return INF
	var m: float = _geosync_body.mass()
	var r: float = _fly_pos.distance_to(_orbit_center)
	if m <= 0.0 or r <= 0.0:
		return INF
	return sqrt(LAPhysical.GRAVITATIONAL_CONSTANT * m / r)


## CRUISE SPEED, m/s: proportional to height so the ground slides past at the same rate from any
## altitude, floored at a running pace on the deck, capped at orbital speed.
func fly_speed(boost: bool = false) -> float:
	var v: float = maxf(FLY_SPEED_FLOOR_M_S, FLY_SPEED_PER_HEIGHT * fly_height_m())
	v *= _fly_speed_mult * (FLY_BOOST if boost else 1.0)
	return minf(v, fly_orbital_speed())


## The wheel sets how fast the drone cruises, one notch at a time. It does not move it.
func fly_speed_notch(dir: float) -> void:
	_fly_speed_mult = clampf(_fly_speed_mult * pow(ZOOM_STEP, dir), 1.0 / FLY_MULT_RANGE, FLY_MULT_RANGE)


func fly_speed_mult() -> float:
	return _fly_speed_mult


## Per-frame drone movement, from the keyboard.
func _fly_step(delta: float) -> void:
	fly_drive(delta, _fly_stick(), Input.is_key_pressed(KEY_SHIFT))


## The stick as a unit-ish vector in the drone's own frame (right, up, forward). Read here alone, so the
## motion below can be driven with a synthetic one.
func _fly_stick() -> Vector3:
	var s: Vector3 = Vector3.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		s.z += 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		s.z -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		s.x += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		s.x -= 1.0
	if Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_E):
		s.y += 1.0
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_Q):
		s.y -= 1.0
	return s


## THE MOTION: the stick commands a velocity, the drone's own eases onto it over one time constant, and
## a released stick commands zero, so it coasts to rest instead of stopping dead.
func fly_drive(delta: float, stick: Vector3, boost: bool) -> void:
	var up: Vector3 = _fly_radial_up()
	var right: Vector3 = _fly_look.cross(up)
	right = right.normalized() if right.length() > 0.001 else Vector3.RIGHT
	var moving: bool = stick.length() > 0.001
	if moving:
		_pose = false                     # a hand on the stick ends the scripted framing
		_fly_goto_on = false
	elif _pose and not _fly_goto_on:
		_solve_pose()
		return
	var speed: float = fly_speed(boost)
	var want: Vector3 = Vector3.ZERO
	if moving:
		want = (right * stick.x + up * stick.y + _fly_look * stick.z).normalized() * speed
	elif _fly_goto_on:
		var to: Vector3 = _fly_goto - _fly_pos
		if to.length() <= maxf(speed * delta, 1.0):
			_fly_goto_on = false
		else:
			want = to.normalized() * minf(speed, to.length() / FLY_RESPONSE_TAU_S)
	var k: float = 1.0 - exp(-delta / FLY_RESPONSE_TAU_S)
	_fly_vel = _fly_vel.lerp(want, k)
	_fly_pos += _fly_vel * delta
	_fly_ease_look(delta)
	_update_fly_transform()


## The aim eases onto its goal over FLY_LOOK_TAU_S, so a flicked mouse turns the drone rather than
## snapping it. Straight through an antipodal goal there is no shortest arc, so it is nudged off-axis.
func _fly_ease_look(delta: float) -> void:
	var goal: Vector3 = _fly_look_goal
	if goal.length() < 0.001:
		return
	if _fly_look.dot(goal) < -0.999:
		goal = goal.rotated(_fly_radial_up(), 0.01)
	var eased: Vector3 = _fly_look.lerp(goal, 1.0 - exp(-delta / FLY_LOOK_TAU_S))
	if eased.length() < 0.001:
		return
	_fly_look = _pitch_limited(eased.normalized())


## THE BOX'S FOOTPRINT ON THE GROUND: its corners with the site radial taken out, and the radius of the
## smallest circle around them. That is what a framing fits, not the atmosphere column above it.
static func footprint_radius(box: AABB, site_dir: Vector3) -> float:
	var n: Vector3 = site_dir.normalized()
	var h: Vector3 = box.size * 0.5
	var r: float = 0.0
	for i in 8:
		var c: Vector3 = Vector3(h.x if (i & 1) else -h.x, h.y if (i & 2) else -h.y,
			h.z if (i & 4) else -h.z)
		r = maxf(r, (c - n * c.dot(n)).length())
	return r


## HOW FAR BACK A SUBJECT OF THAT RADIUS FITS, metres: its bounding sphere inside the narrower of the
## frustum's two half-angles, with the framing margin left around it.
func fit_distance(radius_m: float) -> float:
	var half: float = deg_to_rad(fov) * 0.5
	var vp: Viewport = get_viewport()
	if vp != null:
		var sz: Vector2 = vp.get_visible_rect().size
		if sz.x > 0.0 and sz.y > 0.0:
			half = minf(half, atan(tan(half) * sz.x / sz.y))
	return radius_m * FRAME_MARGIN / maxf(sin(half), 0.001)


## FRAME THE SIMULATED BOX: turn onto the ground under its site and, in flight, back off along that look
## until the footprint fits. False where the body has not said where its surface is: nothing to frame on.
func frame_simulation(site_dir: Vector3, box: AABB) -> bool:
	var footprint_radius_m: float = footprint_radius(box, site_dir)
	if site_dir.length() < 0.001 or footprint_radius_m <= 0.0:
		return false
	var site: Vector3 = site_dir.normalized()
	var radial: Vector3 = site
	if _geosync_body != null and is_instance_valid(_geosync_body):
		radial = (_geosync_body.global_transform.basis * site).normalized()
	var ground_r: float = _surface_radius_at(radial)
	if is_nan(ground_r):
		return false
	var fit: float = fit_distance(footprint_radius_m)
	if not _fly:
		_pose_site = site
		_pose = true
		place_pose(fit * sin(deg_to_rad(SLICE_PITCH_DEG)), -SLICE_PITCH_DEG, 0.0)
		return true
	var centre: Vector3 = _orbit_center + radial * ground_r
	var to: Vector3 = centre - _fly_pos
	if to.length() < 0.001:
		return false
	_pose = false
	_fly_look_goal = _pitch_limited(to.normalized())
	_fly_goto_on = to.length() < fit
	if _fly_goto_on:
		_fly_goto = centre - _fly_look_goal * fit
	return true


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			# Plain middle-mouse held and dragged aims the camera in place.
			if mb.pressed:
				stop_tracking()          # grabbing the view takes back control from a storm follow
				if Input.is_key_pressed(KEY_SHIFT):
					_set_panning(true)
				else:
					_aiming = true
			else:
				_set_panning(false)
				_aiming = false
			return
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_drag_orbit_armed = (mb.button_index == MOUSE_BUTTON_LEFT)
				_drag_orbiting = false
				_drag_orbit_travel = 0.0
			else:
				_drag_orbit_armed = false
				_drag_orbiting = false
			return
		if mb.pressed:
			# Ctrl + wheel is reserved for resizing the spawn brush (VoxelInteraction handles it).
			if mb.ctrl_pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
				return
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				stop_tracking()
				if _fly:
					fly_speed_notch(1.0)
				else:
					_zoom(1.0 / ZOOM_STEP)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				stop_tracking()
				if _fly:
					fly_speed_notch(-1.0)
				else:
					_zoom(ZOOM_STEP)

	elif event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		if _aiming:
			var ax: float = -mm.relative.x if _invert_rotate_x else mm.relative.x
			var ay: float = -mm.relative.y if _invert_rotate_y else mm.relative.y
			_aim_yaw = clampf(_aim_yaw - ax * AIM_DRAG_SPEED, -AIM_YAW_LIMIT, AIM_YAW_LIMIT)
			_aim_pitch = clampf(_aim_pitch + ay * AIM_DRAG_SPEED, -AIM_PITCH_LIMIT, AIM_PITCH_LIMIT)
			if _fly:
				fly_look_drag(mm.relative)
			else:
				_update_transform()
			return
		if _drag_orbit_armed:
			# Accumulate travel; once past the click threshold the hold becomes a planet-rotate drag.
			_drag_orbit_travel += mm.relative.length()
			if not _drag_orbiting and _drag_orbit_travel >= DRAG_ORBIT_THRESHOLD:
				_drag_orbiting = true
				stop_tracking()
			if _drag_orbiting:
				if _fly:
					fly_look_drag(mm.relative)
				else:
					_orbit_drag(mm.relative)
					_update_transform()
				return
		if _panning:
			# Drag the land under the cursor: moving the mouse right slides the world right, so the focus moves opposite.
			var scale: float = DRAG_PAN_SPEED * _distance_pan_factor()
			_pan_ground(-mm.relative.x * scale, mm.relative.y * scale)
			_update_transform()
		elif _orbiting:
			if _fly:
				fly_look_drag(mm.relative)
			else:
				_orbit_drag(mm.relative)
				_update_transform()


## The drone is standing still and aimed where it is aimed: no carried velocity, no framing in flight.
func _fly_rest() -> void:
	_fly_look_goal = _fly_look
	_fly_vel = Vector3.ZERO
	_fly_goto_on = false


func _orbit_drag(rel: Vector2) -> void:
	var dx: float = -rel.x if _invert_rotate_x else rel.x
	var dy: float = -rel.y if _invert_rotate_y else rel.y
	if _geosync and _geosync_body != null and is_instance_valid(_geosync_body):
		var cur: Vector3 = (_geosync_body.global_transform.basis * _geosync_local_dir).normalized()
		var right: Vector3 = cur.cross(Vector3.UP)
		right = right.normalized() if right.length() > 0.001 else Vector3.RIGHT
		var moved: Vector3 = cur.rotated(Vector3.UP, dx * ORBIT_SENSITIVITY).rotated(right, -dy * ORBIT_SENSITIVITY).normalized()
		_geosync_local_dir = (_geosync_body.global_transform.basis.inverse() * moved).normalized()
		return
	_orbit_azimuth += dx * ORBIT_SENSITIVITY
	_orbit_elevation = clampf(_orbit_elevation - dy * ORBIT_SENSITIVITY, -ORBIT_ELEVATION_LIMIT, ORBIT_ELEVATION_LIMIT)


func _set_panning(active: bool) -> void:
	_panning = active
	_update_mouse_capture()


func _set_orbiting(active: bool) -> void:
	_orbiting = active
	_update_mouse_capture()


## Capture the mouse only while actively dragging (pan or orbit) so a drag isn't limited by the window edge.
func _update_mouse_capture() -> void:
	if _panning or _orbiting:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _zoom(factor: float) -> void:
	# Set the TARGET distance.
	if _orbit_mode:
		# Re-read the progression-capped ceiling each zoom so a freshly-earned stage lets the player pull out further.
		_orbit_max_distance = _effective_orbit_max()
		_target_distance = clampf(_target_distance * factor, _orbit_min_distance, _orbit_max_distance)
	else:
		_target_distance = clampf(_target_distance * factor, MIN_DISTANCE, MAX_DISTANCE)


# WHAT THE EYE STANDS OVER: the solid surface, or the sea when the sea is higher. NAN when the body cannot
# say — a missing measurement is missing, and the pose then waits above the terrain's ceiling.
func _surface_radius_at(radial: Vector3) -> float:
	if not _body_answers("surface_radius"):
		return NAN
	var r: float = _geosync_body.surface_radius(radial)
	return NAN if is_nan(r) or r <= 0.0 else r


func _body_answers(method: String) -> bool:
	return _geosync_body != null and is_instance_valid(_geosync_body) and _geosync_body.has_method(method)


# ABOVE EVERY HILL THE BODY HAS: the terrain's own ceiling, where the eye stands while the ground under it
# has not been built yet. NAN when the body cannot say, and then the rig does not move the camera at all.
func _ceiling_radius() -> float:
	if not _body_answers("max_surface_radius"):
		return NAN
	var r: float = _geosync_body.max_surface_radius()
	return NAN if is_nan(r) or r <= 0.0 else r


# HOW FINELY THE GROUND UNDER A POINT IS DRAWN, in metres of voxel edge. INF where none is drawn yet.
func _ground_resolution_at(surface_pt: Vector3) -> float:
	if not _body_answers("meshed_resolution_at"):
		return INF
	return _geosync_body.meshed_resolution_at(surface_pt)


## THE COARSEST GROUND THE FRAME HOLDS, not the ground under one ray: the look point walked across the
## frame's own width at the range it was framed at. A shot taken when the gaze point alone is fine
## catches the rest of the picture still coarse.
func _frame_ground_res(look_pt: Vector3, eye: Vector3, right: Vector3) -> float:
	var half_w: float = eye.distance_to(look_pt) * tan(deg_to_rad(fov) * 0.5)
	var worst: float = 0.0
	for f: float in FRAME_PROBE_FRAC:
		var dir: Vector3 = (look_pt + right * (f * half_w) - _orbit_center).normalized()
		var r: float = _surface_radius_at(dir)
		if is_nan(r):
			return INF
		worst = maxf(worst, _ground_resolution_at(_orbit_center + dir * r))
	return worst


## True while the pose is solved from ground the terrain has actually built under the eye.
func ground_ready() -> bool:
	return _ground_ready


## The gaze is drawn as finely as the eye stands above it, and the coarsest ground across the frame has
## stopped changing: the streamer has finished with this view.
func ground_resolved() -> bool:
	return _ground_ready and _look_res <= maxf(_eye_altitude(), MIN_EYE_CLEARANCE) \
		and is_finite(_ground_res) and is_equal_approx(_ground_res, _ground_res_prev)


## How high the eye stands over the ground it was placed above, whichever pose put it there.
func _eye_altitude() -> float:
	return _pose_alt_m if _pose else _rts_altitude()


## How far down the view axis the pose put its look point: the ground the frame was composed around.
func aim_distance() -> float:
	return _aim_distance


# The eased radius under the LOOK point; a ridge passing beneath the gaze must not jolt the frame.
func _eased_surface_radius(r: float) -> float:
	if _smooth_surface_r <= 0.0:
		_smooth_surface_r = r
	else:
		var dt: float = get_process_delta_time()
		var k: float = 1.0 - exp(-dt / maxf(TERRAIN_FOLLOW_TIME, 0.0001))
		_smooth_surface_r = lerpf(_smooth_surface_r, r, k)
	return _smooth_surface_r


## Critically-damped spring toward `target` over ~ZOOM_SMOOTH_TIME seconds (the standard SmoothDamp).
func _smooth_damp_distance(current: float, target: float, dt: float) -> float:
	var smooth_time: float = maxf(ZOOM_SMOOTH_TIME, 0.0001)
	var omega: float = 2.0 / smooth_time
	var x: float = omega * dt
	var exp_f: float = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var change: float = current - target
	var temp: float = (_zoom_vel + omega * change) * dt
	_zoom_vel = (_zoom_vel - omega * temp) * exp_f
	return target + (change + temp) * exp_f


## Pan factor relative to the reference distance, so pan speeds scale with zoom.
func _distance_pan_factor() -> float:
	return _distance / PAN_REFERENCE_DISTANCE


## Move the focus on the horizontal ground plane in the current yaw frame.
func _pan_ground(right: float, forward: float) -> void:
	var fwd: Vector3 = Vector3(sin(_yaw), 0.0, cos(_yaw))
	var rgt: Vector3 = Vector3(cos(_yaw), 0.0, -sin(_yaw))
	# Camera looks toward -forward (down its -Z), so "up on screen" pans the focus forward.
	_focus += rgt * right - fwd * forward
	_clamp_focus()


# True while this window holds keyboard/pointer focus: the only state in which a pointer is over it.
func _window_focused() -> bool:
	var w: Window = get_window()
	return w != null and w.has_focus()


func _surface_walk(delta: float) -> void:
	if not _orbit_mode or _fly or _solar_view:
		return
	var fwd_in: float = 0.0
	var right_in: float = 0.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		fwd_in += 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		fwd_in -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		right_in += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		right_in -= 1.0
	# EDGE-SCROLL IS A POINTER AT THE EDGE OF A FOCUSED WINDOW. Without focus there is no pointer over the
	# window, and the last-known position an automated run reports is the corner: a standing scroll command
	# that walked the camera across the planet for the whole run.
	var vp: Viewport = get_viewport()
	if vp != null and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and _window_focused():
		var mp: Vector2 = vp.get_mouse_position()
		var sz: Vector2 = vp.get_visible_rect().size
		if mp.x >= 0.0 and mp.y >= 0.0 and mp.x <= sz.x and mp.y <= sz.y:
			if mp.x < EDGE_MARGIN:
				right_in -= 1.0
			elif mp.x > sz.x - EDGE_MARGIN:
				right_in += 1.0
			if mp.y < EDGE_MARGIN:
				fwd_in += 1.0
			elif mp.y > sz.y - EDGE_MARGIN:
				fwd_in -= 1.0
	if fwd_in == 0.0 and right_in == 0.0:
		return
	# Current world view direction from the planet centre (the radial the transform is built around).
	var geo: bool = _geosync and _geosync_body != null and is_instance_valid(_geosync_body)
	var radial: Vector3 = (_geosync_body.global_transform.basis * _geosync_local_dir).normalized() if geo else _radial_from_azel()
	# Screen forward/right projected onto the tangent plane at the view point.
	var t_fwd: Vector3 = -global_transform.basis.z
	t_fwd = (t_fwd - radial * t_fwd.dot(radial))
	if t_fwd.length() < 0.001:
		t_fwd = global_transform.basis.x.cross(radial)   # looking straight down: fall back to a stable tangent
	t_fwd = t_fwd.normalized()
	var t_rgt: Vector3 = radial.cross(t_fwd).normalized()
	var move: Vector3 = t_fwd * fwd_in - t_rgt * right_in
	if move.length() < 0.001:
		return
	var step: float = SURFACE_WALK_SPEED * delta * clampf(0.22 + (1.0 - _approach_t()), 0.22, 1.0)
	var new_radial: Vector3 = (radial + move.normalized() * step).normalized()
	if geo:
		# The geosync rebuild in _process (which runs right after this) picks up the new local dir.
		_geosync_local_dir = (_geosync_body.global_transform.basis.inverse() * new_radial).normalized()
	else:
		_orbit_elevation = clampf(asin(clampf(new_radial.y, -1.0, 1.0)), -ORBIT_ELEVATION_LIMIT, ORBIT_ELEVATION_LIMIT)
		_orbit_azimuth = atan2(new_radial.x, new_radial.z)
		_update_transform()


func _process(delta: float) -> void:
	# Don't drive movement in the editor (@tool) preview.
	if Engine.is_editor_hint():
		return
	# Undo last frame's shake so the offset never accumulates into the base position.
	global_position -= _shake_applied
	_shake_applied = Vector3.ZERO
	# SUNNYSIDE.
	if _sunnyside_pending and _orbit_mode:
		if _sun_light != null and is_instance_valid(_sun_light):
			var to_sun: Vector3 = _sun_light.global_transform.basis.z
			if to_sun.length() > 0.001:
				orient_toward(to_sun)
				_sunnyside_pending = false
		else:
			_sunnyside_pending = false
	# GROUND-WALK: WASD/arrows + edge-scroll sweep the surface view while zoomed in.
	_surface_walk(delta)
	if _orbit_mode and (absf(_distance - _target_distance) > 0.02 or absf(_zoom_vel) > 0.01):
		_distance = _smooth_damp_distance(_distance, _target_distance, delta)
		if absf(_distance - _target_distance) < 0.02:
			_distance = _target_distance
			_zoom_vel = 0.0
		var geosyncing: bool = _geosync and not _solar_view and _geosync_body != null and is_instance_valid(_geosync_body)
		if not geosyncing:
			_update_transform()
	# FLY: drive the drone from the keyboard every frame (WASD/lift/descend/boost).
	if _fly:
		_fly_step(delta)
	# THE GROUND ARRIVES AFTER THE POSE DOES. Terrain streams in under a standing eye, so the pose is
	# re-solved every frame and not only when the player moves; solved once, the eye ends up inside a hill.
	elif _orbit_mode and not _solar_view:
		_update_orbit_transform()
	_decay_shake(delta)


func _decay_shake(delta: float) -> void:
	_trauma = maxf(0.0, _trauma - TRAUMA_DECAY * delta)
	if _trauma > 0.0:
		var s: float = _trauma * _trauma * SHAKE_MAG
		_shake_applied = Vector3(_shake_rng.randf_range(-1.0, 1.0), _shake_rng.randf_range(-1.0, 1.0), _shake_rng.randf_range(-1.0, 1.0)) * s
		global_position += _shake_applied


func aim_ray(screen_pos: Vector2 = Vector2(-1.0, -1.0)) -> Dictionary:
	var sp: Vector2 = screen_pos
	if sp.x < 0.0 and sp.y < 0.0:
		var vp: Viewport = get_viewport()
		if vp != null:
			sp = vp.get_visible_rect().size * 0.5
		else:
			sp = Vector2.ZERO

	# project_ray_* need the camera to be inside a viewport.
	if not is_inside_tree():
		return {
			"origin": global_position,
			"dir": -global_transform.basis.z,
		}

	return {
		"origin": project_ray_origin(sp),
		"dir": project_ray_normal(sp),
	}
