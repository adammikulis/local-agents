extends SceneTree

## ONE DISPATCH, OR THE SAME DISPATCH IN MANY SUBMITS. The derive and the reduce over one seeded box, run
## with no wait to plan against and again against the wait the whole step only just fit in, leave every
## buffer identical to the bit. A wait below one workgroup's own cost is refused before it is submitted.

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const RigScript: GDScript = preload("res://addons/local_agents/tests/bench_rig.gd")

const DERIVE_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"
const REDUCE_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/ReducePass.gd"
## The rung that first declares the reduce rows, so the fold has rows to publish.
const RUNG: int = 1
const N: int = 40
const CELL: float = 2000.0
const STEPS: int = 2
## A buffer value no pass writes, so a cell the refusal arm never submitted still holds it.
const UNWRITTEN: float = 12345.0

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
	var refused: int = _refusal()
	_finish(1 if _fail > 0 else 0, {"whole_submits": int(whole_led["submits"]),
		"split_submits": int(split_led["submits"]), "refused": refused})


func _finish(code: int, out: Dictionary) -> void:
	out["failures"] = _fail if code != 2 else -1
	print("SUBMIT_BUDGET=" + JSON.stringify(out))
	quit(code)


## One box, seeded the same way, stepped STEPS times with the driver planning against `wait_usec`.
## Returns, after each step, every buffer the rig holds and the folded rows, then the driver's ledger;
## empty when it cannot run.
func _arm(wait_usec: float, n: int) -> Dictionary:
	var rig: RefCounted = RigScript.new()
	if not rig.open() or not rig.build(n, n, n, CELL):
		printerr("gate_submit_budget: " + String(rig.error))
		return {}
	rig.driver.set_wait_usec(wait_usec)
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
		var bufs: Dictionary = {}
		for key in rig.bufs:
			bufs[String(key)] = rig.rd.buffer_get_data(rig.bufs[key])
		steps.append({"bufs": bufs, "rows": reduce._drain(rig.rd)})
	var out: Dictionary = {"steps": steps, "ledger": rig.driver.ledger()}
	rig.close()
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


## The derive against a wait no submit returns inside: the first workgroup goes alone to be measured,
## and every workgroup after it is refused before it reaches the device.
func _refusal() -> int:
	var rig: RefCounted = RigScript.new()
	if not rig.open() or not rig.build(8, 8, 8, CELL):
		_say("the refusal arm could not build its box: " + String(rig.error))
		return -1
	rig.driver.set_wait_usec(1.0)
	var derive: RefCounted = rig.attach(DERIVE_PATH)
	_seed(rig)
	var cc: int = int(rig.cell_count)
	rig.fill("g_rest", UNWRITTEN, cc * 3)
	rig.step_only(derive, _ctx(0))
	var g_rest: PackedFloat32Array = rig.read("g_rest")
	var refused: int = int(rig.driver.ledger()["refused"])
	var written: int = 0
	for c in cc:
		if g_rest[c * 3] != UNWRITTEN:
			written += 1
	rig.close()
	if refused < 1:
		_say("a wait below one workgroup's cost refused nothing.")
	if written != 64:
		_say("%d cells were derived under a wait only the first workgroup's own probe may run in." % written)
	return refused
