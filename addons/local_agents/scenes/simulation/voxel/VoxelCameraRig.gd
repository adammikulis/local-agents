@tool
class_name LAVoxelCameraRig
extends Camera3D

## Free-look fly camera for the voxel simulation.
##
##   - Hold RMB to mouse-look (mouse is only captured while RMB is held, so HUD
##     clicks keep working the rest of the time).
##   - WASD to move on the view plane, Shift = up / faster, Ctrl = down.
##   - Mouse wheel adjusts fly speed.
##   - No Ctrl-to-orbit requirement; this is a plain fly cam.
##
## Hosts the VoxelViewer in the integration scene (VoxelWorld calls
## terrain.attach_viewer(camera)). Exposes aim_ray() for click-to-place / select.

# --- Tunables -----------------------------------------------------------------
const MOUSE_SENSITIVITY: float = 0.0032
const MIN_SPEED: float = 4.0
const MAX_SPEED: float = 400.0
const SPEED_STEP: float = 1.15            # wheel multiplier per notch
const FAST_MULTIPLIER: float = 3.0        # Shift while moving
const PITCH_LIMIT: float = deg_to_rad(89.0)
const RAY_LENGTH: float = 4000.0

# --- State --------------------------------------------------------------------
var _fly_speed: float = 40.0
var _yaw: float = 0.0
var _pitch: float = 0.0
var _looking: bool = false


func _ready() -> void:
	current = true
	# Sensible default: close enough to see creatures and craters, looking down at ~30deg.
	global_position = Vector3(0.0, 34.0, 52.0)
	look_at(Vector3(0.0, 10.0, 0.0), Vector3.UP)
	_sync_angles_from_basis()


func _sync_angles_from_basis() -> void:
	var e: Vector3 = global_transform.basis.get_euler()
	_pitch = clampf(e.x, -PITCH_LIMIT, PITCH_LIMIT)
	_yaw = e.y


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_set_looking(mb.pressed)
			return
		if mb.pressed and _looking:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_fly_speed = clampf(_fly_speed * SPEED_STEP, MIN_SPEED, MAX_SPEED)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_fly_speed = clampf(_fly_speed / SPEED_STEP, MIN_SPEED, MAX_SPEED)

	elif event is InputEventMouseMotion and _looking:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		_yaw -= mm.relative.x * MOUSE_SENSITIVITY
		_pitch = clampf(_pitch - mm.relative.y * MOUSE_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
		_apply_look()


func _set_looking(active: bool) -> void:
	_looking = active
	# Only capture the mouse while actively looking, so HUD stays clickable.
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if active else Input.MOUSE_MODE_VISIBLE
	if active:
		_sync_angles_from_basis()


func _apply_look() -> void:
	var b: Basis = Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	global_transform.basis = b


func _process(delta: float) -> void:
	# Don't drive movement in the editor (@tool) preview.
	if Engine.is_editor_hint():
		return

	var dir: Vector3 = Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		dir -= global_transform.basis.z
	if Input.is_key_pressed(KEY_S):
		dir += global_transform.basis.z
	if Input.is_key_pressed(KEY_A):
		dir -= global_transform.basis.x
	if Input.is_key_pressed(KEY_D):
		dir += global_transform.basis.x
	if Input.is_key_pressed(KEY_SHIFT):
		dir += Vector3.UP
	if Input.is_key_pressed(KEY_CTRL):
		dir += Vector3.DOWN

	if dir.length() > 0.001:
		dir = dir.normalized()
		var speed: float = _fly_speed
		if Input.is_key_pressed(KEY_SHIFT):
			speed *= FAST_MULTIPLIER
		global_position += dir * speed * delta


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


func get_fly_speed() -> float:
	return _fly_speed
