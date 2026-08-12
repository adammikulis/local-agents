extends RefCounted

## THE ACCEPTANCE TEST FOR ENTHALPY AS THE STATE. Remove heat from liquid water at a constant rate and the
## temperature must PIN at the melting point for exactly the span `m * L_fus / rate` pays for.

const Mix: GDScript = preload("res://addons/local_agents/sim/material/MixtureEnthalpy.gd")

const WATER_KG: float = 10.0
const START_C: float = 2.0
const RATE_J: float = 1.0e4      # removed per step
const PIN_TOL_C: float = 1.0e-6
const SPAN_TOL: float = 0.02     # steps, relative


func _fail(msg: String) -> bool:
	push_error("test_latent_plateau: " + msg)
	return false


## Enthalpy of fusion of water, J/kg (CRC Handbook). Not read from LASubstances, which the code reads.
const MEASURED_L_FUS_J_KG: float = 333700.0

func _expected_steps() -> float:
	return WATER_KG * MEASURED_L_FUS_J_KG / RATE_J


func run_test(_tree: SceneTree) -> bool:
	var p: float = LAPhysical.STANDARD_PRESSURE_PA
	var masses: Dictionary = {"h2o": WATER_KG}
	var melt: float = LASubstances.melt_c_at("h2o", p)

	var h: float = Mix.enthalpy_at(masses, 0.0, START_C, p)
	var pinned: int = 0
	var seen_liquid: bool = false
	var seen_below: bool = false
	var last_t: float = START_C

	for _i in range(int(_expected_steps() * 3.0) + 200):
		var st: Dictionary = Mix.state(masses, 0.0, h, p)
		var t: float = float(st.get("t_c", NAN))
		if not is_finite(t):
			return _fail("state() returned a non-finite temperature")
		if t > last_t + PIN_TOL_C:
			return _fail("removing heat RAISED the temperature: %f -> %f" % [last_t, t])
		if t > melt + PIN_TOL_C:
			seen_liquid = true
		elif absf(t - melt) <= PIN_TOL_C:
			pinned += 1
		else:
			seen_below = true
			break
		last_t = t
		h -= RATE_J

	if not seen_liquid:
		return _fail("never started above the melting point")
	if not seen_below:
		return _fail("never came off the plateau — the fusion enthalpy is unbounded")

	var want: float = _expected_steps()
	var rel: float = absf(float(pinned) - want) / maxf(want, 1.0)
	if rel > SPAN_TOL:
		return _fail("plateau lasted %d steps, expected %s (rel %s)"
			% [pinned, String.num(want, 2), String.num(rel, 4)])

	# A substance with no fusion enthalpy crossed must not pin.
	var dry: Dictionary = {"silicate": 1.0}
	var h_dry: float = Mix.enthalpy_at(dry, 0.0, 1500.0, p)
	var t_prev: float = 1500.0
	var flat: int = 0
	for _j in range(50):
		h_dry -= 1.0e5
		var t2: float = float(Mix.state(dry, 0.0, h_dry, p).get("t_c", NAN))
		if absf(t2 - t_prev) <= PIN_TOL_C:
			flat += 1
		t_prev = t2
	if flat >= 50:
		return _fail("a cell with no phase boundary crossed still pinned — the pin is not latent heat")

	print("test_latent_plateau: plateau held %d steps against %s expected" % [pinned, String.num(want, 2)])
	return true
