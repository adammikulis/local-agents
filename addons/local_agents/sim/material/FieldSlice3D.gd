class_name LAFieldSlice3D
extends RefCounted

## A SLICE of the declared body: a small box on the planet, seeded from the real terrain, fed at its faces
## by LAFieldBoundary3D. Spec "ox,oy,oz,nx,ny,nz,cell_m" — box-centre offset (m, body frame), cells per
## axis, cell edge; an offset component may be `surface`. Node meta -> setting -> env.

const CaptureScript: GDScript = preload("res://addons/local_agents/sim/material/FieldBoundaryCapture3D.gd")

const SETTING: String = "local_agents/sim/slice_box"
const ENV_VAR: String = "LA_SLICE_BOX"
const META_BOX: StringName = &"slice_box"
const STATE_SETTING: String = "local_agents/sim/slice_state"
const STATE_ENV: String = "LA_SLICE_STATE"
const REPLAY_ENV: String = "LA_SLICE_REPLAY"
## WRAP sides need a torus at least this wide; REPLAY rims this deep.
const MIN_CELLS: int = 2 * LAFieldBoundary3D.RIM_CELLS

var error: String = ""
var offset: Vector3 = Vector3.ZERO
var dims: Vector3i = Vector3i.ZERO
var cell_size: float = 0.0
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
	var t: PackedStringArray = spec.split(",")
	if t.size() != 7:
		return _fail("spec \"%s\" has %d fields; ox,oy,oz,nx,ny,nz,cell_m is 7" % [spec, t.size()])
	offset = Vector3.ZERO
	for i in 3:
		if t[i].strip_edges().to_lower() == "surface":
			surface_axis = i
		else:
			offset[i] = t[i].to_float()
	dims = Vector3i(t[3].to_int(), t[4].to_int(), t[5].to_int())
	cell_size = t[6].to_float()
	if dims.x < MIN_CELLS or dims.y < MIN_CELLS or dims.z < MIN_CELLS:
		return _fail("the box is %s cells; every axis needs at least %d" % [str(dims), MIN_CELLS])
	if cell_size <= 0.0:
		return _fail("cell_m must be positive, got %f" % cell_size)
	if offset.length() <= 0.0 and surface_axis < 0:
		return _fail("the offset locates the box ON the body; zero puts it at the centre and names no local vertical")
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
	field.setup_dims(dims.x, dims.y, dims.z, cell_size, centre - half)
	_configure_boundary(field)
	return error == ""


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
