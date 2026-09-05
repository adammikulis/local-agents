class_name LAMaterialFieldSeal3D
extends RefCounted

const SampleScript: GDScript = preload("res://addons/local_agents/sim/material/FieldStepSample3D.gd")


enum Phase { SEEDING = 0, SEALED = 1 }

## Every channel a conservation baseline reads.
static func required_channels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for name in ["e_j_m3", "e_lith_j_m3", "porosity", "co2", "o2", "n2"]:
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
		if _origin == "unsealed":
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


## A bake carried the seal in. The world was handed this matter once, by the run that baked it, so its
## declarations travel with the state rather than being forgotten on the way back in.
func restore(created: Dictionary) -> void:
	_created = created.duplicate(true)
	_origin = "restored"



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
	return field != null and field._mirrors != null and field._mirrors.cells() >= cc \
		and field._mirrors.has(name)


## Channels whose CPU mirror is not a measurement: one the readback never refreshes holds whatever the
## seed left in it, so only the probe can say it is live.
static func gated(field, name: String) -> bool:
	if field == null or field._mirrors == null or not field._mirrors.has(name):
		return true
	return LAChannels.situational_channels().has(name)


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
