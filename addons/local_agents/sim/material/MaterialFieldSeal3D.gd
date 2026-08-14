class_name LAMaterialFieldSeal3D
extends RefCounted

const SampleScript: GDScript = preload("res://addons/local_agents/sim/material/FieldStepSample3D.gd")


enum Phase { SEEDING = 0, SEALED = 1 }

## Every channel a conservation baseline reads.
static func required_channels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for name in ["h_j_m3", "porosity", "co2", "o2", "fert", "n2"]:
		if not out.has(name):
			out.append(name)
	return out

var _f = null
var _phase: int = Phase.SEEDING
var _seal_step: int = -1
var _waiting_on: PackedStringArray = PackedStringArray()
## "seeded" (this run closed its own books) or "restored" (a bake carried the seal in).
var _origin: String = "unsealed"
## What the world was handed at the seal, filled by `note_seed()`.
var _manifest: Dictionary = {}
var _latched: bool = false
var _baseline_step: int = -1
## What was created while seeding, and what tried to be created after the seal.
var _created: Dictionary = {}
var _refused: Dictionary = {}


func setup(field) -> void:
	_f = field


func sealed() -> bool:
	return _phase == Phase.SEALED


## THE TWO PHASES OF THE WORLD, and the only place the boundary is decided.
func creation_allowed() -> bool:
	return _phase == Phase.SEEDING


## Declare an act that CREATES matter or energy.
func note_creation(what: String, amount: float) -> bool:
	if _phase == Phase.SEEDING:
		_created[what] = float(_created.get(what, 0.0)) + amount
		return true
	_refused[what] = int(_refused.get(what, 0)) + 1
	push_error("CREATION_AFTER_SEAL: '%s' tried to create %f after the world sealed at step %d. "
		% [what, amount, _seal_step]
		+ "After the seal matter and energy may only be moved or transformed. Source it from a real store, "
		+ "or move the call into the seeding phase.")
	return false


func seal_step() -> int:
	return _seal_step


## Restoring a snapshot: seal at the step it carried, rather than re-seeding matter already accounted for.
func seal_restored(step_index: int) -> void:
	_phase = Phase.SEALED
	_seal_step = step_index
	_waiting_on = PackedStringArray()
	_origin = "restored"


## Called once per field step, right after the readback.
func poll(legs: Dictionary) -> bool:
	if _latched:
		return false
	if _f == null or not _f._ready_sim:
		return false
	var cc: int = _f._cell_count
	if cc <= 0:
		return false
	var missing: PackedStringArray = PackedStringArray()
	for name in required_channels():
		if not channel_live(_f, name, legs, cc):
			missing.append(name)
	_waiting_on = missing
	if not missing.is_empty():
		if _f._gpu != null and _f._gpu.has_method("request_probe"):
			_f._gpu.request_probe(missing)
		return false
	if _phase != Phase.SEALED:
		_phase = Phase.SEALED
		_seal_step = SampleScript.field_step(_f)
		_origin = "seeded"
	_latch_baselines()
	return true


## One instrument pass on the sealing step, so every ledger's `*_first` is the state at the seal.
func _latch_baselines() -> void:
	_latched = true
	_baseline_step = SampleScript.field_step(_f)
	var rep = _f._report_mod
	if rep != null:
		rep._heavy_frame = -1_000_000
		rep._heavy_block()


func note_seed(totals: Dictionary) -> void:
	for k in totals:
		var v = totals[k]
		if v == null:
			continue
		if not _manifest.has(k) or _manifest[k] == null:
			_manifest[k] = v


## True when this sample's `name` is a MEASUREMENT: the probe delivered it, or the readback refreshes it.
static func channel_live(field, name: String, legs: Dictionary, cc: int) -> bool:
	var probe = legs.get(name)
	if probe is PackedFloat32Array and probe.size() >= cc:
		return true
	if gated(field, name):
		return false
	var mirror = field.get("_" + name) if field != null else null
	return mirror is PackedFloat32Array and mirror.size() >= cc


## Channels whose CPU mirror is not a measurement.
static func gated(field, name: String) -> bool:
	if name == "carbonate" or name == "silica" or name == "n2":
		return true
	var gpu = field._gpu if field != null else null
	if gpu == null:
		return true
	return gpu.situational_channels().has(name)


func report() -> Dictionary:
	return {
		"world_sealed": _phase == Phase.SEALED,
		"world_seal_step": _seal_step,
		"world_seal_origin": _origin,
		# Field step every `*_first` baseline was taken on. -1 means no ledger has a baseline.
		"world_baseline_step": _baseline_step,
		# Channels the seal is still waiting for. Empty once latched.
		"world_seal_waiting": _waiting_on,
		# What the planet was handed at the seal; every entry is a mechanism the substrate does not have.
		"world_seed": _manifest,
		# Declared creations during the seeding phase, per kind. Legitimate: the world had nothing yet.
		"world_created": _created,
		# Creations REFUSED after the seal, per kind.
		"creation_after_seal": _refused,
	}
