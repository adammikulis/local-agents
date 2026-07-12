class_name LAMaterialCharge3D
extends RefCounted

## LAMaterialCharge3D — the CHARGE→BOLT firing of LAMaterialField3D, factored into its own module (the field
## only forwards). The charge FIELD already accumulates on the GPU (charge_accum_sphere3d, wired in GasWindPass):
## charge separates where a convective updraft lofts supercooled cloud. This module owns the DISCHARGE half —
## after each readback it looks for cells whose charge has crossed the dielectric BREAKDOWN threshold and FIRES
## A BOLT there: it injects a heat pulse at the strike (so a bolt can ignite fuel — emergent wildfire), zeroes
## the cell's charge (the discharge, re-uploaded next step), counts the strike, and calls the registered VISUAL
## callback (the LightningStrike actor / thunder). This is the substrate primitive Thunderstorm DISSOLVES into:
## the storm becomes a moisture/heat SEED, and lightning falls out of the field's own charge physics.
##
## Big-O / relevance: breakdown is not a per-frame full-grid sweep. A cheap STRIDED probe first asks "is any
## region charged at all?"; the full breakdown scan runs ONLY when the probe sees charge climbing (a bubble in
## time — charge exists only under an active storm, which is rare). Holds no field state; reaches into `_f`.
## (Explicit types only — no ':=' inferred typing.)

# Charge at which a cell breaks down and fires a bolt. Reachable by a mature storm's accumulation OR a direct
# add_charge seed. Tuned against charge_accum's CHARGE_GAIN=8 so a sustained updraft×cloud×cold reaches it.
const BREAKDOWN: float = 6.0
# After firing, the cell's charge is knocked down to this (a near-full discharge) so it must recharge before
# it can strike again — a natural per-cell cooldown, no timer.
const RESIDUAL_AFTER_BOLT: float = 0.1
# Heat dumped at the strike point (°C spike over STRIKE_HEAT_R) — enough to cross fuel's ignition temp.
const STRIKE_HEAT: float = 900.0
const STRIKE_HEAT_R: float = 10.0
# Cap bolts fired per step so a broad charged sheet can't dump hundreds of strikes in one frame (visual + perf).
const MAX_BOLTS_PER_STEP: int = 4
# Strided-probe gate: only run the full breakdown scan when the strided max is at least this fraction of
# BREAKDOWN (charge is spatially broad, so a coarse stride still catches a charged region).
const PROBE_STRIDE: int = 64
const PROBE_GATE: float = 0.5
# The strided probe has a blind spot: GPU-grown charge can cross BREAKDOWN in a cell the stride skips, and
# `_charge_woke` is only set by explicit injection — so a NATURAL storm's charge never trips the gate and no
# bolt fires. Guarantee detection with a coarse-cadence FORCED full scan: at least once every FULL_SCAN_EVERY
# frames run the full 127K-cell pass regardless of the probe. It's amortized and cheap in practice — charge is
# ~0 everywhere except under an active storm, which is rare — so this is one full sweep per ~20 quiescent frames.
const FULL_SCAN_EVERY: int = 20

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _visual: Callable = Callable()                       # bolt visual/audio callback (VoxelDisasters.spawn_lightning)
var _bolts: int = 0                                      # cumulative bolts fired (bolts_fired diagnostic)
var _charge_peak: float = 0.0                            # cached peak charge (charge_peak diagnostic)
var _since_full: int = 0                                 # frames since the last full breakdown scan (forced cadence)


func setup(field) -> void:
	_f = field


## Register the bolt VISUAL/audio callback (a Callable taking the strike world position).
func set_visual(cb: Callable) -> void:
	_visual = cb


## Run once per step after the charge readback. Probe → (if charged) full breakdown scan → fire bolts.
func post_step() -> void:
	if _f._charge.size() != _f._cell_count:
		return
	# Cheap strided probe: is any region charged enough to bother scanning? (Also refreshes the peak estimate.)
	var probe_max: float = 0.0
	var c: int = 0
	while c < _f._cell_count:
		if _f._charge[c] > probe_max:
			probe_max = _f._charge[c]
		c += PROBE_STRIDE
	_charge_peak = probe_max
	# Scan when the probe sees charge climbing OR when an injection explicitly woke us (a small injected blob can
	# slip between the strided probe's samples) OR when the forced-cadence timer is due (catches GPU-grown charge
	# the strided probe blind-spots past — the natural-storm case). Otherwise skip — the common, quiescent case.
	_since_full += 1
	var force_full: bool = _since_full >= FULL_SCAN_EVERY
	if probe_max < BREAKDOWN * PROBE_GATE and not _f._charge_woke and not force_full:
		return
	_since_full = 0
	# A region is charging: full scan for cells at/over breakdown, fire up to MAX_BOLTS_PER_STEP of the strongest.
	var fired: int = 0
	var discharged: bool = false
	var true_peak: float = 0.0
	for cc in _f._cell_count:
		var q: float = _f._charge[cc]
		if q > true_peak:
			true_peak = q
		if q < BREAKDOWN or _f._solid[cc] != 0:
			continue
		if fired >= MAX_BOLTS_PER_STEP:
			continue
		_fire_bolt(cc)
		_f._charge[cc] = RESIDUAL_AFTER_BOLT
		discharged = true
		fired += 1
	_charge_peak = true_peak
	# Stay awake while charge still lingers near breakdown; sleep once it has drained (skip the scan again).
	_f._charge_woke = true_peak >= BREAKDOWN * PROBE_GATE
	if discharged:
		_f._charge_dirty = true                           # push the discharge back to the GPU next step


# Fire one bolt at cell `cc`: inject the heat pulse (ignition), count it, and call the visual/audio callback.
func _fire_bolt(cc: int) -> void:
	var pos: Vector3 = _f.cell_world_pos_linear(cc)
	_bolts += 1
	if _f._inject != null:
		_f._inject.add_heat(pos, STRIKE_HEAT, STRIKE_HEAT_R)
	if _visual.is_valid():
		_visual.call(pos)


func bolts_fired() -> int:
	return _bolts


func charge_peak() -> float:
	return _charge_peak
