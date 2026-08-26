class_name LAFieldBoundaryCapture3D
extends RefCounted

## Records a GLOBAL run's drain-derived state just outside a named slice box's six faces, and replays a
## recorded series into a slice's REPLAY faces. Every value in the file comes from a real run's drain.

const ENV_CAPTURE: String = "LA_SLICE_CAPTURE"
const CAPTURE_SETTING: String = "local_agents/sim/slice_capture"
const ENV_CAPTURE_BOX: String = "LA_SLICE_CAPTURE_BOX"
const CAPTURE_BOX_SETTING: String = "local_agents/sim/slice_capture_box"
## Field steps between samples.
const CAPTURE_EVERY: int = 10
const VERSION: int = 2

enum { RECORD, REPLAY }

## The fields one recorded face state carries, beside its per-substance `amounts`.
const SCALARS: Array[String] = ["temp_c", "pressure_pa"]
const VECTORS: Array[String] = ["velocity", "gravity"]

var _f = null
var _mode: int = RECORD
var _path: String = ""
var _names: PackedStringArray = PackedStringArray()
var _amount_names: PackedStringArray = PackedStringArray()
## Face slot -> {"cells", "weights"} over the global cells outside it, or {"unresolved": String}.
var _faces: Array = []
var _unresolved: Dictionary = {}
var _samples: Array = []
var _requested: bool = false
var _starved: bool = false
var _fed_idx: int = 0
var _exhausted: bool = false


## RECORD in a global run naming a capture path and box; REPLAY in a slice run carrying a series.
static func maybe_make(field):
	var cap: LAFieldBoundaryCapture3D = LAFieldBoundaryCapture3D.new()
	if field._slice != null:
		if field._slice.replay_series.is_empty():
			return null
		cap._f = field
		cap._mode = REPLAY
		return cap
	var path: String = configured(CAPTURE_SETTING, ENV_CAPTURE)
	if path == "":
		return null
	var box_spec: String = configured(CAPTURE_BOX_SETTING, ENV_CAPTURE_BOX)
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
	cap._faces = exterior_faces(field._grid, field.centre() + box.resolved_offset(field._body), box)
	for d in LAVoxelGrid.SLOTS:
		if (cap._faces[d] as Dictionary).has("unresolved"):
			cap._unresolved[str(d)] = String(cap._faces[d]["unresolved"])
			push_warning("LAFieldBoundaryCapture3D: face %d has no resolved exterior (%s); it is named in the capture, never copied from another face." % [d, cap._unresolved[str(d)]])
	return cap


## Setting first, then environment. An absent configuration is "", never a path we chose.
static func configured(setting: String, env: String) -> String:
	if ProjectSettings.has_setting(setting):
		return String(ProjectSettings.get_setting(setting))
	if OS.has_environment(env):
		return OS.get_environment(env)
	return ""


static func _matter_channels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var rows: Dictionary = LAChannels.rows()
	for name in rows:
		if String(rows[name].get("unit", "")) == "mol_m3":
			out.append(String(name))
	return out


## Each box face's exterior: the global cells beyond it, by the share of the slab each covers.
static func exterior_faces(grid: LAVoxelGrid, centre: Vector3, box: LAFieldSlice3D) -> Array:
	var half: Vector3 = 0.5 * Vector3(box.dims) * box.cell_size
	var span: Vector3 = Vector3(float(grid.nx), float(grid.ny), float(grid.nz)) * grid.cell_size
	var out: Array = []
	for d in LAVoxelGrid.SLOTS:
		var a: int = d >> 1
		var s_lo: Vector3 = centre - half
		var s_hi: Vector3 = centre + half
		# LA_APPROX: coarse_exterior_slab
		var face: float = s_lo[a] if (d & 1) == 0 else s_hi[a]
		s_lo[a] = face - grid.cell_size if (d & 1) == 0 else face
		s_hi[a] = s_lo[a] + grid.cell_size
		out.append(_slab_weights(grid, s_lo.max(grid.origin), s_hi.min(grid.origin + span)))
	for d in LAVoxelGrid.SLOTS:
		for e in range(d + 1, LAVoxelGrid.SLOTS):
			if String(out[d].get("sig", "d")) != String(out[e].get("sig", "e")):
				continue
			var why: String = "faces %d and %d resolve to the same global cells: the slice spans less than one of them across that axis" % [d, e]
			out[d] = {"unresolved": why}
			out[e] = {"unresolved": why}
	return out


## Every global cell the world-space slab [s_lo, s_hi] touches, weighted by the overlap volume.
static func _slab_weights(grid: LAVoxelGrid, s_lo: Vector3, s_hi: Vector3) -> Dictionary:
	var g: float = grid.cell_size
	var dims: Vector3i = Vector3i(grid.nx, grid.ny, grid.nz)
	var i0: Vector3i = Vector3i.ZERO
	var i1: Vector3i = Vector3i.ZERO
	for i in 3:
		if s_hi[i] <= s_lo[i]:
			return {"unresolved": "the slab beyond this face lies outside the global box"}
		i0[i] = clampi(int(floor((s_lo[i] - grid.origin[i]) / g)), 0, dims[i] - 1)
		i1[i] = clampi(int(ceil((s_hi[i] - grid.origin[i]) / g)) - 1, 0, dims[i] - 1)
	var cells: PackedInt32Array = PackedInt32Array()
	var weights: PackedFloat32Array = PackedFloat32Array()
	var total: float = 0.0
	for z in range(i0.z, i1.z + 1):
		for y in range(i0.y, i1.y + 1):
			for x in range(i0.x, i1.x + 1):
				var idx: Vector3i = Vector3i(x, y, z)
				var w: float = 1.0
				for i in 3:
					var c: float = grid.origin[i] + float(idx[i]) * g
					w *= maxf(0.0, minf(c + g, s_hi[i]) - maxf(c, s_lo[i]))
				if w <= 0.0:
					continue
				cells.append(grid.index(x, y, z))
				weights.append(w)
				total += w
	var sig: PackedStringArray = PackedStringArray()
	for i in weights.size():
		weights[i] = weights[i] / total
		sig.append("%d:%.6f" % [cells[i], weights[i]])
	return {"cells": cells, "weights": weights, "sig": ",".join(sig)}


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
		var face: Dictionary = _faces[d]
		if face.has("unresolved"):
			continue
		var st: Dictionary = _face_state(face, legs)
		if not _raw_ok(st):
			push_warning("LAFieldBoundaryCapture3D: face %d read a non-finite state at step %d; the sample is dropped, not invented." % [d, step])
			return
		faces[str(d)] = st
	_samples.append({"step": step, "faces": faces})
	_write()


## The global field over one face's slab, each cell carrying the share of the slab it covers.
func _face_state(face: Dictionary, legs: Dictionary) -> Dictionary:
	var cells: PackedInt32Array = face["cells"]
	var weights: PackedFloat32Array = face["weights"]
	var sums: Dictionary = {}
	for name in _names:
		var arr: PackedFloat32Array = legs[name]
		var v: float = 0.0
		for i in cells.size():
			v += weights[i] * arr[cells[i]]
		sums[String(name)] = v
	var grav: Vector3 = Vector3.ZERO
	var amounts: Dictionary = {}
	for i in cells.size():
		grav += weights[i] * _f._gravity.g_vec_at(cells[i])
	for name in _amount_names:
		amounts[String(name)] = sums[String(name)]
	return {"temp_c": sums["temp"], "pressure_pa": sums["pressure"], "amounts": amounts,
		"velocity": [sums["vel_x"], sums["vel_y"], sums["vel_z"]],
		"gravity": [grav.x, grav.y, grav.z]}


func _write() -> void:
	var fh: FileAccess = FileAccess.open(_path, FileAccess.WRITE)
	if fh == null:
		if not _starved:
			_starved = true
			push_error("LAFieldBoundaryCapture3D: cannot write \"%s\" (%s)." % [_path, error_string(FileAccess.get_open_error())])
		return
	fh.store_string(JSON.stringify({"version": VERSION, "cadence": CAPTURE_EVERY,
		"cell_size": _f._grid.cell_size, "unresolved": _unresolved, "samples": _samples}))
	fh.close()


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


static func load_file(path: String) -> Dictionary:
	var fh: FileAccess = FileAccess.open(path, FileAccess.READ)
	if fh == null:
		return {}
	var parsed: Variant = JSON.parse_string(fh.get_as_text())
	fh.close()
	if not (parsed is Dictionary) or (parsed.get("samples", []) as Array).is_empty():
		return {}
	return parsed


## Why this face carries no exterior: what the global grid could not resolve, or a plain absence.
static func unresolved_note(data: Dictionary, d: int) -> String:
	var why: String = String((data.get("unresolved", {}) as Dictionary).get(str(d), ""))
	return why if why != "" else "the capture recorded no sample for it"


## Face slot -> the time-mean state over every sample: the CONSTANT boundary's supplied exterior.
static func constant_states(data: Dictionary) -> Dictionary:
	var faces: Dictionary = series_states(data).get("faces", {})
	var out: Dictionary = {}
	for d in faces:
		out[d] = _mean(faces[d])
	return out


static func _mean(arr: Array) -> Dictionary:
	var acc: Dictionary = (arr[0] as Dictionary).duplicate(true)
	var n: float = float(arr.size())
	for i in range(1, arr.size()):
		var st: Dictionary = arr[i]
		for k in SCALARS:
			acc[k] = float(acc[k]) + float(st[k])
		for k in VECTORS:
			acc[k] = Vector3(acc[k]) + Vector3(st[k])
		for name in st["amounts"]:
			acc["amounts"][name] = float(acc["amounts"][name]) + float(st["amounts"][name])
	for k in SCALARS:
		acc[k] = float(acc[k]) / n
	for k in VECTORS:
		acc[k] = Vector3(acc[k]) / n
	for name in acc["amounts"]:
		acc["amounts"][name] = float(acc["amounts"][name]) / n
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
	for vk in VECTORS:
		var v: Array = raw[vk]
		out[vk] = Vector3(float(v[0]), float(v[1]), float(v[2]))
	return out


static func _sample_ok(faces: Dictionary) -> bool:
	for key in faces:
		if not (faces[key] is Dictionary) or not _raw_ok(faces[key]):
			return false
	return true


## A recorded reading is a measurement only when every number in it is a finite number. The momentum
## runaway writes non-finite velocities, which JSON stores as null.
static func _raw_ok(raw: Dictionary) -> bool:
	for k in SCALARS:
		if not _num_ok(raw.get(k)):
			return false
	for vk in VECTORS:
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
