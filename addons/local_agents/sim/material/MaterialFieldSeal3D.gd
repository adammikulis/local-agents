class_name LAMaterialFieldSeal3D
extends RefCounted


enum Phase { SEEDING = 0, SEALED = 1 }

static func required_channels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for name in LAHeatCapacity.channels():
		out.append(name)
	for name in ["porosity", "temp", "co2", "o2", "fert"]:
		if not out.has(name):
			out.append(name)
	return out

var _f = null
var _phase: int = Phase.SEEDING
var _seal_step: int = -1
var _waiting_on: PackedStringArray = PackedStringArray()
## Set when a bake was restored, so `world_seal_origin` can say WHY the world is sealed. A run that sealed
## itself and a run that inherited a seal are different provenance, and a reader comparing two runs needs to
## know which they have.
var _origin: String = "unsealed"
## What the world was HANDED, captured at the instant the books closed. Not a diagnostic: it is the list of
## things the simulation did not have to produce, and the goal is for it to shrink. Filled by `note_seed()`.
var _manifest: Dictionary = {}


func setup(field) -> void:
	_f = field


func sealed() -> bool:
	return _phase == Phase.SEALED


func seal_step() -> int:
	return _seal_step


## Restoring a snapshot: the matter in it was seeded once already, in the run that produced it. Seal at the
## step the snapshot carried rather than re-running a seeding phase over matter that is already accounted for.
func seal_restored(step_index: int) -> void:
	_phase = Phase.SEALED
	_seal_step = step_index
	_waiting_on = PackedStringArray()
	_origin = "restored"


func poll(legs: Dictionary) -> bool:
	if _phase == Phase.SEALED:
		return false
	if _f == null or not _f._ready_sim:
		return false
	var cc: int = _f._cell_count
	if cc <= 0:
		return false
	var missing: PackedStringArray = PackedStringArray()
	for name in required_channels():
		if not _channel_live(name, legs, cc):
			missing.append(name)
	_waiting_on = missing
	if not missing.is_empty():
		if _f._gpu != null and _f._gpu.has_method("request_probe"):
			_f._gpu.request_probe(missing)
		return false
	_phase = Phase.SEALED
	_seal_step = _step_index()
	_origin = "seeded"
	return true


func note_seed(totals: Dictionary) -> void:
	for k in totals:
		var v = totals[k]
		if v == null:
			continue
		if not _manifest.has(k) or _manifest[k] == null:
			_manifest[k] = v


func _channel_live(name: String, legs: Dictionary, cc: int) -> bool:
	var probe = legs.get(name)
	if probe is PackedFloat32Array and probe.size() >= cc:
		return true
	if _gated(name):
		return false
	var mirror = _f.get("_" + name)
	return mirror is PackedFloat32Array and mirror.size() >= cc


## Demand-gated or mirror-less channels, which a full-size all-zero mirror can impersonate.
func _gated(name: String) -> bool:
	if name == "carbonate" or name == "silica":
		return true          # no CPU mirror exists at all, by design
	var gpu = _f._gpu
	if gpu == null:
		return true
	return gpu.SITUATIONAL_CHANNELS.has(name)


func report() -> Dictionary:
	return {
		"world_sealed": _phase == Phase.SEALED,
		"world_seal_step": _seal_step,
		"world_seal_origin": _origin,
		# What the seal is still waiting for. Empty once sealed. A run that never seals publishes the exact
		# channel that never arrived, instead of leaving the reader to guess why every drift gauge is blank.
		"world_seal_waiting": _waiting_on,
		# WHAT THE PLANET WAS HANDED. Every entry is a mechanism the substrate does not yet have; the bar is
		# a post-Theia seed (a molten body and a composition) with the ocean, the air and the crust all
		# emerging, so this shrinking is the measure of progress. See the header.
		"world_seed": _manifest,
	}


func _step_index() -> int:
	var gpu = _f._gpu
	return int(gpu._step_index) if gpu != null else -1
