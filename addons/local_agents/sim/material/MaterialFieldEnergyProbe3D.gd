class_name LAMaterialFieldEnergyProbe3D
extends RefCounted

const CellVolScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCellVolume3D.gd")

## LAMaterialFieldEnergyProbe3D: a PER-PASS heat budget, so the planet's energy drift has to NAME THE PASS
## `cap_j_k` fell 3.81733e14 -> 3.80969e14 J/K; times ~288 K that is -2.204e14, the "error" to four digits.

## Field steps between sampled PAIRS. Matches the mineral and H2O probes so the three line up on one horizon.
const SAMPLE_EVERY: int = 50

## The one pass that flips `temp`'s ping-pong half.
const TEMP_PRODUCER: String = "ThermalPass"

const PRODUCERS: Dictionary = {
	"lava": "WaterSlumpLavaPass",
	"water": "WaterSlumpLavaPass",
	"sediment": "WaterSlumpLavaPass",
	"susp": "ErosionPickupPass",
	"dust": "FireDustPass",
	"soil": "SoilPass",
	"moisture": "AtmospherePass",
	"fungus": "EcoSurfacePass",
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

func _sample(opening: bool) -> Array:
	var gpu = _f._gpu
	var cc: int = _f._cell_count
	var phase: int = gpu.probe_phase()
	var vol: PackedFloat32Array = CellVolScript.of(_f)
	if vol.size() != cc:
		return [0.0, 0.0]

	var ch: Dictionary = {}
	for name in LAHeatCapacity.channels():
		ch[name] = _read(gpu, name, phase)
	var temp: PackedFloat32Array = _read(gpu, "temp", phase)
	if temp.size() < cc:
		return [0.0, 0.0]

	var rc_now: PackedFloat64Array = LAHeatCapacity.field(ch, cc)
	var t_now: PackedFloat64Array = PackedFloat64Array()
	t_now.resize(cc)
	var have_prev: bool = (not opening) and _rc_prev.size() >= cc and _t_prev.size() >= cc
	var stock: float = 0.0
	var cap: float = 0.0
	var heat: float = 0.0
	var capacity: float = 0.0
	for c in cc:
		var rc: float = rc_now[c]
		var tk: float = temp[c] + LAPhysical.KELVIN_OFFSET
		var w: float = vol[c]
		t_now[c] = tk
		stock += rc * tk * w
		cap += rc * w
		if have_prev:
			heat += _rc_prev[c] * (tk - _t_prev[c]) * w
			capacity += tk * (rc - _rc_prev[c]) * w
	_rc_prev = rc_now
	_t_prev = t_now
	_prev = stock
	_cap_now = cap
	return [heat, capacity]


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
