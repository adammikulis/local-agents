extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## The field reduces itself. One kernel, one dispatch per LAReduceRecords row, one partial per workgroup.
## Last in the chain, so every row reads settled state. The blocks and the fold table are the driver's.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/reduce.glsl"
const PARTIALS: String = "reduce_partials"
const GROUP: int = 64

var _pipe: RID = RID()
var _rows: Array = []                   # rows whose buffers exist, in dispatch order
var _sets: Array = []                   # per row: its uniform set
var _partials: RID = RID()
var _groups: int = 0
var _step: int = -1                     # field step the last dispatch reduced
var _latch_step: Dictionary = {}        # ref buffer -> field step that reference was taken at
var _failed_announced: bool = false
var _last: Dictionary = {}              # the last drain, for the query modules that read rows directly


## One partial per workgroup per row, plus one reference buffer per `ref` the rows name.
func _buffers(cc: int) -> Dictionary:
	var g: int = maxi(int(ceil(float(cc) / float(GROUP))), 1)
	var out: Dictionary = {PARTIALS: g * LAProcessSet.reduce_rows().size()}
	for row: Dictionary in LAProcessSet.reduce_rows():
		if String(row.get("ref", "")) != "":
			out[String(row["ref"])] = maxi(cc, 1)
	return out


func _setup(bufs: Dictionary, cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	if not _pipe.is_valid():
		return
	_groups = maxi(int(ceil(float(cc) / float(GROUP))), 1)
	_partials = _single(bufs, PARTIALS)
	if not _partials.is_valid():
		push_error("ReducePass: the driver allocated no \"%s\"; every reduced total is absent." % PARTIALS)
		return
	var solid: RID = _single(bufs, "solid")
	var nbr: RID = _single(bufs, "nbr")
	var vert_up: RID = _single(bufs, "vert_up")
	var vert_down: RID = _single(bufs, "vert_down")
	if not nbr.is_valid() or not vert_up.is_valid() or not vert_down.is_valid():
		push_error("ReducePass: the driver allocated no \"nbr\"/\"vert_up\"/\"vert_down\"; no row can ask "
			+ "what is beside a cell, and none can ask what is below it.")
		return
	for row: Dictionary in LAProcessSet.reduce_rows():
		var src: String = String(row["source"])
		var aux: String = String(row.get("aux", ""))
		var aux2: String = String(row.get("aux2", ""))
		var ref: String = String(row.get("ref", ""))
		var gate: String = String(row.get("gate", ""))
		var gate_aux: String = String(row.get("gate_aux", ""))
		var absent: PackedStringArray = PackedStringArray()
		for key in [src, aux, aux2, ref, gate, gate_aux]:
			if String(key) != "" and not bufs.has(String(key)):
				absent.append(String(key))
		if absent.size() > 0:
			push_error(("ReducePass: row \"%s\" names %s, which nothing allocates. Its reading is ABSENT, "
				+ "not zero, and its consumer publishes null.") % [String(row["key"]), ", ".join(absent)])
			continue
		# A row that names no aux, gate or ref binds `solid` into those slots: already bound, and read
		# through a predicate the row leaves off.
		_sets.append(_uset(_pipe, LABindings.set_for("reduce.glsl", bufs, {
			"reduce_src": _single(bufs, src),
			"reduce_aux": _single(bufs, aux) if aux != "" else solid,
			"reduce_aux2": _single(bufs, aux2) if aux2 != "" else solid,
			"reduce_ref": bufs[ref] if ref != "" else solid,
			"reduce_gate": _single(bufs, gate) if gate != "" else solid,
			"reduce_gate_aux": _single(bufs, gate_aux) if gate_aux != "" else solid,
			"reduce_partials": _partials})))
		_rows.append(row)
	_driver.plan_reduce({"pipe": _pipe, "sets": _sets, "rows": _rows, "cell_count": cc,
		"groups": _groups})


func dispatch(rd: RenderingDevice, cl: int, ctx: Dictionary, _cc: int, _groups_in: int) -> void:
	if not _dispatchable() or _sets.is_empty():
		if not _failed_announced:
			_failed_announced = true
			push_error("GPU_REQUIRED: ReducePass has no pipeline, so the conservation ledger reads nothing "
				+ "and every substance total is absent. Usual cause: reduce.glsl was never imported — run "
				+ "`godot --headless --path . --import` in this worktree.")
		return
	_step = int(ctx.get("step_index", -1))
	# A REFERENCE IS THE STATE THE WORLD WAS BUILT WITH, so a mid-seed derive takes none.
	_run(rd, cl, not bool(ctx.get("seeding", false)))


## Every row the latch policy admits this call. `latch_ok` false leaves every reference where it is.
func _run(_rd: RenderingDevice, cl: int, latch_ok: bool) -> void:
	var rows: PackedInt32Array = PackedInt32Array()
	for r in _rows.size():
		var row: Dictionary = _rows[r]
		if int(row["op"]) == LAReduceRecords.Op.LATCH:
			var ref: String = String(row.get("ref", ""))
			# A reference is the state the world was built with, taken once per row.
			if _latch_step.has(ref) or not latch_ok:
				continue
			_latch_step[ref] = _step
		rows.append(r)
	_driver.run_reduce(cl, rows)


## A reduce taken BETWEEN passes: this pass runs last, so a row cannot say WHICH pass moved a total.
## Leaves every reference and `latest()` alone — arming a probe may not move what an instrument reads.
func checkpoint(rd: RenderingDevice, _ctx: Dictionary, _cc: int) -> Dictionary:
	if not _dispatchable() or _sets.is_empty():
		return {}
	var cl: int = rd.compute_list_begin()
	_run(rd, cl, false)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	return _fold_rows()


## The last drained rows. Reading does not clear it: several instruments read the same reduction.
func latest() -> Dictionary:
	return _last


func _drain(_rd: RenderingDevice) -> Dictionary:
	_last = _fold_rows()
	return _last


## ONE readback of the partials buffer, folded on the device side of the boundary: a row's groups
## combined in float64, in slot order. A MIN/MAX lane that kept no cell is ABSENT, never zero.
func _fold_rows() -> Dictionary:
	if _rows.is_empty() or not _partials.is_valid() or _driver == null:
		return {}
	var out: Dictionary = _driver.fold_reduce(_partials)
	out["reduce_step"] = float(_step)
	for key in _latch_step:
		out[String(key) + "_step"] = float(_latch_step[key])
	return out
