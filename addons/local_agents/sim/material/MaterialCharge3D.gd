class_name LAMaterialCharge3D
extends RefCounted

## LAMaterialCharge3D: the CHARGE→BOLT firing of LAMaterialField3D, factored into its own module (the field

const BREAKDOWN: float = 8.0
# After firing, charge is knocked down to this (a near-full discharge) so a cell must recharge before it can
# strike again — a natural cooldown, no timer.
const RESIDUAL_AFTER_BOLT: float = 0.1
# A bolt drains the capacitor over a NEIGHBOURHOOD, not just the leader cell: the struck storm core goes flat
# and must fully rebuild before re-firing. Draining only the single cell left its still-charged neighbours at
# breakdown to re-fire next step (the firehose). Radius spans the convective charged core (~a few cells).
const DEPLETE_R: float = 22.0
# nothing: the field lost its electrostatic store AND gained heat that no store paid for.
const J_PER_CHARGE: float = LAPhysical.LIGHTNING_FLASH_J / BREAKDOWN
# The energy goes into the volume the discharge actually spanned — the charged core it drained — not into a
# separate, smaller blob at the leader cell. A real return stroke heats its whole channel, and using the same
# radius for the debit and the credit is what makes the two sides describe one event.
const STRIKE_HEAT_R: float = DEPLETE_R
# Cap bolts fired per step so a broad charged sheet can't dump hundreds of strikes in one frame (visual + perf).
const MAX_BOLTS_PER_STEP: int = 4
# Strided-probe gate: only run the full breakdown scan when the strided max is at least this fraction of
# BREAKDOWN (charge is spatially broad, so a coarse stride still catches a charged region).
const PROBE_STRIDE: int = 64
const PROBE_GATE: float = 0.5
const FULL_SCAN_EVERY: int = 20

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _visual: Callable = Callable()                       # bolt visual/audio callback (VoxelDisasters.spawn_lightning)
var _bolts: int = 0                                      # cumulative bolts fired (bolts_fired diagnostic)
var _charge_peak: float = 0.0                            # cached peak charge (charge_peak diagnostic)
var _since_full: int = 0                                 # frames since the last full breakdown scan (forced cadence)
var _bolt_energy_j: float = 0.0                          # cumulative electrostatic energy converted to heat (J)


## Cumulative energy this module has taken out of the charge channel and handed to the temperature field. It
## is a diagnostic AND a conservation check: it can only ever be `drained charge x J_PER_CHARGE`, so if it
## rises while `charge_peak` never does, something is crediting heat without a discharge behind it.
func bolt_energy_j() -> float:
	return _bolt_energy_j


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
		discharged = true
		fired += 1
	_charge_peak = true_peak
	# Stay awake while charge still lingers near breakdown; sleep once it has drained (skip the scan again).
	_f._charge_woke = true_peak >= BREAKDOWN * PROBE_GATE
	# No dirty flag: _fire_bolt drains through MaterialFieldInject3D.deplete_charge, which queues a sparse
	# negative delta against the live buffer.


func _fire_bolt(cc: int) -> void:
	var pos: Vector3 = _f.cell_world_pos_linear(cc)
	_bolts += 1
	if _f._inject != null:
		var drained: float = _f._inject.deplete_charge(pos, DEPLETE_R, RESIDUAL_AFTER_BOLT)
		_bolt_energy_j += drained * J_PER_CHARGE
		if drained > 0.0:
			_f._inject.add_heat_energy(pos, drained * J_PER_CHARGE, STRIKE_HEAT_R)
	else:
		_f._charge[cc] = RESIDUAL_AFTER_BOLT
	if _visual.is_valid():
		_visual.call(pos)


func bolts_fired() -> int:
	return _bolts


func charge_peak() -> float:
	return _charge_peak
