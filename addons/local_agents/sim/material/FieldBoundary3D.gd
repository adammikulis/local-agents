class_name LAFieldBoundary3D
extends RefCounted

## Box-face boundary-state provider. Per face: SHUT (wall), WRAP (torus partner, exact, no ghost state),
## CONSTANT (one supplied exterior state, filled into the ghost buffer tails at attach), REPLAY (the same
## tails re-filled per step from a supplied series). The redirect table is transport.glsl binding 27.

enum { SHUT, WRAP, CONSTANT, REPLAY }

const MODE_NAMES: Dictionary = {"shut": SHUT, "wrap": WRAP, "constant": CONSTANT, "replay": REPLAY}
const SETTING: String = "local_agents/sim/boundary_faces"
const ENV_VAR: String = "LA_BOUNDARY_FACES"
const META_FACES: StringName = &"boundary_faces"
const META_STATES: StringName = &"boundary_face_states"
## A supplied face state is captured data, never invented here. These keys are required of every state.
const STATE_KEYS: PackedStringArray = ["temp_c", "pressure_pa", "gravity", "velocity", "amounts"]

var error: String = ""
var _grid: LAVoxelGrid = null
var _cc: int = 0
var _modes: PackedInt32Array = PackedInt32Array()
var _states: Array = []
var _face_cells: Array = []
var _face_base: PackedInt32Array = PackedInt32Array()
## (cell_count + ghost_rows) * 6 redirect: -1 shut, < cc wrap partner, >= cc ghost tail cell.
var _ghost: PackedInt32Array = PackedInt32Array()
## Per ghost tail cell: the prescribed pressure, Pa — the momentum ledger's CPU mirror.
var _mirror_p: PackedFloat32Array = PackedFloat32Array()
var _gpu = null


## Read the face configuration off the owning field. Node meta -> project setting -> env -> all SHUT.
func setup(field) -> void:
	var spec: String = ""
	if field.has_meta(META_FACES):
		spec = String(field.get_meta(META_FACES))
	elif ProjectSettings.has_setting(SETTING):
		spec = String(ProjectSettings.get_setting(SETTING))
	elif OS.has_environment(ENV_VAR):
		spec = OS.get_environment(ENV_VAR)
	var states: Array = [null, null, null, null, null, null]
	if field.has_meta(META_STATES):
		var sup: Dictionary = field.get_meta(META_STATES)
		for face in sup:
			var d: int = int(face)
			if d >= 0 and d < LAVoxelGrid.SLOTS:
				states[d] = sup[face]
	configure(field._grid, _parse_modes(spec), states)


func _parse_modes(spec: String) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	out.resize(LAVoxelGrid.SLOTS)
	out.fill(SHUT)
	if spec.strip_edges() == "":
		return out
	var toks: PackedStringArray = spec.split(",")
	if toks.size() != LAVoxelGrid.SLOTS:
		_fail("face spec \"%s\" names %d faces, the box has %d" % [spec, toks.size(), LAVoxelGrid.SLOTS])
		return out
	for d in LAVoxelGrid.SLOTS:
		var name: String = toks[d].strip_edges().to_lower()
		if not MODE_NAMES.has(name):
			_fail("face %d mode \"%s\" is not shut|wrap|constant|replay" % [d, name])
			return out
		out[d] = int(MODE_NAMES[name])
	return out


## Build the redirect table and ghost rows. Must run BEFORE the GPU driver's setup reads grid.ghost_rows.
func configure(grid: LAVoxelGrid, modes: PackedInt32Array, states: Array) -> bool:
	_grid = grid
	_cc = grid.cell_count
	_modes = modes
	_states = states
	_face_cells = [null, null, null, null, null, null]
	_face_base = PackedInt32Array([-1, -1, -1, -1, -1, -1])
	if error != "":
		return false
	var ng: int = 0
	for d in LAVoxelGrid.SLOTS:
		var m: int = _modes[d]
		if m == WRAP and _modes[LAVoxelGrid.opposite_slot(d)] != WRAP:
			return _fail("face %d is WRAP but its opposite is not: a torus wraps both ends of an axis" % d)
		if m == CONSTANT or m == REPLAY:
			if not (_states[d] is Dictionary):
				return _fail("face %d needs a supplied state and got none" % d)
			if not _valid_state(_states[d], d):
				return false
			var cells: PackedInt32Array = _cells_on_face(d)
			_face_cells[d] = cells
			ng += cells.size()
	grid.add_ghost_rows(ng)
	_ghost.resize((_cc + ng) * LAVoxelGrid.SLOTS)
	_ghost.fill(-1)
	_mirror_p.resize(ng)
	_mirror_p.fill(NAN)
	var nbr: PackedInt32Array = grid.neighbours
	var next: int = _cc
	for d in LAVoxelGrid.SLOTS:
		if _modes[d] == WRAP:
			for c in _cells_on_face(d):
				_ghost[c * LAVoxelGrid.SLOTS + d] = _wrap_partner(c, d)
		elif _modes[d] == CONSTANT or _modes[d] == REPLAY:
			_face_base[d] = next
			var back: int = LAVoxelGrid.opposite_slot(d)
			var cells: PackedInt32Array = _face_cells[d]
			for i in cells.size():
				var gh: int = next + i
				_ghost[cells[i] * LAVoxelGrid.SLOTS + d] = gh
				nbr[gh * LAVoxelGrid.SLOTS + back] = cells[i]
			next += cells.size()
	grid.neighbours = nbr
	return true


func _valid_state(st: Dictionary, d: int) -> bool:
	for key in STATE_KEYS:
		if not st.has(key):
			return _fail("face %d state has no \"%s\": a boundary state is supplied, never invented" % [d, key])
	if float(st["pressure_pa"]) <= 0.0:
		return _fail("face %d state pressure must be positive" % d)
	if not (st["amounts"] is Dictionary):
		return _fail("face %d state \"amounts\" is not channel -> volume fraction" % d)
	var rows: Dictionary = LAChannels.rows()
	for name in st["amounts"]:
		var row: Dictionary = rows.get(String(name), {})
		if String(row.get("unit", "")) != "vf":
			return _fail("face %d state names \"%s\", which is not a matter channel" % [d, name])
	return true


## Upload the redirect table and every supplied face's ghost tails. Runs AFTER the GPU driver's setup.
func attach(gpu) -> void:
	if error != "" or gpu == null or gpu._rd == null:
		return
	_gpu = gpu
	if not _gpu._bufs.has("ghost"):
		_fail("the driver holds no \"ghost\" buffer")
		return
	var bytes: PackedByteArray = _ghost.to_byte_array()
	_gpu._rd.buffer_update(_gpu._bufs["ghost"], 0, bytes.size(), bytes)
	for d in LAVoxelGrid.SLOTS:
		if _modes[d] == CONSTANT or _modes[d] == REPLAY:
			_fill_face(d)


## The REPLAY seam: the series owner supplies the next state and the tails are re-uploaded in place.
func replay(d: int, state: Dictionary) -> void:
	if _modes.size() != LAVoxelGrid.SLOTS or _modes[d] != REPLAY:
		_fail("face %d is not REPLAY" % d)
		return
	if not _valid_state(state, d):
		return
	_states[d] = state
	if _gpu != null:
		_fill_face(d)


## The redirect for an interior cell's face: -1 shut, < cc wrap partner, >= cc ghost tail cell.
func redirect(c: int, d: int) -> int:
	var i: int = c * LAVoxelGrid.SLOTS + d
	return _ghost[i] if i >= 0 and i < _ghost.size() else -1


## The prescribed pressure at a ghost tail cell, Pa; NAN when it holds none.
func ghost_pressure(gc: int) -> float:
	var i: int = gc - _cc
	return _mirror_p[i] if i >= 0 and i < _mirror_p.size() else NAN


func mode(d: int) -> int:
	return _modes[d] if d >= 0 and d < _modes.size() else SHUT


func ghost_count() -> int:
	return _mirror_p.size()


## Every WRAP face entry re-derived by modulo stepping and compared against the table. Can FAIL.
func wrap_check() -> Dictionary:
	var checked: int = 0
	var mismatches: int = 0
	var dims: PackedInt32Array = PackedInt32Array([_grid.nx, _grid.ny, _grid.nz])
	for d in LAVoxelGrid.SLOTS:
		if _modes[d] != WRAP:
			continue
		var s: Vector3i = LAVoxelGrid.SLOT_STEP[d]
		for c in _cells_on_face(d):
			var v: Vector3i = _grid.coords(c)
			var want: int = _grid.index(
				(v.x + s.x + dims[0]) % dims[0],
				(v.y + s.y + dims[1]) % dims[1],
				(v.z + s.z + dims[2]) % dims[2])
			checked += 1
			if _ghost[c * LAVoxelGrid.SLOTS + d] != want:
				mismatches += 1
	return {"ok": mismatches == 0 and checked > 0, "checked": checked, "mismatches": mismatches}


func _cells_on_face(d: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var axis: int = d >> 1
	var dims: PackedInt32Array = PackedInt32Array([_grid.nx, _grid.ny, _grid.nz])
	var u_axis: int = (axis + 1) % 3
	var v_axis: int = (axis + 2) % 3
	var p: PackedInt32Array = PackedInt32Array([0, 0, 0])
	p[axis] = 0 if (d & 1) == 0 else dims[axis] - 1
	for u in dims[u_axis]:
		for v in dims[v_axis]:
			p[u_axis] = u
			p[v_axis] = v
			out.append(_grid.index(p[0], p[1], p[2]))
	return out


func _wrap_partner(c: int, d: int) -> int:
	var axis: int = d >> 1
	var dims: PackedInt32Array = PackedInt32Array([_grid.nx, _grid.ny, _grid.nz])
	var p: PackedInt32Array = PackedInt32Array([0, 0, 0])
	var v: Vector3i = _grid.coords(c)
	p[0] = v.x
	p[1] = v.y
	p[2] = v.z
	p[axis] = dims[axis] - 1 if (d & 1) == 0 else 0
	return _grid.index(p[0], p[1], p[2])


## Fill one face's ghost tails with the state the same way the seed derives enthalpy from a temperature
## and a mixture, decomposed per entry the way state_derive.glsl carries it.
func _fill_face(d: int) -> void:
	var st: Dictionary = _states[d]
	var cells: PackedInt32Array = _face_cells[d]
	var base: int = _face_base[d]
	var count: int = cells.size()
	if count <= 0 or base < 0:
		return
	var per_cell: Dictionary = _derive(st, d)
	if error != "":
		return
	for key in per_cell:
		_upload(String(key), base, _span(count, float(per_cell[key])))
	var g: Vector3 = st["gravity"]
	var gv: PackedFloat32Array = PackedFloat32Array()
	gv.resize(count * 3)
	for i in count:
		gv[i * 3 + 0] = g.x
		gv[i * 3 + 1] = g.y
		gv[i * 3 + 2] = g.z
	_upload_at(_gpu._bufs["gravity"], base * 3, gv)
	var p_pa: float = float(st["pressure_pa"])
	for i in count:
		_mirror_p[base - _cc + i] = p_pa


## Buffer name -> the one value every ghost cell of this face holds.
func _derive(st: Dictionary, d: int) -> Dictionary:
	var t_c: float = float(st["temp_c"])
	var p_pa: float = float(st["pressure_pa"])
	var vel: Vector3 = st["velocity"]
	var amounts: Dictionary = st["amounts"]
	var vol: float = _grid.cell_volume()
	var rows: Dictionary = LAChannels.rows()
	var table: Dictionary = LASubstances.table()
	var out: Dictionary = {}
	var mass_total: float = 0.0
	var n_gas: float = 0.0
	var v_lambda: float = 0.0
	var v_used: float = 0.0
	var m_by_id: Dictionary = {}
	for name in amounts:
		var vf: float = maxf(float(amounts[name]), 0.0)
		out[String(name)] = vf
		if vf <= 0.0:
			continue
		var id: String = String(rows[name]["substance"])
		var entry: Dictionary = table.get(id, {})
		var rho: float = float(entry.get("density", 0.0))
		if rho <= 0.0:
			_fail("face %d: LASubstances has no density for \"%s\"" % [d, id])
			return {}
		var m: float = vf * rho * vol
		m_by_id[id] = float(m_by_id.get(id, 0.0)) + m
		mass_total += m
		if LAMatterChannels.GASES.has(id):
			n_gas += m / float(entry.get("molar_mass", 1.0))
		v_lambda += vf * float(entry.get("conductivity", 0.0))
		v_used += vf
	var m_h2o: float = float(m_by_id.get("h2o", 0.0))
	var e: Dictionary = LAFieldEnthalpySeed.entry_enthalpies(m_by_id, n_gas, t_c, p_pa)
	out["h_h2o"] = float(e["h_h2o"]) / vol
	out["h_silicate"] = float(e["h_silicate"]) / vol
	out["h_sensible"] = float(e["h_sensible"]) / vol
	out["cap_sensible"] = float(e["cap_sensible"]) / vol
	out["h_j_m3"] = (float(e["h_h2o"]) + float(e["h_silicate"]) + float(e["h_sensible"])) / vol
	out["temp"] = t_c
	out["pressure"] = p_pa
	out["rho_bulk"] = mass_total / vol
	out["conductivity"] = v_lambda / v_used if v_used > 0.0 else 0.0
	out["vel_x"] = vel.x
	out["vel_y"] = vel.y
	out["vel_z"] = vel.z
	out["mom_x"] = vel.x * mass_total / vol
	out["mom_y"] = vel.y * mass_total / vol
	out["mom_z"] = vel.z * mass_total / vol
	var f_v: float = 0.0
	var molten: float = _melt_share("h2o", t_c, p_pa)
	if m_h2o > 0.0:
		f_v = LAMixtureEnthalpy.vapour_fraction("h2o", t_c, p_pa, m_h2o, n_gas)
	out["h2o_vapour"] = f_v
	out["h2o_liquid"] = (1.0 - f_v) * molten
	out["h2o_solid"] = (1.0 - f_v) * (1.0 - molten)
	out["silicate_melt"] = _melt_share("silicate", t_c, p_pa)
	var extra: Dictionary = st.get("extra", {})
	for key in extra:
		if not _gpu._bufs.has(String(key)):
			_fail("face %d extra names \"%s\", which the driver holds no buffer for" % [d, key])
			return {}
		out[String(key)] = float(extra[key])
	return out


## Melted share of a ladder substance at (t, p): the lever rule over its melting interval.
static func _melt_share(id: String, t_c: float, p_pa: float) -> float:
	var solidus: float = LASubstances.melt_c_at(id, p_pa)
	if not is_finite(solidus) or t_c <= solidus:
		return 0.0
	var liquidus: float = LASubstances.liquidus_c_at(id, p_pa)
	if t_c >= liquidus:
		return 1.0
	return (t_c - solidus) / (liquidus - solidus)


func _span(count: int, value: float) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(count)
	out.fill(value)
	return out


func _upload(name: String, first_cell: int, values: PackedFloat32Array) -> void:
	if not _gpu._bufs.has(name):
		_fail("no \"%s\" buffer to fill a ghost tail in" % name)
		return
	_upload_at(_gpu._bufs[name], first_cell, values)


func _upload_at(buf: RID, first_float: int, values: PackedFloat32Array) -> void:
	var bytes: PackedByteArray = values.to_byte_array()
	_gpu._rd.buffer_update(buf, first_float * 4, bytes.size(), bytes)


func _fail(msg: String) -> bool:
	error = msg
	push_error("LAFieldBoundary3D: " + msg)
	return false
