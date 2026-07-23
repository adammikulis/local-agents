class_name LAMaterialSurfaceSeed3D
extends RefCounted

## LAMaterialSurfaceSeed3D — seeds + maintains the GROUND-SURFACE substrate channels of LAMaterialField3D that
## are otherwise allocated to zeros and so never come alive, factored into its own module (the field hub only
## wires + forwards). Two channels, both "what sits on the ground":
##
##   * FUEL (combustion) — the GPU fire kernel (fire_sphere3d.glsl) GATES on fuel > 0, so a zero-filled fuel
##     channel means combustion can NEVER ignite (no wildfire, no CO₂ from burning, no fuel-driven O₂ draw-down).
##     seed_initial() lays a baseline of flammable vegetation on every open ground-surface cell so a heat source
##     (lightning/lava/meteor) can ignite from frame 0; post_readback() refills it from the emergent LIVING
##     BIOMASS channel on a cadence (that standing vegetation IS the fuel), capped so a burned cell regrows to
##     what its biomass supports — emergent wildfire recovery, no timers. Burned-BARE cells (no biomass) stay
##     ash, so the fuel ledger still falls where fire ran.
##
##   * DETRITUS (decomposer substrate) — real soil holds dead organic matter; a zero-filled detritus channel
##     leaves the detritus→fungus→CO₂+FERTILITY loop with no substrate to bootstrap from (fungus only grows on
##     detritus), so soil fertility stays flat 0 for hundreds of steps until biomass respiration slowly builds
##     it. seed_initial() lays a modest baseline of soil organic matter on the same ground-surface cells so the
##     decomposer runs from the start and the (now read-back) fertility channel actually reflects the loop.
##
## Holds NO field state: it reaches into the owning LAMaterialField3D (`_f`) for the per-cell arrays + the
## sphere neighbour table, exactly as the query/inject/step modules do.
## (Explicit types only — no ':=' inferred typing.)

# Flammable vegetation mass laid on a bare ground-surface cell at activation (over the kernel's FUEL_MIN = 0.02
# so it can ignite; enough to sustain a burn for many steps before it is spent to ash — sized against the
# kernel's actual BURN_RATE = 0.12 (fire_sphere3d.glsl), ~16-17 steps. BUG FIX: this constant used to be 0.4,
# sized against a BURN_RATE = 0.045 that this comment (and PHASE_B3_DESIGN.md's independent reaction inventory)
# still documented — the two drifted apart at some point (BURN_RATE was raised, likely as part of the wildfire-
# lethality balance pass, without updating the fuel that was sized against the old rate), so a tree's fuel was
# only ~3 steps' worth (0.3s sim-time) — burned out almost the instant it ignited. 5x'd to restore a genuinely
# visible burn while keeping BURN_RATE (and the spread/severity tuning that depends on it) untouched.
const BASELINE_FUEL: float = 2.0
# Living-biomass → fuel conversion: a surface cell's standing biomass density scaled into flammable mass. The
# refill TOPS UP a burned cell toward the fuel its standing biomass supports, but is CAPPED at BASELINE_FUEL so
# a cell never holds more than one cell's worth of vegetation — the fuel ledger stays bounded (≤ the seed), so
# a fire's consumption shows as a genuine dip in fuel_total instead of ballooning with the greening biosphere.
const BIOMASS_FUEL_GAIN: float = 1.2
# Refill cadence (GPU field steps between biomass→fuel top-ups). A burning cell spends ~BURN_RATE per step, so
# topping up every N steps (N·BURN_RATE < BASELINE) keeps a standing fire fed by its living vegetation instead
# of self-extinguishing the moment its seed fuel is spent — the fire persists as long as biomass regrows under it.
const REFILL_EVERY: int = 40
# Drains ahead of REFILL_EVERY to start requesting the (demand-gated) fuel channel, so it has already been
# read back fresh by the time the refill below runs -- must be >= the driver's CHANNEL_HOLD_DRAINS (20).
const FUEL_REQUEST_LEAD: int = 20
# Soil organic matter laid on a ground-surface cell at activation — over the fungus kernel's DETRITUS_MIN = 0.05
# so fungus colonises it and the decompose reaction (detritus × fungus → CO₂ + fertility) fires from the start.
const BASELINE_DETRITUS: float = 0.15

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _refill_tick: int = 0


func setup(field) -> void:
	_f = field


## Lay the baseline fuel + soil detritus on every open GROUND-surface cell (open cell whose inward-radial
## neighbour, slot 0, is solid rock — i.e. vegetation/soil sitting on the ground). Marks both channels dirty so
## the hub uploads them next step (detritus is a one-shot substrate seed; fuel is re-uploaded on refill too).
func seed_initial() -> void:
	if _f == null or _f._sphere == null or _f._fuel.size() != _f._cell_count:
		return
	var nbr: PackedInt32Array = _f._sphere.neighbours
	if nbr.size() < _f._cell_count * 6:
		return
	var has_detritus: bool = _f._detritus.size() == _f._cell_count
	for c in _f._cell_count:
		if _f._solid[c] != 0:
			continue
		var down: int = nbr[c * 6 + 0]
		if down >= 0 and _f._solid[down] != 0:
			_f._fuel[c] = BASELINE_FUEL
			if has_detritus:
				_f._detritus[c] = maxf(_f._detritus[c], BASELINE_DETRITUS)
	_f._fuel_dirty = true
	_f._detritus_seed_dirty = has_detritus


## Refill fuel from the emergent biomass channel on the coarse cadence. Run after each readback (biomass + fuel
## are freshly scattered), so a burned cell whose biomass has regrown gets its fuel restored (capped at baseline,
## never lowers). Detritus is NOT refilled here — it is GPU-owned after the one-shot seed (respiration credits it,
## the decompose record debits it), so re-uploading would clobber that on-device evolution.
## fuel is demand-gated (SITUATIONAL_CHANNELS): pre-warm its readback a few drains ahead of REFILL_EVERY so it's
## genuinely fresh by the time this actually reads it below, instead of requesting-and-reading the same drain.
func post_readback() -> void:
	_refill_tick += 1
	if _refill_tick >= REFILL_EVERY - FUEL_REQUEST_LEAD and _f != null and _f._gpu != null:
		_f._gpu.request_channel("fuel")
	if _refill_tick < REFILL_EVERY:
		return
	_refill_tick = 0
	if _f == null or _f._fuel.size() != _f._cell_count or _f._biomass.size() != _f._cell_count:
		return
	for c in _f._cell_count:
		if _f._solid[c] != 0:
			continue
		var from_bio: float = minf(BASELINE_FUEL, _f._biomass[c] * BIOMASS_FUEL_GAIN)
		if from_bio > _f._fuel[c]:
			_f._fuel[c] = from_bio
	_f._fuel_dirty = true
