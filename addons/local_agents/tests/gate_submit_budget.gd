extends SceneTree

## ONE DISPATCH, OR THE SAME DISPATCH IN MANY SUBMITS, leaves every buffer identical to the bit: the derive
## and the reduce, and the acoustic group's list dispatches. A floor is the least lone submit, a reduce row
## kind its own measurement, and a refused piece is the last thing the step runs.

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const RigScript: GDScript = preload("res://addons/local_agents/tests/bench_rig.gd")

const DERIVE_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"
const REDUCE_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/ReducePass.gd"
const FLUX_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/FluxPass.gd"
## The rung that first declares the reduce rows, so the fold has rows to publish.
const RUNG: int = 1
const N: int = 40
const CELL: float = 2000.0
const STEPS: int = 2
## A buffer value no pass writes, so a cell the refusal arm never submitted still holds it.
const UNWRITTEN: float = 12345.0
## The acoustic box: nitrogen with a pressure step and a four-fold density step across it, so the thin
## side's sound speed puts it on a finer temporal level and the step moves gas across the list.
const T_RECORDS: PackedStringArray = ["pass:StateDerivePass.gd", "pass:FluxPass.gd", "transport:n2_eddy",
	"transport:mom_flux"]
const T_N: int = 24
const T_CELL: float = 1.0
const T_DT: float = 0.01
const T_STEPS: int = 2
const T_P: float = 1.0e5
const T_P_RATIO: float = 0.9
const T_RHO_RATIO: float = 0.25
const T_SEED_PASSES: int = 24
## Buffers whose contents are the order an atomic append left, not a state: the level sort and its queue.
## Each detector list's compacted indices are another.
const T_ORDERED: PackedStringArray = ["level_idx", "act_queue"]
## Lone single-workgroup submits the floor is taken over.
const FLOOR_SAMPLES: int = 8

var _fail: int = 0


func _say(msg: String) -> void:
	_fail += 1
	printerr("gate_submit_budget: " + msg)


func _init() -> void:
	QuietWindow.apply_if_automated()
	LAProcessSet.declare(RUNG)
	var whole: Dictionary = _arm(INF, N)
	if whole.is_empty():
		_finish(2, {})
		return
	var whole_led: Dictionary = whole["ledger"]
	var split: Dictionary = _arm(float(whole_led["worst_usec"]), N)
	if split.is_empty():
		_finish(2, {})
		return
	var split_led: Dictionary = split["ledger"]
	_same(whole, split)
	if int(whole_led["classes"]) != int(whole_led["dispatches"]):
		_say("with no wait to plan against, %d dispatches went out as %d pieces."
			% [int(whole_led["dispatches"]), int(whole_led["classes"])])
	if int(split_led["classes"]) <= int(split_led["dispatches"]):
		_say("against the wait the whole step fit in, no dispatch was split into submits.")
	for key in ["refused", "over_target"]:
		if int(split_led[key]) != 0:
			_say("the split arm counts %d %s." % [int(split_led[key]), key])
	_kinds(split)
	var listed: int = _transport_arms()
	LAProcessSet.declare(RUNG)
	var floors: int = _floor()
	var refused: int = _refusal()
	_finish(1 if _fail > 0 else 0, {"whole_submits": int(whole_led["submits"]),
		"split_submits": int(split_led["submits"]), "indirect_pieces": listed, "floor_samples": floors,
		"refused": refused})


func _finish(code: int, out: Dictionary) -> void:
	out["failures"] = _fail if code != 2 else -1
	print("SUBMIT_BUDGET=" + JSON.stringify(out))
	quit(code)


## One box, seeded the same way, stepped STEPS times with the driver planning against `wait_usec`.
## Returns, after each step, every buffer the rig holds and the folded rows, then the driver's ledger and
## the reduce's rows; empty when it cannot run.
func _arm(wait_usec: float, n: int) -> Dictionary:
	var rig: RefCounted = RigScript.new()
	if not rig.open() or not rig.build(n, n, n, CELL):
		printerr("gate_submit_budget: " + String(rig.error))
		return {}
	LAFieldDriver.rig_wait_usec(wait_usec)
	var derive: RefCounted = rig.attach(DERIVE_PATH)
	var reduce: RefCounted = rig.attach(REDUCE_PATH)
	if derive == null or reduce == null or reduce._rows.is_empty():
		printerr("gate_submit_budget: the derive or the reduce did not attach, or the reduce holds no row.")
		rig.close()
		return {}
	_seed(rig)
	var steps: Array = []
	for s in STEPS:
		rig.step(_ctx(s))
		steps.append({"bufs": _bufs(rig, PackedStringArray()), "rows": reduce._drain(rig.rd)})
	var blocks: Array = rig.driver.reduce_plan()["pc"]
	var out: Dictionary = {"steps": steps, "ledger": rig.driver.ledger(), "blocks": blocks}
	rig.close()
	return out


func _bufs(rig: RefCounted, skip: PackedStringArray) -> Dictionary:
	var out: Dictionary = {}
	for key in rig.bufs:
		if not skip.has(String(key)):
			out[String(key)] = rig.rd.buffer_get_data(rig.bufs[key])
	return out


func _ctx(step: int) -> Dictionary:
	return {"cell_size": CELL, "centre": Vector3.ZERO, "spin": Vector3.ZERO, "spin_rate_rad_s": 0.0,
		"sea_radius": 0.0, "gravity_self": 0.0, "step_index": float(step), "dt_s": 1.0, "seeding": false}


## A column of air over rock along the cell index, at pressures and enthalpies the substance table
## states, so every cell asks the derive a different question with an answer.
func _seed(rig: RefCounted) -> void:
	var cc: int = int(rig.cell_count)
	var full_h2o: float = LASubstances.full_mol_m3("h2o")
	var full_sil: float = LASubstances.full_mol_m3("silicate")
	var molar: PackedFloat32Array = LAMatterChannels.molar_masses()
	var m_sil: float = molar[LAMatterChannels.CHANNELS.find("silicate")]
	var h2o: PackedFloat32Array = PackedFloat32Array()
	var sil: PackedFloat32Array = PackedFloat32Array()
	var n2: PackedFloat32Array = PackedFloat32Array()
	var e: PackedFloat32Array = PackedFloat32Array()
	var pres: PackedFloat32Array = PackedFloat32Array()
	for c in cc:
		var f: float = float(c) / float(maxi(cc - 1, 1))
		var p: float = 101325.0 * pow(10.0, 3.0 * f)
		pres.append(p)
		h2o.append(f * full_h2o)
		sil.append((1.0 - f) * full_sil)
		n2.append(40.0 * (1.0 - f) if f > 0.0 else 0.0)
		var kg_w: float = f * full_h2o * LAPhysical.MOLAR_MASS_WATER_KG_MOL
		var kg_r: float = sil[c] * m_sil
		e.append(kg_w * LASubstances.enthalpy_at("h2o", 15.0, p)
			+ kg_r * LASubstances.enthalpy_at("silicate", 15.0, p))
	rig.upload("h2o", h2o)
	rig.upload("silicate", sil)
	rig.upload("n2", n2)
	rig.upload("e_j_m3", e)
	rig.upload("pressure", pres)
	# No gravity pass in this box, so no cell has a vertical neighbour.
	var none: PackedInt32Array = PackedInt32Array()
	none.resize(cc)
	none.fill(-1)
	for name in ["vert_up", "vert_down"]:
		var b: PackedByteArray = none.to_byte_array()
		rig.rd.buffer_update(rig.bufs[name], 0, b.size(), b)


func _same(a: Dictionary, b: Dictionary) -> void:
	for s in STEPS:
		var ab: Dictionary = a["steps"][s]["bufs"]
		var bb: Dictionary = b["steps"][s]["bufs"]
		for key in ab:
			if not bb.has(key) or ab[key] != bb[key]:
				_say("step %d: buffer \"%s\" differs between one dispatch and the same split." % [s, key])
		var ar: Dictionary = a["steps"][s]["rows"]
		var br: Dictionary = b["steps"][s]["rows"]
		if ar.size() < 2:
			_say("step %d: the reduce folded %d rows, so the fold was not compared." % [s, ar.size()])
		for key in ar:
			var x: float = float(ar[key])
			var y: float = float(br.get(key, NAN))
			if not br.has(key) or (x != y and not (is_nan(x) and is_nan(y))):
				_say("step %d: reduce row \"%s\" folds to %s whole and %s split." % [s, key, str(x), str(y)])


## EVERY REDUCE ROW KIND IS PRICED BY ITS OWN MEASUREMENT: one floor per distinct block, less the words
## that change no lane's work (the cell count, the partial slot, the threshold and the gate bounds).
func _kinds(split: Dictionary) -> void:
	var kinds: Dictionary = {}
	for pc: PackedByteArray in split["blocks"]:
		var k: PackedByteArray = pc.duplicate()
		for off in [0, 12, 16, 32, 36]:
			k.encode_u32(off, 0)
		kinds[k.hex_encode()] = true
	var measured: int = 0
	for key in (split["ledger"]["floors"] as Dictionary):
		measured += 1 if String(key).begins_with("reduce/") else 0
	if kinds.size() < 2:
		_say("the reduce rows are all one kind, so no kind was priced apart from another.")
	if measured != kinds.size():
		_say("the reduce rows are %d kinds, and the driver priced %d." % [kinds.size(), measured])


## THE ACTIVE-LIST DISPATCHES, whole and split: every list entry runs once, whichever submits carry it.
## Returns the pieces the split arm's indirect dispatches went out as.
func _transport_arms() -> int:
	LAProcessSet.declare_records(T_RECORDS)
	var whole: Dictionary = _transport(INF)
	if whole.is_empty():
		_say("the acoustic box could not run with no wait to plan against.")
		return -1
	var split: Dictionary = _transport(float(whole["ledger"]["worst_usec"]))
	if split.is_empty():
		_say("the acoustic box could not run against the wait its whole step fit in.")
		return -1
	var wl: Dictionary = whole["ledger"]
	var sl: Dictionary = split["ledger"]
	for key in whole["bufs"]:
		if not (split["bufs"] as Dictionary).has(key) or whole["bufs"][key] != split["bufs"][key]:
			_say("acoustic box: buffer \"%s\" differs between whole list dispatches and the same split." % key)
	if int(wl["indirect_dispatches"]) < 1:
		_say("the acoustic box dispatched nothing over an active list, so no list was examined.")
	if int(wl["indirect_classes"]) != int(wl["indirect_dispatches"]) or int(wl["reads"]) != 0:
		_say("with no wait to plan against, a list dispatch was split or a count was read.")
	if int(sl["indirect_classes"]) <= int(sl["indirect_dispatches"]):
		_say("against the wait its whole step fit in, no active-list dispatch was split into submits.")
	if int(sl["reads"]) < 1:
		_say("the split arm planned its list dispatches without reading a count.")
	for key in ["refused", "over_target"]:
		if int(sl[key]) != 0:
			_say("the acoustic split arm counts %d %s." % [int(sl[key]), key])
	var levels: Dictionary = {}
	for lv in (split["bufs"][LATemporalLevels.KEYS.level] as PackedByteArray).to_int32_array():
		levels[lv] = true
	if levels.size() < 2:
		_say("the acoustic box took one temporal level, so no level was handed across a face.")
	return int(sl["indirect_classes"])


func _transport(wait_usec: float) -> Dictionary:
	var rig: RefCounted = RigScript.new()
	if not rig.open() or not rig.build(T_N, T_N, T_N, T_CELL):
		printerr("gate_submit_budget: " + String(rig.error))
		return {}
	LAFieldDriver.rig_wait_usec(wait_usec)
	var derive: RefCounted = rig.attach(DERIVE_PATH)
	var flux: RefCounted = rig.attach(FLUX_PATH)
	if derive == null or flux == null:
		printerr("gate_submit_budget: " + String(rig.error))
		rig.close()
		return {}
	rig.add_levels(flux.group_count())
	var cc: int = int(rig.cell_count)
	var ctx: Dictionary = {"cell_size": T_CELL, "centre": Vector3.ZERO, "spin": Vector3.ZERO,
		"spin_rate_rad_s": 0.0, "sea_radius": 0.0, "gravity_self": 0.0, "dt_s": T_DT,
		"sun_dir": Vector3.ZERO, "cell_size_min": T_CELL, "step_index": 0.0, "seeding": false}
	var n2: PackedFloat32Array = rig.filled(cc, 0.0)
	var want: PackedFloat32Array = rig.filled(cc, 0.0)
	var centres: PackedVector3Array = rig.grid.centres
	for c in cc:
		var left: bool = centres[c].x < 0.0
		n2[c] = (1.0 if left else T_RHO_RATIO) / LAPhysical.MOLAR_MASS_N2_KG_MOL
		want[c] = T_P if left else T_P * T_P_RATIO
	rig.upload("n2", n2)
	_seed_pressure(rig, derive, ctx, want)
	for s in T_STEPS:
		ctx["step_index"] = float(s)
		flux.pre_step(rig.rd, ctx, cc, int(ceil(float(cc) / 64.0)))
		rig.step(ctx)
	var ordered: PackedStringArray = T_ORDERED.duplicate()
	for lrow: Dictionary in LATransportRecords.lists():
		ordered.append(String(LATransportRecords.list_buffers(String(lrow["label"]))["idx"]))
	var out: Dictionary = {"bufs": _bufs(rig, ordered), "ledger": rig.driver.ledger()}
	rig.close()
	return out


## The energy that puts each cell at the pressure asked for, by the secant rule on the derive's own
## equation of state.
func _seed_pressure(rig: RefCounted, derive: RefCounted, ctx: Dictionary, want: PackedFloat32Array) -> void:
	var n: int = want.size()
	var prev: PackedFloat32Array = rig.filled(n, 0.0)
	var e: PackedFloat32Array = rig.filled(n, 1.0e5)
	var p_prev: PackedFloat32Array = _pressure_of(rig, derive, ctx, prev)
	for _i in T_SEED_PASSES:
		var p: PackedFloat32Array = _pressure_of(rig, derive, ctx, e)
		var nxt: PackedFloat32Array = rig.filled(n, 0.0)
		for c in n:
			var dp: float = p[c] - p_prev[c]
			nxt[c] = e[c] if absf(dp) < 1.0e-9 else e[c] + (want[c] - p[c]) * (e[c] - prev[c]) / dp
		prev = e
		p_prev = p
		e = nxt
	_pressure_of(rig, derive, ctx, e)


func _pressure_of(rig: RefCounted, derive: RefCounted, ctx: Dictionary,
		e: PackedFloat32Array) -> PackedFloat32Array:
	rig.upload("e_j_m3", e)
	rig.fill("e_lith_j_m3", 0.0)
	rig.step_only(derive, ctx)
	return rig.read("pressure")


## THE FLOOR IS A LOWER BOUND: one workgroup's derive, alone in its submit again and again, and the floor
## the driver keeps for it is the least of what those submits took. Returns the samples taken.
func _floor() -> int:
	var rig: RefCounted = RigScript.new()
	if not rig.open() or not rig.build(4, 4, 4, CELL):
		_say("the floor arm could not build its box: " + String(rig.error))
		return -1
	LAFieldDriver.rig_wait_usec(1.0e12)
	var derive: RefCounted = rig.attach(DERIVE_PATH)
	_seed(rig)
	var ctx: Dictionary = _ctx(0)
	rig.step_only(derive, ctx)
	var pc: PackedByteArray = (ctx["restate"] as Dictionary)["pc"]
	var samples: PackedFloat64Array = PackedFloat64Array()
	for _i in FLOOR_SAMPLES:
		rig.driver.open()
		rig.driver.run(derive._pipe, [derive._set], [pc], PackedInt32Array([1]), [RID()],
			PackedInt32Array([0]), true, PackedStringArray(["gate/floor"]))
		rig.driver.close()
		samples.append(float(rig.driver.ledger()["last_usec"]))
	var floors: Dictionary = rig.driver.ledger()["floors"]
	rig.close()
	var lo: float = INF
	var hi: float = -INF
	for t in samples:
		lo = minf(lo, t)
		hi = maxf(hi, t)
	if not (hi > lo):
		_say("%d lone submits all took %s usec, so the floor's estimate was not examined."
			% [samples.size(), str(lo)])
	if float(floors.get("gate/floor", NAN)) != lo:
		_say("the floor is %s usec, and the least of the %d lone submits took %s."
			% [str(floors.get("gate/floor", NAN)), samples.size(), str(lo)])
	return samples.size()


## The derive against a wait no submit returns inside: the first workgroup goes alone to be measured,
## the next piece is refused before it reaches the device, and the step stops there: neither the rest of
## the derive, nor its detect phase, nor the reduce after it runs.
func _refusal() -> int:
	var rig: RefCounted = RigScript.new()
	if not rig.open() or not rig.build(8, 8, 8, CELL):
		_say("the refusal arm could not build its box: " + String(rig.error))
		return -1
	LAFieldDriver.rig_wait_usec(1.0)
	var derive: RefCounted = rig.attach(DERIVE_PATH)
	var reduce: RefCounted = rig.attach(REDUCE_PATH)
	_seed(rig)
	var cc: int = int(rig.cell_count)
	rig.fill("g_rest", UNWRITTEN, cc * 3)
	rig.fill("surface_class", UNWRITTEN, cc)
	var partials: int = int(reduce._groups) * reduce._rows.size()
	rig.fill(reduce.PARTIALS, UNWRITTEN, partials)
	rig.step(_ctx(0))
	var g_rest: PackedFloat32Array = rig.read("g_rest")
	var surface: PackedFloat32Array = rig.read("surface_class")
	var parts: PackedFloat32Array = rig.read(reduce.PARTIALS)
	var led: Dictionary = rig.driver.ledger()
	var aborted: String = rig.driver.aborted()
	var written: int = 0
	var detected: int = 0
	var reduced: int = 0
	for c in cc:
		written += 1 if g_rest[c * 3] != UNWRITTEN else 0
		detected += 1 if surface[c] != UNWRITTEN else 0
	for i in partials:
		reduced += 1 if parts[i] != UNWRITTEN else 0
	rig.close()
	if int(led["refused"]) != 1:
		_say("a wait below one workgroup's cost refused %d pieces, not the one that aborts the step."
			% int(led["refused"]))
	if not aborted.begins_with("StateDerivePass/"):
		_say("the refusal aborted \"%s\", not the derive it fell in." % aborted)
	if written != 64:
		_say("%d cells were derived under a wait only the first workgroup's own probe may run in." % written)
	if detected != 0 or reduced != 0:
		_say("after the refusal, the detect phase wrote %d cells and the reduce %d partials." % [detected, reduced])
	return int(led["refused"])
