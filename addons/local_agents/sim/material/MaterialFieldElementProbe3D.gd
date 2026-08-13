class_name LAMaterialFieldElementProbe3D
extends RefCounted

const CellVolScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCellVolume3D.gd")
const RecordsScript: GDScript = preload("res://addons/local_agents/sim/material/FieldLedgerRecords3D.gd")
const SampleScript: GDScript = preload("res://addons/local_agents/sim/material/FieldStepSample3D.gd")

## Per-pass attribution for an ELEMENT, in moles. `LA_ELEMENT_BUDGET=C`; comma-separate for several, `all`
## for every element any channel carries. Moles come from LAFieldLedgerRecords.elements_of.

var _f = null
var _elements: PackedStringArray = PackedStringArray()
var _channels: PackedStringArray = PackedStringArray()
var _sched = null                  # LAFieldStepSample3D: which steps are checkpointed

var _done: Dictionary = {}         # pass name -> true once it has run this step (drives the half map)
var _prev_all: Dictionary = {}     # element -> moles at the previous checkpoint
var _prev_open: Dictionary = {}
var _start_all: Dictionary = {}
var _start_open: Dictionary = {}
var _legs_all: Dictionary = {}     # pass key -> {element: moles moved}
var _legs_open: Dictionary = {}
var _parts_all: Dictionary = {}    # closing per-channel amount, for reading the SHAPE of a gain or loss
var _prev_parts: Dictionary = {}   # per-channel amount at the previous checkpoint
var _legs_parts: Dictionary = {}   # pass key -> {channel: units moved} — WHICH channel the pass moved
var _pair_end_all: Dictionary = {} # closing totals of the pair's first step, so the second reports `chain`


func setup(field) -> void:
	_f = field
	var want: String = OS.get_environment("LA_ELEMENT_BUDGET")
	if want == "":
		return
	var every: String = OS.get_environment("LA_ELEMENT_BUDGET_EVERY")
	var cadence: int = maxi(1, int(every)) if every != "" else SampleScript.SAMPLE_EVERY
	if want == "all" or want == "1":
		_elements = LAReactionBalance.all_elements()
	else:
		for part in want.split(",", false):
			var el: String = part.strip_edges()
			if el != "" and not _elements.has(el):
				_elements.append(el)
	for el in _elements:
		for ch in LAReactionBalance.channels_with(el):
			if not _channels.has(ch):
				_channels.append(ch)
	if _channels.is_empty():
		push_warning("LA_ELEMENT_BUDGET=%s names no element any channel carries — probe disarmed." % want)
		_elements = PackedStringArray()
		return
	_sched = SampleScript.new()
	_sched.setup(field, cadence)


func armed() -> bool:
	return not _channels.is_empty()


## Called once per field step BEFORE _gpu.step().
func pre_step() -> void:
	if _sched == null:
		return
	if _sched.arm(Callable(self, "on_checkpoint")):
		_pair_end_all = {}


## `pass_index` -1 = before any pass ran; otherwise the index of the pass that just finished. The device has
## just been synced when this is called.
func on_checkpoint(pass_index: int, pass_name: String) -> void:
	if pass_index < 0:
		_done = {}
		_legs_all = {}
		_legs_open = {}
		_legs_parts = {}
		var opening: Array = _sample()
		_start_all = opening[0].duplicate()
		_start_open = opening[1].duplicate()
		_prev_all = opening[0]
		_prev_open = opening[1]
		_prev_parts = opening[2]
		return
	# The producer's OUTPUT is what a checkpoint taken after it must read, so the half flips HERE, not before.
	_done[pass_name] = true
	var now: Array = _sample()
	var key: String = SampleScript.leg_key(pass_name)
	_legs_all[key] = _delta(now[0], _prev_all)
	_legs_open[key] = _delta(now[1], _prev_open)
	var moved: Dictionary = {}
	for ch in now[2]:
		var d: float = float(now[2][ch]) - float(_prev_parts.get(ch, 0.0))
		if d != 0.0:
			moved[ch] = d
	_legs_parts[key] = moved
	_prev_all = now[0]
	_prev_open = now[1]
	_prev_parts = now[2]
	_parts_all = now[2]


## Called once per field step AFTER _gpu.step(). Prints the sampled step's budget; a no-op otherwise.
func post_step() -> void:
	if _sched == null or _sched.pair() == 0 or _legs_all.is_empty():
		return
	var step_all: Dictionary = _delta(_prev_all, _start_all)
	var step_open: Dictionary = _delta(_prev_open, _start_open)
	var out: Dictionary = {
		"elements": _elements,
		"channels": _channels,
		"all": _prev_all,
		"open": _prev_open,
		"step_all": step_all,
		"step_open": step_open,
		"legs_all": _legs_all,
		"legs_open": _legs_open,
		"legs_parts": _legs_parts,
		"parts_all": _parts_all,
	}
	if _sched.pair() == 2 and not _pair_end_all.is_empty():
		# The instrument's falsifiable number: this step opened where the previous one closed, or the half map
		# above is wrong.
		out["chain_all"] = _delta(_start_all, _pair_end_all)
	_pair_end_all = _prev_all.duplicate()
	_sched.publish("ELEMENT_BUDGET", out)
	_legs_all = {}
	_legs_open = {}
	_legs_parts = {}


# --- internals ----------------------------------------------------------------

## Moles of every requested element right now, mask-free and over open cells, plus the per-channel amounts.
## Returns [all, open, parts_all].
func _sample() -> Array:
	var gpu = _f._gpu
	var cc: int = _f._cell_count
	var vol: PackedFloat32Array = CellVolScript.of(_f)
	if vol.size() != cc:
		return [{}, {}, {}]
	var solid: PackedFloat32Array = gpu.read_raw("solid", 0)
	var has_solid: bool = solid.size() >= cc
	var phase: int = gpu.probe_phase()
	var all_by_channel: Dictionary = {}
	var open_by_channel: Dictionary = {}
	for ch in _channels:
		var a: PackedFloat32Array = _read(gpu, ch, phase)
		if a.size() < cc:
			continue
		var t_all: float = 0.0
		var t_open: float = 0.0
		for c in cc:
			var v: float = a[c] * vol[c]
			t_all += v
			if (not has_solid) or solid[c] == 0.0:
				t_open += v
		all_by_channel[ch] = t_all
		open_by_channel[ch] = t_open
	var parts: Dictionary = {}
	for ch in all_by_channel:
		parts[ch] = all_by_channel[ch]
	return [_only(RecordsScript.elements_of(all_by_channel)),
		_only(RecordsScript.elements_of(open_by_channel)), parts]


## Read one channel at the half that is current given which passes have already run this step.
func _read(gpu, name: String, phase: int) -> PackedFloat32Array:
	if gpu.single_channels().has(name):
		return gpu.read_raw(name, 0)
	var producer: String = String(LAFieldAttributionRecords.PRODUCERS.get(name, ""))
	var half: int = (1 - phase) if (producer != "" and _done.has(producer)) else phase
	return gpu.read_raw(name, half)


## Drop every element the run did not ask for, so a carbon probe does not print the whole periodic table.
func _only(elements: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for el in _elements:
		out[el] = float(elements.get(el, 0.0))
	return out


func _delta(now: Dictionary, before: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for el in _elements:
		out[el] = float(now.get(el, 0.0)) - float(before.get(el, 0.0))
	return out
