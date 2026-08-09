class_name LAMaterialFieldEnergyProbe3D
extends RefCounted

## LAMaterialFieldEnergyProbe3D: a PER-PASS heat budget, so the planet's energy drift has to NAME THE PASS
## that causes it instead of being guessed at. Diagnostic only — created by LAMaterialFieldSphereStep3D and
## only when `LA_ENERGY_BUDGET` is in the environment, because a sampled step costs one CPU↔GPU round-trip
## per pass.
##
## WHY THIS EXISTS. LAMaterialFieldEnergyLedger3D reports ONE number, `energy_run_drift`, and its header lists
## ELEVEN unbooked terms with no way to rank them. Item 11 was picked off that list on judgement, fixed, and
## MOVED THE DRIFT 2.5% — a whole session spent to learn that one term was not the leak. Ten guesses remain.
## The mineral probe already solved this exact shape: eleven of its twelve passes read 0.0000 and the whole
## leak was `fire_dust`, named in one run. This is that instrument for energy.
##
## DIRECT SIBLING OF LAMaterialFieldMineralProbe3D — read that file's header first; the pair/chain/half-map
## machinery here is deliberately identical so the two diagnostics can be compared line for line.
##
## ONLY FOUR OF THE THIRTEEN PASSES WRITE `temp` AT ALL, and that is what makes this cheap and self-checking:
##   WaterSlumpLavaPass  — lava_flow_sphere3d.glsl:197, donor-mix inflow heat
##   ThermalPass         — six kernels: conduct, solar, buoyancy, cool, lava_phase, magma_buoy
##   SoilPass            — soil_sphere3d.glsl:527 and :616, capacity-weighted mixes
##   ReactionsPass       — reactions_sphere3d.glsl:432 (raw TEMP slot) and :638 (record enthalpy)
## The other nine bind `temp` read-only or not at all, so their HEAT leg must be exactly zero. Any pass may
## legitimately show a CAPACITY leg, because moving matter is most passes' whole job — see the split below.
## A nonzero heat leg on a non-writer means this instrument or its half-map is wrong, not that the planet is
## leaking. That is a free, strong self-check the single global gauge could never offer.
##
## IT SPLITS EACH PASS INTO A HEAT LEG AND A CAPACITY LEG, AND THE CAPACITY ONE IS THE POINT.
## Energy is rc*T*V, and over one pass BOTH move, so the exact change of a cell splits two ways:
##
##     rc_n*T_n - rc_p*T_p  ==  rc_p*(T_n - T_p)  +  T_n*(rc_n - rc_p)
##                              \___ HEAT ___/       \___ CAPACITY ___/
##
## an algebraic identity, so `heat + capacity == total` exactly, per pass, with no residual to explain. HEAT
## is the same matter changing temperature. CAPACITY is the matter itself arriving or leaving — and when a
## carrier moves between cells WITHOUT its enthalpy, or into a channel `rc_of` does not count at all, the
## capacity leg is what records it.
##
## *(The first version of this probe held `rc` fixed at the step's opening and published the heat leg only,
## reasoning that LAMaterialFieldEnergyLedger3D "already attributes the capacity leg". It does not — it
## attributes that leg to a CARRIER (`energy_cap_legs`), never to a PASS, which is the whole question. Worse,
## the fixed-rc form made the pair falsifier useless: `chain_heat` came back -2.2e14 J, and that was not a
## stale buffer, it was `rc` being rebuilt between the two steps of the pair. Measured on the same run,
## `cap_j_k` fell 3.81733e14 -> 3.80969e14 J/K; times ~288 K that is -2.204e14, the "error" to four digits.
## An instrument whose falsifier fires on the dominant physical term cannot falsify anything. And the
## discarded leg was the big one: on the baseline `energy_capacity_w_m2` is -288705 against
## `energy_heat_w_m2` -51124, so holding rc fixed carefully attributed 15% of the drift and threw away 85%.)*
##
## The cost of doing it properly is reading the seven composition channels at every checkpoint rather than
## once: ~112 full-grid reads on a sampled step against 21. At two sampled steps in fifty, nobody notices.
##
## WHICH HALF IS CURRENT. `temp` is a PAIR channel with ONE producer, which is why it is the easiest channel
## in the driver to instrument per-pass. Every writer before ThermalPass edits LIVE; ThermalPass's buoyancy
## leg writes BACK for EVERY cell (heat3d_buoyancy_sphere3d.glsl:88 the pass-through branch, :116 the
## convecting one); everything after edits BACK in place; the end-of-step parity flip promotes BACK. The
## composition channels have their own producers, listed in PRODUCERS below. Keyed by pass NAME so reordering
## PASS_SCRIPTS cannot silently invalidate the map.
##
## THE SELF-CHECK. `residual` is zero by construction (telescoping differences), which is worth nothing on
## its own, so the instrument samples steps in CONSECUTIVE PAIRS: `chain_j` is the second sample's opening
## stock minus the first sample's closing stock. Both are now taken against their own live composition, so a
## wrong half-map is the only thing that can make it large. With the nine structural heat zeros it is the
## second of two numbers that can falsify this instrument.
##
## IT MUST NOT PERTURB THE RUN, and there are two specific ways it could.
##   1. It never calls `request_channel` — residency is simulation state (LAMaterialSphereGPU3D:682-692:
##      a woken `dust` mirror changes insolation, a stale one changes what `add_lava` rewinds).
##   2. It reads ONLY from inside `on_checkpoint`, where `_step_checkpointed` has just called `_rd.sync()`.
##      `buffer_get_data` with a submit still in flight is NOT a passive read — measured 2026-08-03, the same
##      seed and frame count moved `h2o_total` 5062 -> 9803 and `temp_mean` 39.8 -> 44.6 C.
##      In particular it does NOT call `_flush_pending()` the way `read_soil_budget` does, because that makes
##      the next `_drain_pending` early-return and skip a whole mirror refresh plus any pending `take_probe`.
##
## MUTUALLY EXCLUSIVE WITH `LA_H2O_BUDGET` AND `LA_MINERAL_BUDGET`. All three arm the driver's single
## `set_step_probe` callable. LAMaterialFieldSphereStep3D picks by declared precedence and warns.
##
## WHAT IT MEASURED, 2026-08-09, seed 4242, `--sandbox --planet-only --no-fauna --run-frames=300 --fast=8`,
## eight sampled pairs from field_step 1 to 359. Sums over the sixteen sampled steps, so read the RANKING and
## the ZEROS, not the absolute totals (the samples are not consecutive).
##
##     pass                   HEAT J          CAPACITY J
##     thermal              -3.1743e+14       0.0000e+00
##     water_slump_lava     -1.7383e+09      +1.2877e+15
##     erosion_pickup        0.0000e+00      -9.7929e+14
##     plate_advect          0.0000e+00      -7.4095e+14
##     soil                 +3.7695e+12      -3.5476e+14
##     atmosphere            0.0000e+00      +8.4971e+13
##     solid_derive          0.0000e+00      +4.2028e+13
##     eco_surface           0.0000e+00      -2.8292e+13
##     reactions             0.0000e+00      +2.4954e+13
##     erosion_transport / lava_cell_list / fire_dust / gas_wind : 0.0 and 0.0
##     TOTAL                -3.1367e+14      -6.6369e+14
##
## SELF-CHECK PASSED AT EVERY SAMPLE: nine passes exactly 0.0 heat, `residual_j` ~1e3 against totals ~1e14
## (1e-10 relative), `chain_j` 0.0 except +1.2e13 at step 359 — the vent injection queue flushing between the
## two steps of that pair, the same real source LAMaterialFieldMineralProbe3D records at its own step 359.
##
## THE TWO READINGS THAT MATTER.
##   1. THE HEAT LEG IS ONE PASS. `thermal` is 99.9% of it and every other pass is at or near zero. Whatever
##      is wrong with how this planet's temperature evolves is inside ThermalPass's six kernels, not spread
##      across the step. That is a much smaller search than eleven unranked terms.
##   2. THE CAPACITY LEG IS TWICE THE HEAT LEG AND NOBODY WAS LOOKING AT IT. -6.64e14 against -3.14e14, and
##      it is not one pass — it is every pass that MOVES MATTER. A pass that relocates mass and carries its
##      enthalpy nets ~0 here, because one cell's loss is another's gain. A large net is mass arriving
##      somewhere at a temperature it did not bring with it, or leaving into a channel `rc_of` does not
##      count. **`rc_of` counts SEVEN carriers — rock_fill, lava, water, snow, fuel, biomass, detritus — out
##      of the eighteen-odd channels that hold matter.** `soil`, `sediment`, `susp`, `dust`, `moisture`,
##      `fert`, `fungus`, `carbonate` and `silica` are all thermally invisible, so every gram that crosses
##      into one of them deletes its own heat capacity. That is why `erosion_pickup` (rock -> susp) reads
##      -9.8e14 while writing no temperature at all: the scoured rock's thermal mass simply stops existing.
##      HANDOFF item 10 names `soil` as "the one the gauge found"; it is the largest of NINE, not the only
##      one, and this instrument is what makes the other eight visible.
## (Explicit types only, no ':=' inferred typing.)

## Field steps between sampled PAIRS. Matches the mineral and H2O probes so the three line up on one horizon.
const SAMPLE_EVERY: int = 50

## The one pass that flips `temp`'s ping-pong half.
const TEMP_PRODUCER: String = "ThermalPass"

## Ping-pong producers for the composition channels `rc_of` reads. A checkpoint AFTER the named pass must read
## that channel's `back` half. `rock_fill`, `snow`, `fuel`, `biomass` and `detritus` are SINGLE buffers with no
## halves (LAMaterialSphereGPU3D.SINGLE_CHANNELS), so they are absent here and `read_raw` ignores the half.
const PRODUCERS: Dictionary = {
	"lava": "WaterSlumpLavaPass",
	"water": "WaterSlumpLavaPass",
}

## The nine passes that write no `temp` buffer. Their HEAT leg is asserted zero as a structural self-check.
const SILENT_HEAT_PASSES: PackedStringArray = [
	"plate_advect", "solid_derive", "lava_cell_list", "gas_wind", "atmosphere",
	"erosion_transport", "erosion_pickup", "fire_dust", "eco_surface"]

## A leg smaller than this is reported as a structural zero rather than as noise. One megajoule against a
## stock of ~1.5e17 is 6.6e-12 of it; float32 buffer reads cannot resolve anything near that, so a "zero" leg
## printing 1e-9 is the readback's own rounding and saying so is more honest than printing the digits.
const ZERO_EPS_J: float = 1.0e6

var _f = null                      # back-reference to the owning LAMaterialField3D
# Primed so the FIRST pair samples at field_step 1 — the opening stock is what separates "this run lost heat"
# from "this build started with less", and first sampling at step 50 cannot tell them apart.
var _gate: int = SAMPLE_EVERY - 1
var _in_pair: int = 0              # 0 = not sampling, 1 = first of the pair, 2 = second

var _done: Dictionary = {}         # pass name -> true, once it has run this step (drives the half-map)
var _volume: float = 0.0           # one cell, m3
# FLOAT64, AND THAT IS LOAD-BEARING, NOT TIDINESS. Every published number here is a DIFFERENCE of two
# checkpoints, so the storage precision sets the noise floor of the whole instrument. Held as float32 these
# read a spurious ~-5e8 J of "heat" per checkpoint on all nine passes that write no temperature: rc is ~2.4e6,
# whose float32 ulp is ~0.25, and 0.25 x 288 K x ~1e5 cells x the cell volume is exactly that. The device
# buffers are float32 and that is fine — reading the same unchanged buffer twice gives bit-identical values,
# so an untouched cell differences to exactly zero — but the rc computed FROM them must not be re-quantised.
var _rc_prev: PackedFloat64Array = PackedFloat64Array()
var _t_prev: PackedFloat64Array = PackedFloat64Array()
var _prev: float = 0.0             # stock in joules at the previous checkpoint
var _start: float = 0.0            # stock in joules at the step's opening
var _cap_now: float = 0.0          # sum rc*V at the latest checkpoint, J/K
var _legs_heat: Dictionary = {}
var _legs_cap: Dictionary = {}
# Closing stock of the FIRST sample of a pair, so the second can report `chain_j`.
var _pair_end: float = NAN


func setup(field) -> void:
	_f = field


## Called once per field step by LAMaterialFieldSphereStep3D, BEFORE _gpu.step(). Arms the driver's
## between-pass probe on the steps this sampler wants and leaves it disarmed otherwise, so the normal
## one-submit step path is what runs on every other step.
func pre_step() -> void:
	if _f == null or _f._gpu == null or not _f._gpu.has_method("set_step_probe"):
		return
	if _in_pair == 1:
		_in_pair = 2                   # second half of the pair — sample again, immediately after the first
	else:
		_gate += 1
		if _gate >= SAMPLE_EVERY:
			_gate = 0
			_in_pair = 1
			_pair_end = NAN
		else:
			_in_pair = 0
	if _in_pair == 0:
		_f._gpu.set_step_probe(Callable())
		return
	_f._gpu.set_step_probe(Callable(self, "on_checkpoint"))


## The between-pass probe. `pass_index` -1 = before any pass ran; otherwise the index of the pass that just
## finished, with `pass_name` its script basename. The device has just been synced when this is called.
func on_checkpoint(pass_index: int, pass_name: String) -> void:
	if pass_index < 0:
		_done = {}
		_legs_heat = {}
		_legs_cap = {}
		_sample(true)
		_start = _prev
		return
	# The producer's OUTPUT is what a checkpoint taken after it must read, so the half flips HERE, not before.
	_done[pass_name] = true
	var before: float = _prev
	var split: Array = _sample(false)
	var key: String = _leg_key(pass_name)
	_legs_heat[key] = split[0]
	_legs_cap[key] = split[1]
	# heat + capacity == total, algebraically. Assert it rather than trusting it.
	var slip: float = (split[0] + split[1]) - (_prev - before)
	if absf(slip) > ZERO_EPS_J:
		push_warning("EnergyProbe: leg split does not close on %s by %.3e J" % [key, slip])


## Called once per field step by LAMaterialFieldSphereStep3D, AFTER _gpu.step(). Prints the sampled step's
## budget; a no-op on unsampled steps.
func post_step() -> void:
	if _in_pair == 0 or _legs_heat.is_empty():
		return
	var step_total: float = _prev - _start
	var sum_heat: float = 0.0
	var sum_cap: float = 0.0
	var heat_out: Dictionary = {}
	var cap_out: Dictionary = {}
	var violations: PackedStringArray = PackedStringArray()
	for k in _legs_heat:
		var h: float = float(_legs_heat[k])
		var c: float = float(_legs_cap[k])
		sum_heat += h
		sum_cap += c
		heat_out[k] = 0.0 if absf(h) < ZERO_EPS_J else h
		cap_out[k] = 0.0 if absf(c) < ZERO_EPS_J else c
		# A pass that binds no writable temp buffer cannot have changed any cell's temperature.
		if SILENT_HEAT_PASSES.has(k) and absf(h) >= ZERO_EPS_J:
			violations.append(k)
	var out: Dictionary = {
		"field_step": _step_index(),
		"pair": _in_pair,
		"stock_j": _prev,
		"cap_j_k": _cap_now,
		"step_total_j": step_total,
		"step_heat_j": sum_heat,
		"step_cap_j": sum_cap,
		"residual_j": step_total - (sum_heat + sum_cap),
		"legs_heat_j": heat_out,
		"legs_cap_j": cap_out,
	}
	# A pass with no temp write reporting heat falsifies the instrument, not the planet. Say so loudly rather
	# than letting a reader treat the number as a finding.
	if not violations.is_empty():
		out["INSTRUMENT_WRONG_silent_pass_moved_heat"] = violations
	if _in_pair == 2 and not is_nan(_pair_end):
		# The instrument's other falsifiable number: this step opened where the previous one closed, or the
		# half-map / parity flip in the header is wrong. Both ends are taken against their own live
		# composition, so a composition change between steps can no longer masquerade as an error here.
		out["chain_j"] = _start - _pair_end
	_pair_end = _prev
	print("ENERGY_BUDGET=", JSON.stringify(out))
	_legs_heat = {}
	_legs_cap = {}


# --- internals ----------------------------------------------------------------

## Read the composition and temperature at the half that is current RIGHT NOW, update `_prev`/`_cap_now`, and
## return [heat_j, capacity_j] against the previous checkpoint. `opening` skips the split (there is no
## previous checkpoint) and just latches the state.
##
## THE rc FORMULA HERE IS A TRANSCRIPTION OF kernels3d/rc_shared.glsli `rc_of()`, AND THAT IS A KNOWN HAZARD —
## it is how the ledger's own stock came to be measured against a capacity model the kernels did not use,
## which made a 7.4% drift read as 12.8% once the two were reconciled. It is tolerable HERE and only here,
## because every published number is a DIFFERENCE taken against the same formula on both sides: a
## transcription error scales all thirteen legs by a common factor and cannot change which pass is largest,
## which is the only question this instrument is asked. Do not read `stock_j` as an absolute —
## LAMaterialFieldEnergyLedger3D owns that number. Any edit to rc_shared.glsli must change this in the same
## commit.
func _sample(opening: bool) -> Array:
	var gpu = _f._gpu
	var cc: int = _f._cell_count
	var phase: int = gpu.probe_phase()
	var side: float = maxf(float(_f._cell_size), 0.001)
	_volume = side * side * side

	var rock: PackedFloat32Array = _read(gpu, "rock_fill", phase)
	var lava: PackedFloat32Array = _read(gpu, "lava", phase)
	var water: PackedFloat32Array = _read(gpu, "water", phase)
	var snow: PackedFloat32Array = _read(gpu, "snow", phase)
	var fuel: PackedFloat32Array = _read(gpu, "fuel", phase)
	var bio: PackedFloat32Array = _read(gpu, "biomass", phase)
	var det: PackedFloat32Array = _read(gpu, "detritus", phase)
	var temp: PackedFloat32Array = _read(gpu, "temp", phase)

	var rc_air: float = LAPhysical.VOL_HEAT_CAP_AIR_J_M3K
	var rc_rock: float = LAPhysical.VOL_HEAT_CAP_ROCK_J_M3K
	var rc_water: float = LAPhysical.VOL_HEAT_CAP_WATER_J_M3K
	var rc_snow: float = LAPhysical.VOL_HEAT_CAP_SNOW_J_M3K
	var rc_org: float = LAPhysical.VOL_HEAT_CAP_ORGANIC_J_M3K

	var ok: bool = temp.size() >= cc and rock.size() >= cc and lava.size() >= cc and water.size() >= cc \
		and snow.size() >= cc and fuel.size() >= cc and bio.size() >= cc and det.size() >= cc
	if not ok:
		return [0.0, 0.0]

	var rc_now: PackedFloat64Array = PackedFloat64Array()
	rc_now.resize(cc)
	var t_now: PackedFloat64Array = PackedFloat64Array()
	t_now.resize(cc)
	var have_prev: bool = (not opening) and _rc_prev.size() >= cc and _t_prev.size() >= cc
	var stock: float = 0.0
	var cap: float = 0.0
	var heat: float = 0.0
	var capacity: float = 0.0
	for c in cc:
		var f_rock: float = clampf(rock[c] + lava[c], 0.0, 1.0)
		var f_water: float = clampf(water[c], 0.0, 1.0)
		var f_snow: float = clampf(snow[c], 0.0, 1.0)
		var f_org: float = clampf(fuel[c] + bio[c] + det[c], 0.0, 1.0)
		var f_air: float = maxf(0.0, 1.0 - f_rock - f_water - f_snow - f_org)
		var rc: float = rc_air * f_air + rc_rock * f_rock + rc_water * f_water \
			+ rc_snow * f_snow + rc_org * f_org
		var tk: float = temp[c] + LAPhysical.KELVIN_OFFSET
		rc_now[c] = rc
		t_now[c] = tk
		stock += rc * tk
		cap += rc
		if have_prev:
			heat += _rc_prev[c] * (tk - _t_prev[c])
			capacity += tk * (rc - _rc_prev[c])
	_rc_prev = rc_now
	_t_prev = t_now
	_prev = stock * _volume
	_cap_now = cap * _volume
	return [heat * _volume, capacity * _volume]


## Read one channel at the half that is current given which passes have already run this step.
func _read(gpu, name: String, phase: int) -> PackedFloat32Array:
	var half: int = phase
	var producer: String = TEMP_PRODUCER if name == "temp" else String(PRODUCERS.get(name, ""))
	if producer != "" and _done.has(producer):
		half = 1 - phase
	return gpu.read_raw(name, half)


## Short leg label: "WaterSlumpLavaPass" -> "water_slump_lava" (mirrors the driver's GPU-timing gauge keys).
func _leg_key(pass_name: String) -> String:
	var s: String = pass_name
	if s.ends_with("Pass"):
		s = s.substr(0, s.length() - 4)
	return s.to_snake_case()


func _step_index() -> int:
	var gpu = _f._gpu
	return int(gpu._step_index) if gpu != null else -1
