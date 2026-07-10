@tool
class_name LAVoxelCameraRig
extends Camera3D

## RTS-style orbit camera for the voxel simulation (Black & White feel).
##
##   - Middle-mouse drag to rotate the view (orbit): horizontal = heading/yaw, vertical =
##     tilt/pitch. WASD / arrow keys pan; push the cursor to a screen edge to edge-scroll.
##   - Mouse wheel zooms in / out.
##   - Shift + middle-mouse drag grabs & pans the terrain; Q / E rotate
##     yaw and R / F tilt pitch from the keyboard. (LMB = select/grab and RMB = spawn/cast
##     are handled by VoxelWorld, so the camera leaves both those buttons free.)
##   - The cursor stays visible (only captured while actively dragging) so HUD clicks,
##     selection, and placement keep working.
##
## The rig is defined by a ground focus point plus a spherical offset (distance/yaw/pitch);
## panning moves the focus, zoom changes the distance, orbit changes yaw/pitch. The camera
## transform is rebuilt from that state every time it changes (_update_transform()).
##
## Hosts the VoxelViewer in the integration scene (VoxelWorld calls
## terrain.attach_viewer(camera)). Exposes aim_ray() for click-to-place / select and
## focus_on()/frame_vista() so the world can recenter the view without fighting the rebuild.

# --- Tunables -----------------------------------------------------------------
const MIN_DISTANCE: float = 0.5           # closest zoom (units from focus) — right down onto an animal
const MAX_DISTANCE: float = 1400.0        # farthest zoom — pull way out for a whole-world view
const ZOOM_STEP: float = 1.12             # wheel multiplier per notch (bigger = faster zoom) — gentle, slow zoom
# LMB/RMB "grab the planet" drag-orbit only engages once the cursor has moved past this many pixels, so a
# plain click still selects / casts (near-zero drag) while a real drag rotates the view. No mouse capture on
# these buttons (they double as click actions) — we read relative motion with the cursor left visible.
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

# --- Orbit (planet) mode tunables --------------------------------------------
# Parallel mode used when the world is a spherical planet: the rig sits on a sphere around the
# planet centre (spherical coords: azimuth + elevation), looks at the centre, and scroll zooms the
# orbit radius. Enabled by set_orbit_target(); the flat fly path below is left untouched.
const ORBIT_DEFAULT_DISTANCE_MULT: float = 2.4   # start distance = planet_radius * this
const ORBIT_MIN_DISTANCE_MULT: float = 1.05      # closest zoom — just above the surface
const ORBIT_MAX_DISTANCE_MULT: float = 6.0       # farthest zoom — a few planet radii out
# Clamp elevation shy of the poles so "up" stays world-up without a gimbal flip through the pole.
const ORBIT_ELEVATION_LIMIT: float = deg_to_rad(85.0)

# Reference distance the pan speeds are tuned against; panning scales with distance so the
# world moves a consistent fraction of the screen at every zoom level.
const PAN_REFERENCE_DISTANCE: float = 100.0

# --- State --------------------------------------------------------------------
var _focus: Vector3 = Vector3.ZERO
var _distance: float = 140.0
var _yaw: float = 0.0
var _pitch: float = deg_to_rad(55.0)
var _panning: bool = false
var _orbiting: bool = false
# LMB/RMB "hold to rotate the planet" drag-orbit. Armed on press, becomes active once the drag passes
# DRAG_ORBIT_THRESHOLD so a click still falls through to select/cast. Released → stops (as the player expects).
var _drag_orbiting: bool = false
var _drag_orbit_armed: bool = false
var _drag_orbit_travel: float = 0.0

# --- Orbit (planet) mode state ------------------------------------------------
# When _orbit_mode is true the rig ignores _focus/_yaw/_pitch and instead sits on a sphere of radius
# `_distance` around `_orbit_center` (the planet centre), oriented by azimuth/elevation, looking in.
# The flat fly state above is preserved untouched so toggling back is lossless.
var _orbit_mode: bool = false
var _orbit_center: Vector3 = Vector3.ZERO
var _orbit_radius: float = 0.0            # planet radius (for zoom clamps)
var _orbit_azimuth: float = 0.0           # rotation around the polar axis, radians
var _orbit_elevation: float = deg_to_rad(20.0)  # latitude of the camera, radians (clamped off the poles)
var _orbit_min_distance: float = 0.0
var _orbit_max_distance: float = 0.0

# --- Rotation mode: FREE (camera fixed in the world frame, planet spins under it) vs GEOSYNC (camera rides
# the planet's rotating frame, locked over one surface region so it stays centred as the planet spins).
# In geosync the source-of-truth is a body-LOCAL direction; each frame the world radial = body_basis * that,
# so the same spot faces the camera. VoxelWorld's `_body` is wired in via set_geosync_body().
var _geosync: bool = false
var _geosync_body: Node3D = null
var _geosync_local_dir: Vector3 = Vector3.UP
# --- Solar-system overview: a pulled-back framing that shows the planet + the (visible) sun together. It
# uses a MANUAL transform, so the per-frame geosync ride is suppressed while it is active.
var _solar_view: bool = false

# --- FLY / DRONE free-flight: a planet-aware first-person cam. WASD moves relative to the look direction,
# hold-drag mouse-looks to aim, Space/E lift + Ctrl/Q descend along the local RADIAL (away-from/toward the
# core), Shift boosts. "Up" is the radial (normalize(pos - centre)) so it feels right over the curved surface:
# skim low over the terrain or pull up into the atmosphere. Driftless — the look dir is stored, not integrated.
const FLY_SPEED_FRAC: float = 0.30    # base move speed as a fraction of the planet radius, per second
const FLY_BOOST: float = 4.0          # Shift multiplier
const FLY_LOOK_SENS: float = 0.005    # radians per pixel for the hold-drag mouse-look
const FLY_PITCH_LIMIT_DOT: float = 0.96   # keep the look off the local up/down poles so the up-vector stays stable
var _fly: bool = false
var _fly_pos: Vector3 = Vector3.ZERO
var _fly_look: Vector3 = Vector3.FORWARD  # world-space unit forward (aim)

# --- Storm tracking -----------------------------------------------------------
# Follow a live, moving Node3D (a wandering storm) so it stays framed. Each frame the focus eases
# toward the target's world position; an optional framing distance/pitch eases in too so a big storm
# is pulled back to fit. Any manual pan/orbit/zoom cancels the follow so the player keeps control.
const TRACK_LERP: float = 3.0             # focus/zoom ease rate toward the target, per second
const TRACK_FOCUS_LIFT: float = 8.0       # keep the focus a touch above the ground foot of the storm
var _track_target: Node3D = null
var _track_distance: float = -1.0         # <0 = keep the current zoom (per the default contract)
var _track_pitch: float = -1.0            # <0 = keep the current pitch

# Pan bound: the focus point is clamped to a square of this half-extent (world XZ) so the player can
# roam the island and its surrounding ocean ring but never pan off past the horizon into empty void.
# 0 = unbounded (until VoxelWorld sets it once the world size is known).
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
# How strongly felt seismic energy (from the ecology's seismic field) converts to trauma per second.
# The shake now EMERGES from ground motion: any disturbance emits a seismic pulse, the rig queries the
# energy at its own position each frame and feeds it here — no event tells the camera to shake.
const SEISMIC_TRAUMA_GAIN: float = 2.0
var _trauma: float = 0.0
var _shake_applied: Vector3 = Vector3.ZERO
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
	# Fallback framing used until VoxelWorld calls frame_vista() with the real surface height:
	# a 3/4 downward vista, pulled back so we open on a landscape rather than inside a hill.
	_focus = Vector3(0.0, 20.0, 0.0)
	_distance = 140.0
	_yaw = 0.0
	_pitch = deg_to_rad(55.0)
	_update_transform()


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
		_update_transform()
		return
	_focus = center + Vector3(0.0, 10.0, 0.0)
	_distance = clampf(dist, MIN_DISTANCE, MAX_DISTANCE)
	_yaw = deg_to_rad(35.0)
	_pitch = deg_to_rad(48.0)
	_clamp_focus()
	_update_transform()


## Follow a live, moving target (a wandering storm) so it stays framed. Each frame the focus eases
## toward `target`'s world position. `distance` / `pitch_deg` (when > 0) also ease in so a large storm
## is pulled back to fit; pass negatives to keep the current zoom/pitch. Manual input cancels the follow.
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


## Switch the rig into orbit (planet) mode around `center` at radius `radius`. Starts at a
## whole-planet framing distance (radius * ORBIT_DEFAULT_DISTANCE_MULT) and clamps zoom from just
## above the surface out to a few planet radii. Called by VoxelWorld once the planet is known.
## The flat fly state is left intact, so this is a mode switch, not a teardown.
func set_orbit_target(center: Vector3, radius: float) -> void:
	_orbit_mode = true
	_orbit_center = center
	_orbit_radius = maxf(1.0, radius)
	_orbit_min_distance = _orbit_radius * ORBIT_MIN_DISTANCE_MULT
	_orbit_max_distance = _effective_orbit_max()
	_distance = clampf(_orbit_radius * ORBIT_DEFAULT_DISTANCE_MULT, _orbit_min_distance, _orbit_max_distance)
	_orbit_azimuth = 0.0
	_orbit_elevation = deg_to_rad(20.0)
	stop_tracking()          # storm-follow is a flat-world concept; drop it on entering orbit
	_update_transform()


## The orbit max-distance ceiling in world units, capped by the campaign progression: the player starts
## constrained near the surface and each earned stage raises the ceiling (sandbox / no progression = the full
## ORBIT_MAX_DISTANCE_MULT). Recomputed on every zoom so a live unlock takes effect immediately.
func _effective_orbit_max() -> float:
	var cap_mult: float = minf(ORBIT_MAX_DISTANCE_MULT, LAGameProgression.zoom_ceiling_mult())
	return _orbit_radius * maxf(ORBIT_MIN_DISTANCE_MULT, cap_mult)


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


## Rebuild the transform for orbit (planet) mode: place the camera on a sphere of radius `_distance`
## around `_orbit_center` and look straight in. FREE mode uses azimuth/elevation (a world-fixed pose the
## spinning planet turns under); GEOSYNC derives the radial from a body-LOCAL direction so the camera rides
## the planet's spin and one region stays centred. Up flips to RIGHT near the poles so world-up never gimbals.
func _update_orbit_transform() -> void:
	var radial: Vector3
	if _geosync and _geosync_body != null and is_instance_valid(_geosync_body):
		radial = (_geosync_body.global_transform.basis * _geosync_local_dir).normalized()
	else:
		_orbit_elevation = clampf(_orbit_elevation, -ORBIT_ELEVATION_LIMIT, ORBIT_ELEVATION_LIMIT)
		radial = _radial_from_azel()
	global_position = _orbit_center + radial * _distance
	var up: Vector3 = Vector3.UP if absf(radial.dot(Vector3.UP)) < 0.985 else Vector3.RIGHT
	look_at(_orbit_center, up)
	# Far plane scaled to the orbit distance so the whole planet stays inside the frustum when pulled out.
	far = clampf(_distance * 4.0, 4000.0, 40000.0)


## Wire the planet body (VoxelWorld's `_body`) so GEOSYNC can read its rotating frame. Passed via the input
## controller's bind() so VoxelWorld stays untouched.
func set_geosync_body(body: Node3D) -> void:
	_geosync_body = body


## Toggle GEOSYNC. Enabling captures the current view direction into the body-local frame (so it locks on the
## spot you're looking at); disabling syncs azimuth/elevation back from the ridden radial so FREE mode resumes
## from the same view with no jump.
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
	_orbit_max_distance = maxf(_orbit_max_distance, orbit_dist * 2.0)
	far = clampf(orbit_dist * 4.0, 4000.0, 80000.0)


## Leave the solar overview and reframe the planet at the default orbit distance.
func set_planet_view() -> void:
	_solar_view = false
	_orbit_max_distance = _effective_orbit_max()
	_distance = clampf(_orbit_radius * ORBIT_DEFAULT_DISTANCE_MULT, _orbit_min_distance, _orbit_max_distance)
	_update_transform()


func is_solar_view() -> bool:
	return _solar_view


## Enter/leave FLY mode. Entering seeds the drone at the current camera pose (position + forward). Leaving
## resumes the orbit rig from wherever the drone ended up (azimuth/elevation/distance derived from the fly
## position) so the view doesn't jump.
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
			# Plain MMB held + drag orbits (horizontal = yaw, vertical = pitch);
			# Shift + MMB pans. RMB is left free for spawn/cast.
			if mb.pressed:
				stop_tracking()          # grabbing the view takes back control from a storm follow
				if Input.is_key_pressed(KEY_SHIFT):
					_set_panning(true)
				else:
					_set_orbiting(true)
			else:
				_set_panning(false)
				_set_orbiting(false)
			return
		# Plain LMB / RMB held: arm a "grab the planet" drag-orbit. It only starts rotating once the
		# cursor moves past DRAG_ORBIT_THRESHOLD, so a click still selects (LMB) / casts (RMB) — those
		# resolve on the same (non-consumed) event over in VoxelWorld's interaction/brush.
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_drag_orbit_armed = true
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


## Apply a mouse-drag to the view (horizontal = sweep around the pole, vertical = latitude). Shared by MMB
## orbit and the LMB/RMB "grab the planet" drag. In FREE mode it moves azimuth/elevation; in GEOSYNC it
## re-aims the locked body-local spot (rotating it in world space, then folding back into the body frame) so
## dragging re-chooses which region stays centred with no jump.
func _orbit_drag(rel: Vector2) -> void:
	if _geosync and _geosync_body != null and is_instance_valid(_geosync_body):
		var cur: Vector3 = (_geosync_body.global_transform.basis * _geosync_local_dir).normalized()
		var right: Vector3 = cur.cross(Vector3.UP)
		right = right.normalized() if right.length() > 0.001 else Vector3.RIGHT
		var moved: Vector3 = cur.rotated(Vector3.UP, -rel.x * ORBIT_SENSITIVITY).rotated(right, -rel.y * ORBIT_SENSITIVITY).normalized()
		_geosync_local_dir = (_geosync_body.global_transform.basis.inverse() * moved).normalized()
		return
	_orbit_azimuth -= rel.x * ORBIT_SENSITIVITY
	_orbit_elevation = clampf(_orbit_elevation - rel.y * ORBIT_SENSITIVITY, -ORBIT_ELEVATION_LIMIT, ORBIT_ELEVATION_LIMIT)


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
	if _orbit_mode:
		# Re-read the progression-capped ceiling each zoom so a freshly-earned stage lets the player pull out further.
		_orbit_max_distance = _effective_orbit_max()
		_distance = clampf(_distance * factor, _orbit_min_distance, _orbit_max_distance)
	else:
		_distance = clampf(_distance * factor, MIN_DISTANCE, MAX_DISTANCE)
	_update_transform()


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


func _process(delta: float) -> void:
	# Don't drive movement in the editor (@tool) preview.
	if Engine.is_editor_hint():
		return
	# Undo last frame's shake so the seismic offset never accumulates into the base position.
	global_position -= _shake_applied
	_shake_applied = Vector3.ZERO
	# FLY: drive the drone from the keyboard every frame (WASD/lift/descend/boost).
	if _fly:
		_fly_step(delta)
	# GEOSYNC: rebuild the transform every frame so the camera rides the planet's spin and the locked region
	# stays centred. (Suppressed in the solar overview, which holds a manual pose.)
	elif _geosync and not _solar_view and _geosync_body != null and is_instance_valid(_geosync_body):
		_update_orbit_transform()
	# Otherwise the planet-orbit rig is driven entirely by input (drag-orbit + scroll zoom); the only per-frame
	# work is the emergent seismic camera shake. (The old flat WASD/edge-scroll/keyboard-fly path was dead
	# once the planet became the sole world — deleted.)
	_apply_seismic_shake(delta)
	# Enforce the player's draw-distance budget on the far plane every frame, whatever view mode set `far`.
	# One central seam (each mode sets a zoom-derived far first; this bounds it) so the knob composes with all
	# modes and picks up a live settings re-apply. The 0.5×budget floor lets far GROW with a high budget too
	# (not just cap), and the budget floor of DRAW_BUDGET_MIN keeps it well past what the small planet needs to
	# stay visible — so no view is ever clipped, the knob only trades cull distance for fill-rate.
	var budget: float = _far_budget()
	far = clampf(far, budget * 0.5, budget)


## The camera far-plane budget in metres — the player's Graphics draw-distance knob (la_draw_distance,
## published by LAVoxelSettingsApplier). Default/missing → 8000. Clamped to DRAW_BUDGET_MIN so it always
## clears the whole planet (radius ~250, farthest orbit ~1500 → ~1750 needed), never clipping the view.
const DRAW_BUDGET_MIN: float = 4000.0
const DRAW_BUDGET_MAX: float = 80000.0

func _far_budget() -> float:
	var b: float = float(Engine.get_meta("la_draw_distance", 8000.0)) if Engine.has_meta("la_draw_distance") else 8000.0
	return clampf(b, DRAW_BUDGET_MIN, DRAW_BUDGET_MAX)


## Emergent camera shake, shared by flat and orbit modes: query the seismic field at the camera's own
## position and top up trauma in proportion to nearby seismic energy (that energy already folds in
## proximity and time decay), then apply the decaying trauma as a transient offset on top of the base
## position. A meteor impact, a volcano breach, an earthquake pulse all shake it just by disturbing the earth.
func _apply_seismic_shake(delta: float) -> void:
	if _ecology != null and _ecology.has_method("seismic_energy_at"):
		var seismic: float = _ecology.seismic_energy_at(global_position)
		if seismic > 0.0:
			add_shake(seismic * SEISMIC_TRAUMA_GAIN * delta)

	_trauma = maxf(0.0, _trauma - TRAUMA_DECAY * delta)
	if _trauma > 0.0:
		var s: float = _trauma * _trauma * SHAKE_MAG
		_shake_applied = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * s
		global_position += _shake_applied


## Returns a world-space ray {"origin": Vector3, "dir": Vector3}.
##   - screen_pos == Vector2(-1, -1): use the viewport center.
##   - otherwise: project the given screen position.
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
