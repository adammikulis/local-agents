class_name LAMaterialFieldSeal3D
extends RefCounted


enum Phase { SEEDING = 0, SEALED = 1 }

## Every channel a conservation baseline reads. The seal waits for all of them, so the baselines it latches
## are measurements rather than mirrors that had not arrived.
static func required_channels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for name in LAHeatCapacity.channels():
		out.append(name)
	for name in ["porosity", "temp", "co2", "o2", "fert", "n2"]:
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
##
## SEEDING: the world is being built. Matter and energy may be CREATED, because they are being handed to a
## planet that does not have them yet. Every such act is recorded in `world_seed`, which is the scoreboard of
## what the substrate was TOLD rather than worked out.
##
## SEALED: the world exists. Matter and energy may only be MOVED or TRANSFORMED. Creating either is a
## violation, not a modelling choice, and no flag, mode or environment variable may re-enable it.
func creation_allowed() -> bool:
	return _phase == Phase.SEEDING


## Declare an act that CREATES matter or energy. Returns true only while seeding; after the seal it refuses,
## errors, and counts the attempt into `creation_after_seal`. A caller that ignores the return value has
## written the violation anyway, which is what `scripts/check_seed_phase.sh` exists to catch.
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


## Field step every conservation baseline was taken on. -1 until the seal has driven the latch.
func baseline_step() -> int:
	return _baseline_step


## Restoring a snapshot: seal at the step it carried, rather than re-seeding matter already accounted for.
func seal_restored(step_index: int) -> void:
	_phase = Phase.SEALED
	_seal_step = step_index
	_waiting_on = PackedStringArray()
	_origin = "restored"


## Called once per field step, right after the readback. Seals when every required channel is live and
## latches every baseline on that step. True on the latching step.
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
		_seal_step = _step_index()
		_origin = "seeded"
	_latch_baselines()
	return true


## One instrument pass on the sealing step, so every ledger's `*_first` is the state at the seal. The gauge
## cache is dropped first, else the 64-frame cadence returns a pre-seal block.
func _latch_baselines() -> void:
	_latched = true
	_baseline_step = _step_index()
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
## The one provenance predicate — every ledger's `*_live` map calls this.
static func channel_live(field, name: String, legs: Dictionary, cc: int) -> bool:
	var probe = legs.get(name)
	if probe is PackedFloat32Array and probe.size() >= cc:
		return true
	if gated(field, name):
		return false
	var mirror = field.get("_" + name) if field != null else null
	return mirror is PackedFloat32Array and mirror.size() >= cc


## Channels whose CPU mirror is not a measurement: carbonate/silica have none, n2 has one the readback never
## refreshes, and the demand-gated set is stale until requested. These must come from the probe.
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
		# Creations REFUSED after the seal, per kind. Any non-empty value is a conservation violation that
		# reached a call site; the refusal stopped the write, not the defect.
		"creation_after_seal": _refused,
	}


func _step_index() -> int:
	var gpu = _f._gpu
	return int(gpu._step_index) if gpu != null else -1
