class_name LAFieldSlice3D
extends RefCounted

## A SLICE of the declared body: a box on the planet, seeded from the real terrain, fed at its faces by
## LAFieldBoundary3D. Spec "ox,oy,oz,nx,ny,nz,cell_m,fine_m", the offset in m in the body frame with one
## component allowed to read `surface`. Node meta -> setting -> env.

const CaptureScript: GDScript = preload("res://addons/local_agents/sim/material/FieldBoundaryCapture3D.gd")

const SETTING: String = "local_agents/sim/slice_box"
const ENV_VAR: String = "LA_SLICE_BOX"
const META_BOX: StringName = &"slice_box"
const STATE_SETTING: String = "local_agents/sim/slice_state"
const STATE_ENV: String = "LA_SLICE_STATE"
const REPLAY_ENV: String = "LA_SLICE_REPLAY"
## A REPLAY pair nudges over RIM_CELLS rows inward of each face, so an axis carrying one needs both rims.
## A torus needs only two cells across it, or a cell faces itself on both sides.
const MIN_REPLAY_CELLS: int = 2 * LAFieldBoundary3D.RIM_CELLS
const MIN_WRAP_CELLS: int = 2

var error: String = ""
var offset: Vector3 = Vector3.ZERO
var dims: Vector3i = Vector3i.ZERO
var cell_size: float = 0.0
## Finest cell edge the box refines to, metres: cell_size halved a whole number of times.
var fine_size: float = 0.0
## Offset axis given as `surface`, resolved against the body in apply(); -1 when the spec was all numbers.
var surface_axis: int = -1
## Face slot -> Array of per-sample states, fed through replay(); empty outside replay mode.
var replay_series: Dictionary = {}
## Field steps one replay sample spans.
var replay_cadence: int = 0


## The configured slice, or null when none is configured anywhere.
static func of(node) -> LAFieldSlice3D:
	var spec: String = String(node.get_meta(META_BOX)) if node != null and node.has_meta(META_BOX) \
		else CaptureScript.configured(SETTING, ENV_VAR)
	if spec.strip_edges() == "":
		return null
	return parse(spec)


## A slice box from a bare spec string (the capture arm's box, which must not slice its own run).
static func parse(spec: String) -> LAFieldSlice3D:
	var s: LAFieldSlice3D = LAFieldSlice3D.new()
	s._parse(spec)
	return s


func _parse(spec: String) -> bool:
	var p: Dictionary = LAGridGeometry.parse_slice_spec(spec)
	if p.has("error"):
		return _fail(String(p["error"]))
	offset = p["offset"]
	dims = p["dims"]
	cell_size = float(p["cell_size"])
	fine_size = float(p["fine_size"])
	surface_axis = int(p["surface_axis"])
	return true


## The box-centre offset with `surface` filled in from the body's own radius. ONE declaration: apply() and
## the capture path both read the offset through here, or one of them places the box somewhere else.
func resolved_offset(body) -> Vector3:
	return offset if _resolve_offset(body) else Vector3.ZERO


func _resolve_offset(body) -> bool:
	if surface_axis < 0:
		return true
	if body == null or not body.has_method("radius"):
		return _fail("the box asks for the body's surface and no body was supplied to resolve it")
	var r: float = float(body.radius())
	if not is_finite(r) or r <= 0.0:
		return _fail("the box asks for the body's surface and the body has not measured a radius yet")
	offset[surface_axis] = r
	surface_axis = -1
	return true


## Lay the field over the slice box against the real terrain, and configure its face boundary.
func apply(field, body, terrain) -> bool:
	if error != "":
		return false
	if body == null or not body.has_method("center") or not body.has_method("radius"):
		return _fail("a slice needs a declared body: its centre and radius locate the box and the monopole gravity")
	if terrain == null or not terrain.has_method("is_solid"):
		return _fail("a slice seeds from the real terrain, and none was supplied")
	if not _resolve_offset(body):
		return false
	field._slice = self
	field._pivot = body.center()
	field.set_body(body)
	field._terrain = terrain
	if terrain.has_method("generator_options"):
		field._terrain_opts = terrain.generator_options()
	var centre: Vector3 = Vector3(body.center()) + offset
	var half: Vector3 = 0.5 * Vector3(dims) * cell_size
	# The slice is a region of the one construction path, under the same refinement rule as the body, and
	# it declares its own finest edge instead of taking the planet's scale-height target.
	field.setup_box(centre - half, dims, cell_size, terrain, body.center(), LocalAgentSimWorld.MODELLED_ATMOSPHERE_HEIGHT_M,
		LocalAgentSimWorld.MODELLED_ATMOSPHERE_HEIGHT_M, fine_size, float(body.radius()))
	_configure_boundary(field)
	return error == ""


## A wrapped axis is a torus and a replayed one carries a relaxation rim: they need different widths. An
## axis whose faces are shut or open carries neither, so it may be one cell.
func _rim_fits(modes: PackedStringArray) -> bool:
	for axis in 3:
		var need: int = 0
		for h in 2:
			var m: String = modes[axis * 2 + h]
			need = maxi(need, MIN_REPLAY_CELLS if m == "replay" else (MIN_WRAP_CELLS if m == "wrap" else 0))
		if dims[axis] < need:
			return _fail("axis %d is %d cells and its faces need at least %d" % [axis, dims[axis], need])
	return true


## Sides WRAP; the vertical pair takes the captured exterior, or stays SHUT when no capture is supplied.
func _configure_boundary(field) -> void:
	var d_down: int = LAFieldGeometry.slot_toward(-offset)
	var d_up: int = LAVoxelGrid.opposite_slot(d_down)
	if LAFieldBoundary3D.explicit_spec() != "":
		print("SLICE_BOUNDARY={\"faces\":\"%s\",\"note\":\"explicit\"}" % LAFieldBoundary3D.explicit_spec())
		return
	var modes: PackedStringArray = PackedStringArray()
	modes.resize(LAVoxelGrid.SLOTS)
	# LA_APPROX: periodic_slice_geometry
	modes.fill("wrap")
	var states: Dictionary = {}
	var path: String = CaptureScript.configured(STATE_SETTING, STATE_ENV)
	if path == "":
		modes[d_down] = "shut"
		modes[d_up] = "space"
		print("SLICE_BOUNDARY={\"faces\":\"%s\",\"note\":\"no capture supplied (%s): bottom SHUT, top SPACE\"}"
			% [",".join(modes), STATE_ENV])
	else:
		var data: Dictionary = CaptureScript.load_file(path)
		if data.is_empty():
			_fail("capture file \"%s\" is unreadable, and a face state is supplied, never invented" % path)
			return
		var replay: bool = OS.get_environment(REPLAY_ENV) != ""
		modes[d_down] = "replay" if replay else "constant"
		modes[d_up] = "replay" if replay else "constant"
		if replay:
			var series: Dictionary = CaptureScript.series_states(data)
			replay_cadence = int(series.get("cadence", 0))
			for d in [d_down, d_up]:
				var arr: Array = series.get("faces", {}).get(d, [])
				if arr.is_empty() or replay_cadence <= 0:
					_fail(_absent(path, data, d))
					return
				replay_series[d] = arr
				states[d] = arr[0]
		else:
			var means: Dictionary = CaptureScript.constant_states(data)
			for d in [d_down, d_up]:
				if not means.has(d):
					_fail(_absent(path, data, d))
					return
				states[d] = means[d]
		print("SLICE_BOUNDARY={\"faces\":\"%s\",\"state\":\"%s\"}" % [",".join(modes), path])
	if not _rim_fits(modes):
		return
	field.set_meta(LAFieldBoundary3D.META_FACES, ",".join(modes))
	if not states.is_empty():
		field.set_meta(LAFieldBoundary3D.META_STATES, states)


## A face the capture supplies nothing for is refused by name, never given another face's reading.
func _absent(path: String, data: Dictionary, d: int) -> String:
	return "capture file \"%s\" supplies no exterior for face %d: %s. Record it from a global run whose cells are smaller than the slice box." % [path, d, CaptureScript.unresolved_note(data, d)]


func _fail(msg: String) -> bool:
	error = msg
	push_error("LAFieldSlice3D: " + msg)
	return false
