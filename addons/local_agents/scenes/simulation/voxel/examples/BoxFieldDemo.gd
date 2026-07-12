extends Node3D

## Library demo — a volumetric MaterialField in BOX mode (setup_dims), with NO planet and NO GPU kernels.
## It injects heat at the floor of the box for a short burst, then the CPU box-step (LAMaterialFieldBoxStep3D)
## diffuses + BUOYS it upward, so a warm plume rises and spreads. A vertical slice of cubes is tinted by the
## live temperature each frame so the flow is visible; a headless run prints before/after stats proving the
## field is non-static. (Explicit types only — project rule: no ':=' inferred typing.)

const MaterialFieldScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialField3D.gd")

@export var extent: Vector3 = Vector3(60.0, 40.0, 60.0)
@export var cell_size: float = 5.0
## Heat injected per frame at the floor centre during the initial burst (°C per frame per source cell).
@export var heat_per_frame: float = 40.0
## How many frames the floor heat source runs before switching off (then we watch it flow + settle).
@export var heat_burst_frames: int = 40

var _field = null
var _dx: int = 0
var _dy: int = 0
var _dz: int = 0
var _origin: Vector3 = Vector3.ZERO
var _slice_cubes: Array = []          # {mi, ix, iy} for the z-mid vertical slice
var _slice_mats: Array = []
var _run_frames: int = 0
var _frame: int = 0
var _top_start: float = 0.0


func _ready() -> void:
	_parse_run_frames()
	_build_camera_and_light()
	_build_field()
	_build_slice_visual()
	_top_start = _sample_top_center()


func _build_camera_and_light() -> void:
	var light: DirectionalLight3D = DirectionalLight3D.new()
	light.rotation = Vector3(-0.9, 0.5, 0.0)
	add_child(light)
	var cam: Camera3D = Camera3D.new()
	cam.position = Vector3(0.0, 24.0, 70.0)
	cam.rotation = Vector3(-0.25, 0.0, 0.0)
	cam.current = true
	add_child(cam)


func _build_field() -> void:
	_field = MaterialFieldScript.new()
	_field.name = "BoxField"
	add_child(_field)
	_dx = maxi(1, int(round(extent.x / cell_size)))
	_dy = maxi(1, int(round(extent.y / cell_size)))
	_dz = maxi(1, int(round(extent.z / cell_size)))
	_origin = Vector3(-0.5 * extent.x, 0.0, -0.5 * extent.z)
	_field.setup_dims(_dx, _dy, _dz, cell_size, _origin)


# A vertical slice of cubes (z at the box centre) whose colour tracks temperature — the visible field.
func _build_slice_visual() -> void:
	var zc: int = _dz / 2
	for iy in range(_dy):
		for ix in range(_dx):
			var mi: MeshInstance3D = MeshInstance3D.new()
			var box: BoxMesh = BoxMesh.new()
			box.size = Vector3(cell_size * 0.85, cell_size * 0.85, cell_size * 0.85)
			mi.mesh = box
			var mat: StandardMaterial3D = StandardMaterial3D.new()
			mat.emission_enabled = true
			mi.material_override = mat
			mi.position = _cell_center(ix, iy, zc)
			add_child(mi)
			_slice_cubes.append({"mi": mi, "ix": ix, "iy": iy})
			_slice_mats.append(mat)


func _cell_center(ix: int, iy: int, iz: int) -> Vector3:
	return _origin + Vector3((float(ix) + 0.5) * cell_size, (float(iy) + 0.5) * cell_size, (float(iz) + 0.5) * cell_size)


func _process(_delta: float) -> void:
	_frame += 1
	# Inject a floor-centred heat source for the opening burst, then switch it off and watch it flow.
	if _frame <= heat_burst_frames:
		var cx: int = _dx / 2
		var cz: int = _dz / 2
		for ox in range(-1, 2):
			for oz in range(-1, 2):
				_field.add_heat(_cell_center(clampi(cx + ox, 0, _dx - 1), 0, clampi(cz + oz, 0, _dz - 1)), heat_per_frame)
	_update_slice_colours()
	if _run_frames > 0 and _frame == _run_frames:
		_emit_report_and_quit()


func _update_slice_colours() -> void:
	var ambient: float = _field.INITIAL_TEMP
	for i in range(_slice_cubes.size()):
		var entry: Dictionary = _slice_cubes[i]
		var t: float = _field.temp_at(_cell_center(int(entry["ix"]), int(entry["iy"]), _dz / 2))
		var f: float = clampf((t - ambient) / 60.0, 0.0, 1.0)          # 0 = ambient, 1 = +60°C
		var col: Color = Color(0.15, 0.2, 0.5).lerp(Color(1.0, 0.35, 0.1), f)
		var mat: StandardMaterial3D = _slice_mats[i]
		mat.albedo_color = col
		mat.emission = col * f


func _sample_top_center() -> float:
	return _field.temp_at(_cell_center(_dx / 2, _dy - 1, _dz / 2))


func _sample_bottom_center() -> float:
	return _field.temp_at(_cell_center(_dx / 2, 0, _dz / 2))


func _emit_report_and_quit() -> void:
	var top_now: float = _sample_top_center()
	var bottom_now: float = _sample_bottom_center()
	var rose: bool = top_now > _top_start + 0.5      # heat reached the top ⇒ the field flowed (non-static)
	print("BOX_FIELD_REPORT={\"frames\":%d,\"cells\":%d,\"top_start\":%.2f,\"top_now\":%.2f,\"bottom_now\":%.2f,\"flowed\":%s}"
		% [_frame, _dx * _dy * _dz, _top_start, top_now, bottom_now, str(rose)])
	LAAppExit.request(self, 0)


func _parse_run_frames() -> void:
	for arg in OS.get_cmdline_user_args():
		if String(arg).begins_with("--run-frames="):
			_run_frames = maxi(0, int(String(arg).get_slice("=", 1)))
