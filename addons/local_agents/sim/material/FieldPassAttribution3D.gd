class_name LAFieldPassAttribution3D
extends RefCounted

## Between-pass attribution for one conserved substance: which pass changed its total, and by how much.
## A sample sums the halves it downloaded at the checkpoint; the ledger's totals come off the device.

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
	if now.is_empty():
		return
	var key: String = SampleScript.leg_key(pass_name)
	for name in now:
		var d: Dictionary = _legs.get(name, {})
		d[key] = float(now[name]) - float(_prev.get(name, 0.0))
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
	var channels: PackedStringArray = _rec["channels"]
	var energy: bool = bool(_rec["energy"])
	var ch: Dictionary = {}
	for name in channels:
		ch[name] = gpu.read_raw(String(name))
	if energy:
		# The stock is enthalpy; temperature is derived and books nothing.
		ch["h_j_m3"] = gpu.read_raw("h_j_m3")
	var f: Dictionary = _sums(ch, gpu.read_raw("solid"), cc, energy)
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


## Mask-free and open-only amounts of the channels this checkpoint downloaded, in cubic metres of channel.
## One uniform grid, so one volume; `temp` books nothing, the stock is the enthalpy.
func _sums(ch: Dictionary, solid: PackedFloat32Array, cc: int, energy: bool) -> Dictionary:
	if solid.size() < cc:
		return {}
	var m3: float = pow(float(_f._cell_size), 3.0)
	var live: Dictionary = {}
	var all_by: Dictionary = {}
	var open_by: Dictionary = {}
	var solid_cells: int = 0
	for c in cc:
		if solid[c] != 0.0:
			solid_cells += 1
	for name in ch:
		var a: PackedFloat32Array = ch[name]
		live[name] = a.size() == cc
		if a.size() != cc:
			continue
		var s_all: float = 0.0
		var s_open: float = 0.0
		for c in cc:
			var av: float = a[c] * m3
			s_all += av
			if solid[c] == 0.0:
				s_open += av
		all_by[name] = s_all
		open_by[name] = s_open
	var out: Dictionary = {"live": live, "all": all_by, "open": open_by, "solid_cells": solid_cells}
	if energy:
		out["energy_stock"] = float(all_by.get("h_j_m3", 0.0))
	return out




