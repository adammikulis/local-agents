class_name LAFieldPassAttribution3D
extends RefCounted

## Between-pass attribution for one conserved substance: which pass changed its total, and by how much.
## The substance is data (LAFieldAttributionRecords); the walk is LAFieldLedgerFold3D's; this file owns the

const FoldScript: GDScript = preload("res://addons/local_agents/sim/material/FieldLedgerFold3D.gd")

## Field steps between sampled PAIRS. A sample checkpoints between every pass, so it is not free.
const SAMPLE_EVERY: int = 50

var _f = null                              # back-reference to the owning LAMaterialField3D
var _rec: Dictionary = {}
var _fold = null

# Primed so the first pair samples at field step 1: the opening total is what separates a run that lost
# matter from a build that started with less.
var _gate: int = SAMPLE_EVERY - 1
var _in_pair: int = 0                      # 0 = not sampling, 1 = first of the pair, 2 = second

var _done: Dictionary = {}                 # pass name -> true, once it has run this step
var _missing: PackedStringArray = PackedStringArray()
var _prev: Dictionary = {}                 # scalar -> value at the previous checkpoint
var _start: Dictionary = {}                # scalar -> value at the step's opening
var _legs: Dictionary = {}                 # scalar -> {leg key -> delta}
var _parts: Dictionary = {}                # scalar -> per-channel closing split
var _pair_end: Dictionary = {}             # scalar -> closing value of the pair's first sample
var _cum: Dictionary = {}                  # scalar -> running within-step sum, for the energy split terms


func setup(field, record: Dictionary) -> void:
	if record.is_empty():
		push_error("LAFieldPassAttribution3D: no record — see LAFieldAttributionRecords.ORDER")
		return
	_f = field
	_rec = record
	_fold = FoldScript.new()
	_fold.setup(field)


## Called once per field step BEFORE _gpu.step(). Arms the driver's between-pass probe on the steps this
## sampler wants and leaves it disarmed otherwise.
func pre_step() -> void:
	if _f == null or _f._gpu == null or not _f._gpu.has_method("set_step_probe"):
		return
	if _in_pair == 1:
		_in_pair = 2
	else:
		_gate += 1
		if _gate >= SAMPLE_EVERY:
			_gate = 0
			_in_pair = 1
			_pair_end = {}
		else:
			_in_pair = 0
	if _in_pair == 0:
		_f._gpu.set_step_probe(Callable())
		return
	_f._gpu.set_step_probe(Callable(self, "on_checkpoint"))


## The between-pass probe. `pass_index` -1 = before any pass ran; otherwise the index of the pass that just
## finished, with `pass_name` its script basename. The device has just been synced.
func on_checkpoint(pass_index: int, pass_name: String) -> void:
	if pass_index < 0:
		_done = {}
		_legs = {}
		_parts = {}
		_cum = {}
		var opening: Dictionary = _sample()
		_start = opening.duplicate()
		_prev = opening.duplicate()
		return
	# The producer's OUTPUT is what a checkpoint taken after it must read, so the half flips here.
	_done[pass_name] = true
	var now: Dictionary = _sample()
	if now.is_empty():
		return
	var key: String = _leg_key(pass_name)
	for name in now:
		var d: Dictionary = _legs.get(name, {})
		d[key] = float(now[name]) - float(_prev.get(name, 0.0))
		_legs[name] = d
	_prev = now


## Called once per field step AFTER _gpu.step(). Prints the sampled step's budget; a no-op otherwise.
func post_step() -> void:
	if _in_pair == 0:
		return
	var marker: String = String(_rec.get("marker", ""))
	var out: Dictionary = {"field_step": _step_index(), "pair": _in_pair}
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
		out[key] = float(_prev.get(pair[0], 0.0)) - float(_prev.get(pair[1], 0.0))
	for scalar in _rec.get("parts", {}):
		out[String(_rec["parts"][scalar])] = _parts.get(scalar, {})
	var res: Dictionary = _rec.get("resolution", {})
	var floor_v: float = 0.0
	if not res.is_empty():
		floor_v = _resolution(String(res["scalar"]))
		out[String(res["key"])] = floor_v
	var silent: PackedStringArray = _rec.get("silent_heat", PackedStringArray())
	if silent.size() > 0:
		var violations: PackedStringArray = _silent_violations(silent, floor_v)
		if violations.size() > 0:
			out["INSTRUMENT_WRONG_silent_pass_moved_heat"] = violations
	_pair_end = _prev.duplicate()
	print(marker, "=", JSON.stringify(out))
	_clear_step()


# --- report ---------------------------------------------------------------------------------------

func _publish_row(out: Dictionary, row: Dictionary) -> void:
	var scalar: String = String(row["scalar"])
	var value: float = float(_prev.get(scalar, 0.0))
	var opened: float = float(_start.get(scalar, 0.0))
	if row.has("total"):
		out[String(row["total"])] = value
	if row.has("step"):
		out[String(row["step"])] = value - opened
	if row.has("legs"):
		out[String(row["legs"])] = _legs.get(scalar, {})
	if row.has("residual"):
		var against: Array = row["residual_of"] if row.has("residual_of") else [scalar]
		var booked: float = 0.0
		for other in against:
			booked += _leg_sum(String(other))
		out[String(row["residual"])] = (value - opened) - booked
	# The instrument's falsifiable number: this step opened where the previous one closed.
	if row.has("chain") and _in_pair == 2 and _pair_end.has(scalar):
		out[String(row["chain"])] = opened - float(_pair_end[scalar])


func _leg_sum(scalar: String) -> float:
	var acc: float = 0.0
	for k in _legs.get(scalar, {}):
		acc += float(_legs[scalar][k])
	return acc


## Absolute resolution of a difference of two float32 readback sums, in the scalar's own units.
func _resolution(scalar: String) -> float:
	var cc: int = _f._cell_count if _f != null else 0
	return LAMaterialFieldConservation3D.noise_floor(cc) * absf(float(_prev.get(scalar, 0.0)))


## Passes that bind no writable temp buffer and yet carry a heat leg the readback can resolve.
func _silent_violations(silent: PackedStringArray, floor_v: float) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var legs: Dictionary = _legs.get("heat", {})
	for k in legs:
		if silent.has(String(k)) and absf(float(legs[k])) >= floor_v:
			out.append(String(k))
	return out


func _clear_step() -> void:
	_legs = {}
	_parts = {}


# --- sampling -------------------------------------------------------------------------------------

## One checkpoint. Returns the record's scalars, or an empty dictionary when a channel did not arrive.
func _sample() -> Dictionary:
	var gpu = _f._gpu
	var cc: int = _f._cell_count
	var phase: int = gpu.probe_phase()
	var channels: PackedStringArray = _rec["channels"]
	var energy: bool = bool(_rec["energy"])
	var ch: Dictionary = {}
	for name in channels:
		ch[name] = gpu.read_raw(name, _half(String(name), phase))
	var temp: PackedFloat32Array = PackedFloat32Array()
	if energy:
		# The stock is enthalpy; temperature is derived and books nothing.
		ch["h_j_m3"] = gpu.read_raw("h_j_m3", _half("h_j_m3", phase))
		temp = gpu.read_raw("temp", 0)
	var f: Dictionary = _fold.amounts(ch, _mask(gpu.read_raw("solid", 0), cc), temp, energy)
	if f.is_empty():
		_missing = PackedStringArray(["solid"])
		return {}
	var live: Dictionary = f["live"]
	var absent: PackedStringArray = PackedStringArray()
	for name in channels:
		if not bool(live.get(name, false)):
			absent.append(String(name))
	if energy and int(ch.get("h_j_m3", PackedFloat32Array()).size()) < cc and not absent.has("h_j_m3"):
		absent.append("h_j_m3")
	_missing = absent
	if absent.size() > 0:
		return {}
	if energy:
		return _energy_scalars(f)
	return _mass_scalars(f, channels)


func _mass_scalars(f: Dictionary, channels: PackedStringArray) -> Dictionary:
	var open_by: Dictionary = f["open"]
	var all_by: Dictionary = f["all"]
	var open_parts: Dictionary = {}
	var all_parts: Dictionary = {}
	for name in channels:
		open_parts[name] = float(open_by[name])
		all_parts[name] = float(all_by[name])
	all_parts["solid_cells"] = f["solid_cells"]
	_parts = {"open": open_parts, "all": all_parts}
	return {"open": LAFieldLedgerRecords.sum_of(open_by, channels),
		"all": LAFieldLedgerRecords.sum_of(all_by, channels)}


## The stock is the enthalpy the cells hold. There is no heat/capacity split to take: that decomposition
## existed only to separate "temperature moved" from "the capacity mix moved", and with h as the state
## there is no capacity mix.
func _energy_scalars(f: Dictionary) -> Dictionary:
	return {"stock": float(f["energy_stock"])}


## Which ping-pong half a channel's current data sits in, given which passes have already run this step.
func _half(name: String, phase: int) -> int:
	var producer: String = String(LAFieldAttributionRecords.PRODUCERS.get(name, ""))
	if producer != "" and _done.has(producer):
		return 1 - phase
	return phase


func _mask(solid: PackedFloat32Array, cc: int) -> PackedByteArray:
	var out: PackedByteArray = PackedByteArray()
	if solid.size() < cc:
		return out
	out.resize(cc)
	for c in cc:
		out[c] = 1 if solid[c] != 0.0 else 0
	return out


## Short leg label: "WaterSlumpLavaPass" -> "water_slump_lava".
func _leg_key(pass_name: String) -> String:
	var s: String = pass_name
	if s.ends_with("Pass"):
		s = s.substr(0, s.length() - 4)
	return s.to_snake_case()


func _step_index() -> int:
	var gpu = _f._gpu
	return int(gpu._step_index) if gpu != null else -1
