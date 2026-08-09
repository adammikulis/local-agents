class_name LAMaterialFieldSeal3D
extends RefCounted

## THE WORLD HAS TWO PHASES, AND THIS IS THE LINE BETWEEN THEM.
##
##   SEEDING — matter and energy come into existence. That is not a defect; it is the INITIAL CONDITION,
##             and a planet has to be made of something. Solidity is sampled, the sea is placed, the
##             regolith band and its water table are computed, lakes are flooded, the geotherm is written,
##             the atmosphere is given its gases. Creation here is the whole job.
##
##   SEALED  — the books close and thermodynamics applies. From this instant:
##             * MATTER IS CLOSED. Every conserved substance's mask-free total must equal what it was at
##               the seal, plus whatever booked EXTERNAL input arrived (a meteor is real mass from off-world
##               and is booked as such). No other change is legitimate, in either direction.
##             * ENERGY IS NOT CLOSED, AND MUST NOT BE. Sunlight enters and longwave leaves every step; the
##               geotherm delivers radiogenic heat from a reservoir. The law here is not "the stock does not
##               move" but "every joule of movement is BOOKED to a named source or sink" — i.e.
##               `energy_residual` goes to zero, not `energy_run_drift`. A ledger that demanded a constant
##               energy stock would be demanding a planet with no sun.
##
## WHY THIS EXISTS, and it is not bookkeeping tidiness. Every `*_run_drift` gauge in this repository latches
## its baseline at `_samples > BASELINE_SKIP_SAMPLES`, i.e. the third heavy sample, roughly frame 24. That is
## a SAMPLING artifact with no physical meaning, and it lands in the middle of seeding. Two consequences,
## both measured:
##   1. Seeding is counted AS DRIFT. `carbon_run_drift` reads +1360% of its own baseline over a 600-frame
##      run, which no chemistry can produce; the atmosphere's carbon largely did not exist yet when the
##      baseline was taken.
##   2. A baseline can be taken through a channel that has not arrived. `porosity` is read back on the SLOW
##      cadence, so when it was added, `energy_stock_first` came out BIT-IDENTICAL (1.6727e17) on two arms
##      whose regolith heat capacity differs by 29% — the baseline described a planet that did not exist
##      yet, and the arms could not be compared at all.
## Neither is a leak. Both look exactly like one, which is worse: they hide the real leaks underneath a
## number too large to act on.
##
## THE SEAL CONDITION IS "EVERY BOOK CAN BE OPENED", NOT A FRAME COUNT. A timer would re-introduce the same
## arbitrariness one layer up. The world seals on the first sample where BOTH:
##   * the substrate's own bootstrap has run (`LAMaterialField3D._ready_sim` — solidity, sea, regolith,
##     lakes, activate), and
##   * every channel that holds matter or energy has actually been DELIVERED at least once, so no ledger is
##     latching a baseline through a channel it cannot see.
## The second half is why this owns a channel list rather than a countdown.
##
## A LOADED BAKE SEALS IMMEDIATELY. Restoring a snapshot is not seeding — the matter it describes was seeded
## once, in the run that produced it, and re-counting that as creation would make every bake look like a
## planet being conjured. `seal_restored()` is the entry point for that, and it takes the step index the
## snapshot carried so the seal's provenance survives the round trip.
##
## IT ALSO PUBLISHES THE SEED MANIFEST, AND THAT NUMBER IS THE PROJECT'S SCOREBOARD.
## Everything present at the seal is something the simulation was TOLD rather than something it worked out.
## Today that list is long: a sea is placed, lakes are priority-flooded into basins, a water table is filled
## to a fraction of pore space, a regolith band is declared, the geotherm is written in, the surface starts
## at a chosen temperature and the air starts with its gases already mixed. Every one of those is a partway
## answer standing in for a mechanism.
##
## THE BAR IS A POST-THEIA PLANET. A better substrate needs a smaller assertion, so the direction of travel
## is measured by how much of `world_seed_*` can be DELETED — until the seed is a molten body and a bulk
## composition, ~4.5 Ga, and the ocean, the atmosphere and the crust are all OUTPUTS. The acceptance test is
## not a number looking right: it is that such a planet COOLS, and that water CONDENSES onto its surface,
## without anyone placing a sea. Publishing the manifest is what turns "we should seed less" from an
## intention into a quantity that shows up in every run and can be watched going down.
##
## THIS MODULE CREATES NOTHING, READS NOTHING THE SIMULATION CAN SEE, AND HAS NO OPINION ABOUT PHYSICS.
## It answers one question — has the world been sealed, with what, and at which step — so that everything
## which HAS an opinion can ask it instead of guessing from a sample counter.
## (Explicit types only, no ':=' inferred typing.)

enum Phase { SEEDING = 0, SEALED = 1 }

## Every channel that holds matter or energy, i.e. every channel some conservation ledger reads. The seal
## waits for all of them. Assembled from the ledgers' own leg lists rather than hand-copied:
##   LAHeatCapacity.channels() + porosity  — the energy stock's composition
##   the element inventory's legs          — carbon / oxygen / nitrogen / fertility
##   the mineral budget's legs             — the five silicate phases + the two non-silicate species
##   the H2O ledger's legs                 — water / moisture / snow / soil
## Anything added to one of those and NOT to the model it belongs to is a channel whose matter is invisible;
## that is the defect rc_shared.glsli's header documents at length, and waiting on this list is the cheapest
## place to notice it.
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


## Called once per report. Arms the probe for anything still missing and seals on the first sample where the
## bootstrap has run and every book can be opened. Returns true on the step it seals, so a caller can log it.
##
## IT ARMS `request_probe`, NEVER `request_channel`. Residency is simulation state — waking a mirror changes
## insolation through `avg_atmos_dust` and changes what `add_lava`'s whole-mirror upload rewinds — so a
## module whose entire job is to decide when measurement becomes meaningful must not perturb the thing it is
## waiting for. `request_probe` reads at the drain, into a dictionary no simulation consumer sees.
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


## Record what existed at the seal. Called once, by the report path, with the conserved totals the ledgers
## have just computed — so the manifest is the SAME numbers the drift gauges will measure against, not a
## second sampling of them.
## Entries FILL IN rather than being written once. A ledger that has not latched yet hands null, and the
## manifest takes the first non-null it is offered for each key — so a re-ordering of the report path makes
## an entry LATE instead of permanently null, which is how `h2o` was lost on the first attempt.
func note_seed(totals: Dictionary) -> void:
	for k in totals:
		var v = totals[k]
		if v == null:
			continue
		if not _manifest.has(k) or _manifest[k] == null:
			_manifest[k] = v


## A channel counts as delivered if a read-only probe leg carried it this sample, or its always-hot CPU
## mirror is the right length. A mirror that is merely ALLOCATED is not evidence — LAMaterialField3D resizes
## every mirror to `_cell_count` unconditionally, so a demand-gated channel that never arrived is full-size
## and all-zero. That is precisely why the probe leg is checked FIRST and why the demand-gated names cannot
## be satisfied by their mirrors at all.
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
