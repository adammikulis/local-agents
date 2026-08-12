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
const RTS_ALT_MAX: float = 220.0     # farthest zoom — a wide tactical view, still clearly on the surface
# The most-constrained campaign ceiling (stage 1). The progression ladder interpolates from here up to
# RTS_ALT_MAX as stages unlock; see _effective_alt_max().
const RTS_ALT_CEILING_MIN: float = 70.0
# Where the view opens. Campaign opens close (working a curated patch); sandbox opens at a comfortable
# working height with the local area in frame.
const RTS_ALT_START: float = 95.0
const RTS_ALT_START_CAMPAIGN: float = 40.0

const RTS_PITCH_DEG: float = 50.0
const RTS_PITCH_MIN_DEG: float = 40.0
const RTS_PITCH_MAX_DEG: float = 60.0

const ORBIT_MAX_DISTANCE_MULT: float = 6.0
const ORBIT_DEFAULT_DISTANCE_MULT: float = 2.4   # retained for the (deferred) solar/space framing only
# Clamp elevation shy of the poles so "up" stays world-up without a gimbal flip through the pole.
const ORBIT_ELEVATION_LIMIT: float = deg_to_rad(85.0)
const SURFACE_WALK_SPEED: float = 0.8     # radians/sec of surface sweep at full stick (before the near-zoom taper)

const ARC_LOOK_HEIGHT: float = 2.2
const MIN_EYE_CLEARANCE: float = 6.0      # eye never sits closer than this above the terrain beneath the view
const TERRAIN_FOLLOW_TIME: float = 0.35   # ease time (s) of the terrain-radius follow — smooths ridges under the eye

const PAN_REFERENCE_DISTANCE: float = 100.0

var _focus: Vector3 = Vector3.ZERO
var _distance: float = 140.0
var _target_distance: float = 140.0       # wheel-set zoom goal; _distance eases toward it (smooth-zoom glide)
var _zoom_vel: float = 0.0                 # critically-damped spring velocity for the zoom glide
# SUNNYSIDE START: open the orbit view over the lit hemisphere. Resolved one-shot on the first orbit frame
# (the sky controller orients the sun in its own per-frame update, so it is not yet placed at _ready time).
var _sun_light: Node3D = null
var _sunnyside_pending: bool = false
var _yaw: float = 0.0
var _pitch: float = deg_to_rad(55.0)
var _panning: bool = false
var _orbiting: bool = false
# LMB/RMB "hold to rotate the planet" drag-orbit. Armed on press, becomes active once the drag passes
# DRAG_ORBIT_THRESHOLD so a click still falls through to select/cast. Released → stops (as the player expects).
var _drag_orbiting: bool = false
var _drag_orbit_armed: bool = false
var _drag_orbit_travel: float = 0.0
# MIDDLE-mouse (scroll-wheel) held-drag AIMS the camera in place (free-look yaw/pitch offset on top of the orbit
# pose) — pivot your head without moving the globe. LEFT-mouse held-drag moves the globe (orbit). Shift+MMB pans.
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
# Constant RTS view pitch, radians. Held across the whole zoom band; adjustable within
# [RTS_PITCH_MIN_DEG, RTS_PITCH_MAX_DEG] via set_rts_pitch_deg().
var _rts_pitch: float = deg_to_rad(RTS_PITCH_DEG)
var _smooth_surface_r: float = 0.0

var _geosync: bool = false
var _geosync_body: Node3D = null
var _geosync_local_dir: Vector3 = Vector3.UP
# --- Solar-system overview: a pulled-back framing that shows the planet + the (visible) sun together. It
# uses a MANUAL transform, so the per-frame geosync ride is suppressed while it is active.
var _solar_view: bool = false

const FLY_SPEED_FRAC: float = 0.30    # base move speed as a fraction of the planet radius, per second
const FLY_BOOST: float = 4.0          # Shift multiplier
const FLY_LOOK_SENS: float = 0.005    # radians per pixel for the hold-drag mouse-look
const FLY_PITCH_LIMIT_DOT: float = 0.96   # keep the look off the local up/down poles so the up-vector stays stable
var _fly: bool = false
var _fly_pos: Vector3 = Vector3.ZERO
var _fly_look: Vector3 = Vector3.FORWARD  # world-space unit forward (aim)

const TRACK_LERP: float = 3.0             # focus/zoom ease rate toward the target, per second
const TRACK_FOCUS_LIFT: float = 8.0       # keep the focus a touch above the ground foot of the storm
var _track_target: Node3D = null
var _track_distance: float = -1.0         # <0 = keep the current zoom (per the default contract)
var _track_pitch: float = -1.0            # <0 = keep the current pitch

var _pan_limit: float = 0.0


## Current zoom distance (focus→camera). The ocean plane reads this to size itself so it always
## reaches the horizon when zoomed out yet keeps fine tessellation when zoomed in.
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

# Screen shake (earthquakes, big impacts). Trauma 0..1 decays; the applied offset is removed and
# re-added each frame so it never accumulates into the fly position.
const SHAKE_MAG: float = 1.8
const TRAUMA_DECAY: float = 1.1
const SEISMIC_TRAUMA_GAIN: float = 2.0
var _trauma: float = 0.0
var _shake_applied: Vector3 = Vector3.ZERO
# This rig's own shake stream. A camera belongs to a viewer, not to a world, so it owns its stream outright
# and can never move a world's sequence.
var _shake_rng: LASimRng = LASimRng.make(LASimRng.DEFAULT_SEED, "camera_shake")
var _ecology: Object = null                # LAEcologyService — source of the seismic field (set by VoxelWorld)


## Add camera trauma (0..1). The low-level shake primitive; it decays on its own. Driven emergently
## by felt seismic energy (see _process), not by disaster code calling it directly.
func add_shake(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


## Wire the ecology so the rig can query seismic_energy_at() and shake in response to ground motion.
func set_ecology(ecology: Object) -> void:
	_ecology = ecology


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
## Called once by VoxelWorld after the terrain has streamed so we never start buried in a
## hillside or staring at the ground.
func frame_vista(center: Vector3) -> void:
	_focus = center + Vector3(0.0, 8.0, 0.0)
	_distance = 34.0
	_yaw = 0.0
	_pitch = deg_to_rad(38.0)
	_clamp_focus()
	_update_transform()


## Frame a wide, high vista over `center` — a whole-island overview (dev/screenshot aid). `dist` lets a
## test pull all the way out to check horizon/ocean coverage at max zoom.
func frame_overview(center: Vector3, dist: float = 360.0) -> void:
	if _orbit_mode:
		# In orbit mode this is a whole-planet framing request: recenter on the planet and set the
		# orbit distance (clamped to the zoom range), keeping the current azimuth/elevation.
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


## Recenter the camera on `point` (auto-select focus, meteor impacts, etc.) at a closer
## inspection distance. Goes through the focus state so the per-frame rebuild doesn't
## immediately overwrite a directly-poked transform.
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
	_orbit_azimuth = 0.0
	_orbit_elevation = deg_to_rad(20.0)
	stop_tracking()          # storm-follow is a flat-world concept; drop it on entering orbit
	_update_transform()


## Ask the rig to open over the LIT hemisphere: stores the sun light and orients toward it on the first orbit
## frame (deferred because the sky controller only places the sun during its per-frame update). One-time framing.
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


func _effective_alt_max() -> float:
	var m: float = clampf(LAGameProgression.zoom_ceiling_mult(),
		LAGameProgression.BASELINE_ZOOM_MULT, ORBIT_MAX_DISTANCE_MULT)
	var span: float = maxf(ORBIT_MAX_DISTANCE_MULT - LAGameProgression.BASELINE_ZOOM_MULT, 0.0001)
	var f: float = (m - LAGameProgression.BASELINE_ZOOM_MULT) / span
	return lerpf(RTS_ALT_CEILING_MIN, RTS_ALT_MAX, clampf(f, 0.0, 1.0))


## The orbit max distance in world units — the RTS altitude ceiling measured from the planet centre.
func _effective_orbit_max() -> float:
	return _orbit_radius + maxf(RTS_ALT_MIN, _effective_alt_max())


## Altitude the view opens at: campaign starts close (working a curated patch); sandbox opens at a
## comfortable working height. Clamped into the band by the caller.
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
	# Push the far plane out with zoom so the (now horizon-spanning) ocean isn't clipped when pulled
	# way out; keep it modest when zoomed in to preserve depth precision up close.
	far = clampf(_distance * 12.0, 4000.0, 20000.0)


## Unit world radial (planet centre → camera) from the azimuth/elevation pair. This is the FREE-mode pose.
func _radial_from_azel() -> Vector3:
	var e: float = clampf(_orbit_elevation, -ORBIT_ELEVATION_LIMIT, ORBIT_ELEVATION_LIMIT)
	return Vector3(cos(e) * sin(_orbit_azimuth), sin(e), cos(e) * cos(_orbit_azimuth))


func _rts_altitude() -> float:
	return clampf(_distance - _orbit_radius, RTS_ALT_MIN, RTS_ALT_MAX)


func _approach_t() -> float:
	var span: float = maxf(RTS_ALT_MAX - RTS_ALT_MIN, 0.0001)
	return clampf(1.0 - (_rts_altitude() - RTS_ALT_MIN) / span, 0.0, 1.0)


## How close the orbit camera is to the surface, for the sky cycle's altitude-aware atmosphere. In RTS mode the
## whole zoom band is well inside the atmosphere — even the ceiling is a couple hundred metres up — so the
## ground look is always fully engaged. Fly and the (deferred) solar overview still read as space.
func surface_blend() -> float:
	if not _orbit_mode or _solar_view or _fly:
		return 0.0
	return 1.0


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
	var base_r: float = _terrain_aware_radius(radial)
	var surface_pt: Vector3 = _orbit_center + radial * base_r
	var back: Vector3 = up - radial * up.dot(radial)            # a tangent "behind" the eye
	if back.length() < 0.01:
		back = Vector3.RIGHT - radial * Vector3.RIGHT.dot(radial)
	back = back.normalized()
	var alt: float = _rts_altitude()
	var look_pt: Vector3 = surface_pt + upn * ARC_LOOK_HEIGHT   # gaze at creature height
	var rise: float = maxf(alt - ARC_LOOK_HEIGHT, 0.1)          # vertical run from the look target up to the eye
	var eye_back: float = rise / maxf(tan(_rts_pitch), 0.0001)
	var pos: Vector3 = look_pt + upn * rise + back * eye_back
	# Anti-clip floor: never let the eye sit below the (eased) terrain beneath the view + clearance. The
	# tangential back-offset can slide it over a spot taller than the look point; push it straight back out
	# along its own radial if so. base_r is eased, so this floor moves smoothly too.
	var min_r: float = base_r + MIN_EYE_CLEARANCE
	var pos_off: Vector3 = pos - _orbit_center
	if pos_off.length() < min_r:
		var pdir: Vector3 = pos_off.normalized() if pos_off.length() > 0.001 else radial
		pos = _orbit_center + pdir * min_r
	global_position = pos
	look_at(look_pt, upn)
	# FREE-LOOK aim offset (MMB drag): pivot the camera in place on top of the orbit pose, without moving the globe.
	if not is_zero_approx(_aim_yaw) or not is_zero_approx(_aim_pitch):
		rotate_object_local(Vector3.UP, _aim_yaw)
		rotate_object_local(Vector3.RIGHT, _aim_pitch)
	# Far plane scaled to the orbit distance so the whole planet stays inside the frustum when pulled out.
	far = clampf(_distance * 4.0, 4000.0, 40000.0)


## Wire the planet body (VoxelWorld's `_body`) so GEOSYNC can read its rotating frame. Passed via the input
## controller's bind() so VoxelWorld stays untouched.
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


## Solar-system overview: drop into a MANUAL pulled-back framing (planet + sun in one shot). Geosync ride is
## suppressed while active. `orbit_dist` seeds the zoom so the wheel keeps working from the solar distance.
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
	if on == _fly:
		return
	if on:
		_fly = true
		_geosync = false
		_solar_view = false
		_fly_pos = global_position
		var fwd: Vector3 = -global_transform.basis.z
		_fly_look = fwd.normalized() if fwd.length() > 0.001 else Vector3.FORWARD
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
	_geosync = false
	_solar_view = false
	_fly_pos = pos
	var d: Vector3 = look_target - pos
	if d.length() > 0.001:
		_fly_look = d.normalized()
	_update_fly_transform()


## Local radial "up" at the drone's position (away from the planet core) — the reference for lift/descend and
## the roll-free camera up.
func _fly_radial_up() -> Vector3:
	var r: Vector3 = _fly_pos - _orbit_center
	return r.normalized() if r.length() > 0.001 else Vector3.UP


func _update_fly_transform() -> void:
	global_position = _fly_pos
	var up: Vector3 = _fly_radial_up()
	if absf(_fly_look.dot(up)) > 0.999:
		up = Vector3.UP if absf(_fly_look.dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
	look_at(_fly_pos + _fly_look, up)
	far = clampf(_fly_pos.distance_to(_orbit_center) * 4.0 + _orbit_radius * 2.0, 4000.0, 60000.0)


## Hold-drag mouse-look: yaw about the local radial up, pitch about the camera right, clamped off the poles.
func _fly_look_drag(rel: Vector2) -> void:
	var up: Vector3 = _fly_radial_up()
	_fly_look = _fly_look.rotated(up, -rel.x * FLY_LOOK_SENS).normalized()
	var right: Vector3 = _fly_look.cross(up)
	if right.length() > 0.001:
		right = right.normalized()
		var pitched: Vector3 = _fly_look.rotated(right, -rel.y * FLY_LOOK_SENS).normalized()
		if absf(pitched.dot(up)) < FLY_PITCH_LIMIT_DOT:
			_fly_look = pitched
	_update_fly_transform()


## Per-frame drone movement: WASD tangential (relative to the look), Space/E lift + Ctrl/Q descend along the
## radial, Shift boost. Speed scales gently with altitude so high flight covers ground faster than a low skim.
func _fly_step(delta: float) -> void:
	var up: Vector3 = _fly_radial_up()
	var fwd: Vector3 = _fly_look
	var right: Vector3 = fwd.cross(up)
	right = right.normalized() if right.length() > 0.001 else Vector3.RIGHT
	var move: Vector3 = Vector3.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		move += fwd
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		move -= fwd
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		move += right
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		move -= right
	if Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_E):
		move += up
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_Q):
		move -= up
	if move.length() > 0.001:
		var alt: float = maxf(0.0, _fly_pos.distance_to(_orbit_center) - _orbit_radius)
		var speed: float = _orbit_radius * FLY_SPEED_FRAC * (1.0 + alt / maxf(1.0, _orbit_radius))
		if Input.is_key_pressed(KEY_SHIFT):
			speed *= FLY_BOOST
		_fly_pos += move.normalized() * speed * delta
	_update_fly_transform()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			# Plain MMB (scroll-wheel) held + drag AIMS the camera in place (free-look yaw/pitch — pivot your view
			# without moving the globe); Shift + MMB pans. Moving the globe is LEFT-mouse drag (below).
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
			# Ctrl + wheel is reserved for resizing the spawn brush (VoxelInteraction handles it) — never
			# zoom while Ctrl is held, so the two gestures don't both fire on the same wheel event.
			if mb.ctrl_pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
				return
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				stop_tracking()
				if _fly:
					_fly_dolly(1.0)
				else:
					_zoom(1.0 / ZOOM_STEP)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				stop_tracking()
				if _fly:
					_fly_dolly(-1.0)
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
				_fly_look_drag(mm.relative)
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
					_fly_look_drag(mm.relative)
				else:
					_orbit_drag(mm.relative)
					_update_transform()
				return
		if _panning:
			# Drag the land under the cursor: moving the mouse right slides the world right,
			# so the focus moves opposite. Scale by distance for a consistent feel.
			var scale: float = DRAG_PAN_SPEED * _distance_pan_factor()
			_pan_ground(-mm.relative.x * scale, mm.relative.y * scale)
			_update_transform()
		elif _orbiting:
			if _fly:
				_fly_look_drag(mm.relative)
			else:
				_orbit_drag(mm.relative)
				_update_transform()


## Dolly the drone forward (+1) / back (-1) along its look direction — the fly-mode use of the scroll wheel.
func _fly_dolly(dir: float) -> void:
	_fly_pos += _fly_look * dir * _orbit_radius * 0.06
	_update_fly_transform()


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


## Capture the mouse only while actively dragging (pan or orbit) so a drag isn't limited by
## the window edge; otherwise keep the cursor visible for selection, placement, and edge-scroll.
func _update_mouse_capture() -> void:
	if _panning or _orbiting:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _zoom(factor: float) -> void:
	# Set the TARGET distance; _process eases _distance toward it (smooth glide), so both the zoom and the
	# arc-down eye-level blend that reads _distance are continuous instead of snapping per wheel notch.
	if _orbit_mode:
		# Re-read the progression-capped ceiling each zoom so a freshly-earned stage lets the player pull out further.
		_orbit_max_distance = _effective_orbit_max()
		_target_distance = clampf(_target_distance * factor, _orbit_min_distance, _orbit_max_distance)
	else:
		_target_distance = clampf(_target_distance * factor, MIN_DISTANCE, MAX_DISTANCE)


func _terrain_aware_radius(radial: Vector3) -> float:
	var r: float = _orbit_radius
	if _geosync_body != null and is_instance_valid(_geosync_body) and _geosync_body.has_method("surface_radius"):
		var tr: float = _geosync_body.surface_radius(radial)
		if not is_nan(tr) and tr > 0.0:
			r = maxf(r, tr)
	# Ease toward the queried radius (framerate-independent exponential) so a ridge sweeping under the camera is
	# a smooth rise, not a snap. Seed on the first valid frame so we don't ramp up from zero.
	if _smooth_surface_r <= 0.0:
		_smooth_surface_r = r
	else:
		var dt: float = get_process_delta_time()
		var k: float = 1.0 - exp(-dt / maxf(TERRAIN_FOLLOW_TIME, 0.0001))
		_smooth_surface_r = lerpf(_smooth_surface_r, r, k)
	return _smooth_surface_r


## Critically-damped spring toward `target` over ~ZOOM_SMOOTH_TIME seconds (the standard SmoothDamp): smooth
## acceleration AND deceleration, framerate-independent, no overshoot. Threads the spring velocity through _zoom_vel.
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
##   `right`   moves along the camera's ground-right axis,
##   `forward` moves along the camera's ground-forward axis (away from the camera).
func _pan_ground(right: float, forward: float) -> void:
	var fwd: Vector3 = Vector3(sin(_yaw), 0.0, cos(_yaw))
	var rgt: Vector3 = Vector3(cos(_yaw), 0.0, -sin(_yaw))
	# Camera looks toward -forward (down its -Z), so "up on screen" pans the focus forward.
	_focus += rgt * right - fwd * forward
	_clamp_focus()


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
	# Edge-scroll: cursor pushed to a screen border pans the same way (only with a visible cursor, so a captured
	# mouse-look drag never edge-scrolls).
	var vp: Viewport = get_viewport()
	if vp != null and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
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
	# Undo last frame's shake so the seismic offset never accumulates into the base position.
	global_position -= _shake_applied
	_shake_applied = Vector3.ZERO
	# SUNNYSIDE: one-shot orient over the lit hemisphere once the sun light is placed (basis.z = toward the sun,
	# matching the sky shader's sun_dir). Waits for a non-degenerate transform, then never runs again.
	if _sunnyside_pending and _orbit_mode:
		if _sun_light != null and is_instance_valid(_sun_light):
			var to_sun: Vector3 = _sun_light.global_transform.basis.z
			if to_sun.length() > 0.001:
				orient_toward(to_sun)
				_sunnyside_pending = false
		else:
			_sunnyside_pending = false
	# GROUND-WALK: WASD/arrows + edge-scroll sweep the surface view while zoomed in. Updates the orbit/geosync
	# state the transform rebuild below reads; inert when zoomed out, flying, or in the solar overview.
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
	# GEOSYNC: rebuild the transform every frame so the camera rides the planet's spin and the locked region
	# stays centred. (Suppressed in the solar overview, which holds a manual pose.)
	elif _geosync and not _solar_view and _geosync_body != null and is_instance_valid(_geosync_body):
		_update_orbit_transform()
	_apply_seismic_shake(delta)
	var budget: float = _far_budget()
	far = clampf(far, budget * 0.5, budget)


const DRAW_BUDGET_MIN: float = 4000.0
const DRAW_BUDGET_MAX: float = 80000.0

func _far_budget() -> float:
	var b: float = float(Engine.get_meta("la_draw_distance", 8000.0)) if Engine.has_meta("la_draw_distance") else 8000.0
	return clampf(b, DRAW_BUDGET_MIN, DRAW_BUDGET_MAX)


func _apply_seismic_shake(delta: float) -> void:
	if _ecology != null and _ecology.has_method("seismic_energy_at"):
		var seismic: float = _ecology.seismic_energy_at(global_position)
		if seismic > 0.0:
			add_shake(seismic * SEISMIC_TRAUMA_GAIN * delta)

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

	# project_ray_* need the camera to be inside a viewport; guard for headless
	# instantiation outside a tree by falling back to the camera transform.
	if not is_inside_tree():
		return {
			"origin": global_position,
			"dir": -global_transform.basis.z,
		}

	return {
		"origin": project_ray_origin(sp),
		"dir": project_ray_normal(sp),
	}
