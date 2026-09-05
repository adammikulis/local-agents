class_name LAFieldPassAttribution3D
extends RefCounted

## Between-pass attribution for one conserved substance: which pass changed its total, and by how much.
## Every total is a reduce row folded on the device; nothing here downloads a channel.

const SampleScript: GDScript = preload("res://addons/local_agents/sim/material/FieldStepSample3D.gd")

var _f = null                              # back-reference to the owning LAMaterialField3D
var _rec: Dictionary = {}
var _sched = null                          # LAFieldStepSample3D: which steps are checkpointed

var _missing: PackedStringArray = PackedStringArray()
var _prev: Dictionary = {}                 # scalar -> value at the previous checkpoint
var _start: Dictionary = {}                # scalar -> value at the step's opening
var _legs: Dictionary = {}                 # scalar -> {leg key -> delta}
var _parts: Dictionary = {}                # scalar -> per-channel closing split
var _pair_end: Dictionary = {}             # scalar -> closing value of the pair's first sample


func setup(field, record: Dictionary) -> void:
	if record.is_empty():
		push_error("LAFieldPassAttribution3D: no record — see LAFieldAttributionRecords.ORDER")
		return
	_f = field
	_rec = record
	_sched = SampleScript.new()
	_sched.setup(field)


## Called once per field step BEFORE _gpu.step(). Arms the driver's between-pass probe on the steps this
## sampler wants and leaves it disarmed otherwise.
func pre_step() -> void:
	if _sched == null:
		return
	if _sched.arm(Callable(self, "on_checkpoint")):
		_pair_end = {}


## The between-pass probe. `pass_index` -1 = before any pass ran; otherwise the index of the pass that just
## finished, with `pass_name` its script basename. The device has just been synced.
func on_checkpoint(pass_index: int, pass_name: String) -> void:
	if pass_index < 0:
		_legs = {}
		_parts = {}
		var opening: Dictionary = _sample()
		_start = opening.duplicate()
		_prev = opening.duplicate()
		return
	var now: Dictionary = _sample()
	if now.is_empty() or _start.is_empty():
		return
	var key: String = SampleScript.leg_key(pass_name)
	for name in now:
		var d: Dictionary = _legs.get(name, {})
		d[key] = float(now[name]) - float(_prev[name])
		_legs[name] = d
	_prev = now


## Called once per field step AFTER _gpu.step(). Prints the sampled step's budget; a no-op otherwise.
func post_step() -> void:
	if _sched == null or _sched.pair() == 0:
		return
	var marker: String = String(_rec.get("marker", ""))
	var out: Dictionary = {"field_step": SampleScript.field_step(_f), "pair": _sched.pair()}
	if not _missing.is_empty():
		out["refused"] = true
		out["missing"] = _missing
		print(marker, "=", JSON.stringify(out))
		_clear_step()
		return
	if _legs.is_empty():
		return
	for row in _rec.get("rows", []):
		_publish_row(out, row)
	for key in _rec.get("derived", {}):
		var pair: Array = _rec["derived"][key]
		out[key] = float(_prev[pair[0]]) - float(_prev[pair[1]])
	for scalar in _rec.get("parts", {}):
		out[String(_rec["parts"][scalar])] = _parts.get(scalar, {})
	var res: Dictionary = _rec.get("resolution", {})
	var floor_v: float = 0.0
	if not res.is_empty():
		floor_v = _resolution(String(res["scalar"]))
		out[String(res["key"])] = floor_v
	var silent: PackedStringArray = _rec.get("silent_heat", PackedStringArray())
	if silent.size() > 0 and not res.is_empty():
		var violations: PackedStringArray = _silent_violations(silent, floor_v, String(res["scalar"]))
		if violations.size() > 0:
			out["INSTRUMENT_WRONG_silent_pass_moved_heat"] = violations
	_pair_end = _prev.duplicate()
	print(marker, "=", JSON.stringify(out))
	_clear_step()


# --- report ---------------------------------------------------------------------------------------

func _publish_row(out: Dictionary, row: Dictionary) -> void:
	var scalar: String = String(row["scalar"])
	var value: float = float(_prev[scalar])
	var opened: float = float(_start[scalar])
	if row.has("total"):
		out[String(row["total"])] = value
	if row.has("step"):
		out[String(row["step"])] = value - opened
	if row.has("legs"):
		out[String(row["legs"])] = _legs.get(scalar, {})
	if row.has("residual"):
		out[String(row["residual"])] = (value - opened) - _leg_sum(scalar)
	# The instrument's falsifiable number: this step opened where the previous one closed.
	if row.has("chain") and _sched.pair() == 2 and _pair_end.has(scalar):
		out[String(row["chain"])] = opened - float(_pair_end[scalar])


func _leg_sum(scalar: String) -> float:
	var acc: float = 0.0
	for k in _legs.get(scalar, {}):
		acc += float(_legs[scalar][k])
	return acc


## Absolute resolution of a difference of two float32 readback sums, in the scalar's own units.
func _resolution(scalar: String) -> float:
	var cc: int = _f._cell_count if _f != null else 0
	return LAMaterialFieldConservation3D.noise_floor(cc) * absf(float(_prev[scalar]))


## Passes that bind no writable enthalpy buffer and yet moved the stock by more than the fold resolves.
func _silent_violations(silent: PackedStringArray, floor_v: float, scalar: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var legs: Dictionary = _legs.get(scalar, {})
	for k in legs:
		if silent.has(String(k)) and absf(float(legs[k])) > floor_v:
			out.append(String(k))
	return out


func _clear_step() -> void:
	_legs = {}
	_parts = {}


# --- sampling -------------------------------------------------------------------------------------

## One checkpoint, folded on the device. Returns the record's scalars, or an empty dictionary naming the
## rows this world does not hold.
func _sample() -> Dictionary:
	var reduce = SampleScript.reduce_of(_f)
	if reduce == null:
		_missing = PackedStringArray(["ReducePass"])
		return {}
	var gpu = _f._gpu
	var rows: Dictionary = reduce.checkpoint(gpu._rd, gpu._ctx, gpu._cc)
	if bool(_rec["energy"]):
		return _energy_scalars(rows)
	return _mass_scalars(rows, _rec["channels"])


## The ledger's own mask-free and open-only stocks, in moles.
func _mass_scalars(rows: Dictionary, channels: PackedStringArray) -> Dictionary:
	var open_parts: Dictionary = {}
	var all_parts: Dictionary = {}
	var absent: PackedStringArray = PackedStringArray()
	for name in channels:
		var n: String = String(name)
		if not rows.has("all_" + n) or not rows.has("open_" + n):
			absent.append(n)
			continue
		all_parts[n] = float(rows["all_" + n])
		open_parts[n] = float(rows["open_" + n])
	if not rows.has("solid_cells"):
		absent.append("solid_cells")
	_missing = absent
	if absent.size() > 0:
		return {}
	var totals: Dictionary = {"open": LAFieldLedgerRecords.sum_of(open_parts, channels),
		"all": LAFieldLedgerRecords.sum_of(all_parts, channels)}
	all_parts["solid_cells"] = int(round(float(rows["solid_cells"])))
	_parts = {"open": open_parts, "all": all_parts}
	return totals


## The stock is the enthalpy the cells hold: the fluid's reservoir and the lattice's.
func _energy_scalars(rows: Dictionary) -> Dictionary:
	var absent: PackedStringArray = PackedStringArray()
	for key in ["energy_stock", "energy_stock_lith"]:
		if not rows.has(key):
			absent.append(String(key))
	_missing = absent
	if absent.size() > 0:
		return {}
	return {"stock": float(rows["energy_stock"]) + float(rows["energy_stock_lith"])}
