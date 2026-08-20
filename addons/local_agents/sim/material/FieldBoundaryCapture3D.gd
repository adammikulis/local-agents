class_name LAFieldBoundaryCapture3D
extends RefCounted

## Records a GLOBAL run's drain-derived state just outside a named slice box's six faces, and replays a
## recorded series into a slice's REPLAY faces. Every value in the file comes from a real run's drain.

const ENV_CAPTURE: String = "LA_SLICE_CAPTURE"
const CAPTURE_SETTING: String = "local_agents/sim/slice_capture"
## The box a GLOBAL run samples for — named apart from LA_SLICE_BOX so the recording run stays global.
const ENV_CAPTURE_BOX: String = "LA_SLICE_CAPTURE_BOX"
const CAPTURE_BOX_SETTING: String = "local_agents/sim/slice_capture_box"
## Field steps between samples.
const CAPTURE_EVERY: int = 10
const VERSION: int = 1

enum { RECORD, REPLAY }

var _f = null
var _mode: int = RECORD
var _path: String = ""
var _names: PackedStringArray = PackedStringArray()
var _amount_names: PackedStringArray = PackedStringArray()
var _face_cells: Array = []
var _samples: Array = []
var _requested: bool = false
var _starved: bool = false
var _fed_idx: int = 0
var _exhausted: bool = false


## RECORD in a global run naming a capture path and a slice box; REPLAY in a slice run carrying a series.
static func maybe_make(field):
	var cap: LAFieldBoundaryCapture3D = LAFieldBoundaryCapture3D.new()
	if field._slice != null:
		if field._slice.replay_series.is_empty():
			return null
		cap._f = field
		cap._mode = REPLAY
		return cap
	var path: String = cap._capture_path()
	if path == "":
		return null
	var box_spec: String = cap._capture_box_spec()
	var box: LAFieldSlice3D = LAFieldSlice3D.parse(box_spec) if box_spec != "" else null
	if box == null or box.error != "":
		push_error("LAFieldBoundaryCapture3D: %s names \"%s\" and no slice box is configured (%s); the capture has no faces to sample."
			% [ENV_CAPTURE, path, ENV_CAPTURE_BOX])
		return null
	cap._f = field
	cap._mode = RECORD
	cap._path = path
	cap._amount_names = _matter_channels()
	cap._names = PackedStringArray(["temp", "pressure", "vel_x", "vel_y", "vel_z"])
	cap._names.append_array(cap._amount_names)
	cap._face_cells = cap._exterior_face_cells(box)
	return cap


func _capture_path() -> String:
	if ProjectSettings.has_setting(CAPTURE_SETTING):
		return String(ProjectSettings.get_setting(CAPTURE_SETTING))
	if OS.has_environment(ENV_CAPTURE):
		return OS.get_environment(ENV_CAPTURE)
	return ""


func _capture_box_spec() -> String:
	if ProjectSettings.has_setting(CAPTURE_BOX_SETTING):
		return String(ProjectSettings.get_setting(CAPTURE_BOX_SETTING))
	if OS.has_environment(ENV_CAPTURE_BOX):
		return OS.get_environment(ENV_CAPTURE_BOX)
	return ""


static func _matter_channels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var rows: Dictionary = LAChannels.rows()
	for name in rows:
		if String(rows[name].get("unit", "")) == "mol_m3":
			out.append(String(name))
	return out


## The GLOBAL cells one layer outside each box face: the exterior the slice's ghost tails stand for.
func _exterior_face_cells(box: LAFieldSlice3D) -> Array:
	var grid: LAVoxelGrid = _f._grid
	var centre: Vector3 = _f.centre() + box.offset
	var half: Vector3 = 0.5 * Vector3(box.dims) * box.cell_size
	var lo: Vector3 = centre - half
	var out: Array = []
	for d in LAVoxelGrid.SLOTS:
		var axis: int = d >> 1
		var u_axis: int = (axis + 1) % 3
		var v_axis: int = (axis + 2) % 3
		var seen: Dictionary = {}
		var cells: PackedInt32Array = PackedInt32Array()
		var p: Vector3 = Vector3.ZERO
		p[axis] = (lo[axis] - 0.5 * box.cell_size) if (d & 1) == 0 \
			else (lo[axis] + 2.0 * half[axis] + 0.5 * box.cell_size)
		var nu: int = box.dims[u_axis]
		var nv: int = box.dims[v_axis]
		for u in nu:
			for v in nv:
				p[u_axis] = lo[u_axis] + (float(u) + 0.5) * box.cell_size
				p[v_axis] = lo[v_axis] + (float(v) + 0.5) * box.cell_size
				var c: int = grid.cell_at(p)
				if c >= 0 and not seen.has(c):
					seen[c] = true
					cells.append(c)
		if cells.is_empty():
			push_error("LAFieldBoundaryCapture3D: face %d of the slice box lies outside the global grid; nothing to sample." % d)
		out.append(cells)
	return out


## Called once per field step, after the previous step drained and before this step dispatches.
func pre_step() -> void:
	if _mode == REPLAY:
		_replay_tick()
		return
	var step: int = int(_f._gpu._step_index)
	if _requested:
		_requested = false
		var legs: Dictionary = _f._gpu.take_probe(_names)
		_fold(step, legs)
	if step % CAPTURE_EVERY == 0:
		_f._gpu.request_probe(_names)
		_requested = true


func _fold(step: int, legs: Dictionary) -> void:
	var cc: int = _f._cell_count
	for name in _names:
		var arr = legs.get(name)
		if not (arr is PackedFloat32Array) or arr.size() < cc:
			if not _starved:
				_starved = true
				push_warning("LAFieldBoundaryCapture3D: probe leg \"%s\" is absent; the sample is dropped, not invented." % String(name))
			return
	var faces: Dictionary = {}
	for d in LAVoxelGrid.SLOTS:
		var cells: PackedInt32Array = _face_cells[d]
		if cells.is_empty():
			continue
		var st: Dictionary = _face_state(cells, legs)
		if not _raw_ok(st):
			push_warning("LAFieldBoundaryCapture3D: face %d read a non-finite state at step %d; the sample is dropped, not invented." % [d, step])
			return
		faces[str(d)] = st
	_samples.append({"step": step, "faces": faces})
	_write()


func _face_state(cells: PackedInt32Array, legs: Dictionary) -> Dictionary:
	var n: float = float(cells.size())
	var t: float = 0.0
	var p: float = 0.0
	var vel: Vector3 = Vector3.ZERO
	var grav: Vector3 = Vector3.ZERO
	var temp: PackedFloat32Array = legs["temp"]
	var pres: PackedFloat32Array = legs["pressure"]
	var vx: PackedFloat32Array = legs["vel_x"]
	var vy: PackedFloat32Array = legs["vel_y"]
	var vz: PackedFloat32Array = legs["vel_z"]
	for c in cells:
		t += temp[c]
		p += pres[c]
		vel += Vector3(vx[c], vy[c], vz[c])
		grav += _f._gravity.g_vec_at(c)
	var amounts: Dictionary = {}
	for name in _amount_names:
		var arr: PackedFloat32Array = legs[name]
		var s: float = 0.0
		for c in cells:
			s += arr[c]
		amounts[String(name)] = s / n
	return {"temp_c": t / n, "pressure_pa": p / n,
		"velocity": _vec(vel / n), "gravity": _vec(grav / n), "amounts": amounts}


func _write() -> void:
	var fh: FileAccess = FileAccess.open(_path, FileAccess.WRITE)
	if fh == null:
		if not _starved:
			_starved = true
			push_error("LAFieldBoundaryCapture3D: cannot write \"%s\" (%s)." % [_path, error_string(FileAccess.get_open_error())])
		return
	fh.store_string(JSON.stringify({"version": VERSION, "cadence": CAPTURE_EVERY,
		"cell_size": _f._grid.cell_size, "samples": _samples}))
	fh.close()


static func _vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


# --- REPLAY: feed the recorded series through the boundary, one sample per recorded cadence ---------------

func _replay_tick() -> void:
	if _exhausted or _f._boundary == null:
		return
	var series: Dictionary = _f._slice.replay_series
	var cadence: int = maxi(int(_f._slice.replay_cadence), 1)
	var idx: int = int(_f._gpu._step_index) / cadence
	if idx == _fed_idx:
		return
	for d in series:
		var arr: Array = series[d]
		if idx >= arr.size():
			_exhausted = true
			push_error("LAFieldBoundaryCapture3D: the capture series ends at sample %d and the run asked for %d; the exterior is unknown past the recording." % [arr.size() - 1, idx])
			return
		_f._boundary.replay(int(d), arr[idx])
	_fed_idx = idx


# --- FILE -> STATES --------------------------------------------------------------------------------------

static func load_file(path: String) -> Dictionary:
	var fh: FileAccess = FileAccess.open(path, FileAccess.READ)
	if fh == null:
		return {}
	var parsed: Variant = JSON.parse_string(fh.get_as_text())
	fh.close()
	if not (parsed is Dictionary) or (parsed.get("samples", []) as Array).is_empty():
		return {}
	return parsed


## Face slot -> the time-mean state over every sample: the CONSTANT boundary's supplied exterior.
static func constant_states(data: Dictionary) -> Dictionary:
	var samples: Array = data.get("samples", [])
	var acc: Dictionary = {}
	var counts: Dictionary = {}
	for s in samples:
		var faces: Dictionary = s.get("faces", {})
		if not _sample_ok(faces):
			push_warning("LAFieldBoundaryCapture3D: a stored sample carries a non-finite reading; skipped.")
			continue
		for key in faces:
			var d: int = int(String(key))
			var st: Dictionary = _state_of(faces[key])
			if not acc.has(d):
				acc[d] = st
				counts[d] = 1
				continue
			var a: Dictionary = acc[d]
			a["temp_c"] = float(a["temp_c"]) + float(st["temp_c"])
			a["pressure_pa"] = float(a["pressure_pa"]) + float(st["pressure_pa"])
			a["velocity"] = Vector3(a["velocity"]) + Vector3(st["velocity"])
			a["gravity"] = Vector3(a["gravity"]) + Vector3(st["gravity"])
			var am: Dictionary = a["amounts"]
			for name in st["amounts"]:
				am[name] = float(am.get(name, 0.0)) + float(st["amounts"][name])
			counts[d] = int(counts[d]) + 1
	for d in acc:
		var n: float = float(counts[d])
		var a: Dictionary = acc[d]
		a["temp_c"] = float(a["temp_c"]) / n
		a["pressure_pa"] = float(a["pressure_pa"]) / n
		a["velocity"] = Vector3(a["velocity"]) / n
		a["gravity"] = Vector3(a["gravity"]) / n
		for name in a["amounts"]:
			a["amounts"][name] = float(a["amounts"][name]) / n
	return acc


## Face slot -> the per-sample series, plus the cadence in field steps: the REPLAY boundary's feed.
## A series with a gap cannot drive a boundary, so one bad sample refuses the whole file.
static func series_states(data: Dictionary) -> Dictionary:
	var faces: Dictionary = {}
	for s in data.get("samples", []):
		var sf: Dictionary = s.get("faces", {})
		if not _sample_ok(sf):
			push_error("LAFieldBoundaryCapture3D: the series carries a non-finite sample; a gapped series cannot drive a REPLAY face.")
			return {}
		for key in sf:
			var d: int = int(String(key))
			if not faces.has(d):
				faces[d] = []
			(faces[d] as Array).append(_state_of(sf[key]))
	return {"cadence": int(data.get("cadence", 0)), "faces": faces}


## One stored face state, JSON arrays rebuilt into the vectors the provider consumes.
static func _state_of(raw: Dictionary) -> Dictionary:
	var out: Dictionary = raw.duplicate(true)
	out["velocity"] = _to_vec(raw.get("velocity"))
	out["gravity"] = _to_vec(raw.get("gravity"))
	return out


static func _to_vec(v) -> Vector3:
	if v is Array and (v as Array).size() == 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO


static func _sample_ok(faces: Dictionary) -> bool:
	for key in faces:
		if not (faces[key] is Dictionary) or not _raw_ok(faces[key]):
			return false
	return true


## A recorded reading is a measurement only when every number in it is a finite number. The momentum
## runaway writes non-finite velocities, which JSON stores as null.
static func _raw_ok(raw: Dictionary) -> bool:
	if not _num_ok(raw.get("temp_c")) or not _num_ok(raw.get("pressure_pa")):
		return false
	for vk in ["velocity", "gravity"]:
		var v = raw.get(vk)
		if v is Vector3:
			if not (v as Vector3).is_finite():
				return false
			continue
		if not (v is Array) or (v as Array).size() != 3:
			return false
		for e in v:
			if not _num_ok(e):
				return false
	var amounts = raw.get("amounts")
	if not (amounts is Dictionary):
		return false
	for name in amounts:
		if not _num_ok(amounts[name]):
			return false
	return true


static func _num_ok(v) -> bool:
	return (v is float and is_finite(v)) or v is int
