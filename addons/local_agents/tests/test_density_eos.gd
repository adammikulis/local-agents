@tool
extends RefCounted

## density() against the ideal gas law, thermal expansivity, bulk modulus and the reference fallback.

const S: GDScript = preload("res://addons/local_agents/sim/material/Substances.gd")
const PC: GDScript = preload("res://addons/local_agents/sim/material/PhysicalConstants.gd")

const P_ATM: float = 101325.0


func _fail(msg: String) -> bool:
	push_error(msg)
	return false


func run_test(_tree: SceneTree) -> bool:
	var ok: bool = true

	# A gas obeys p M / R T.
	var t_c: float = 15.0
	var rho_n2: float = S.density("n2", t_c, P_ATM)
	var want: float = P_ATM * PC.MOLAR_MASS_N2_KG_MOL \
		/ (PC.GAS_CONSTANT_J_MOL_K * (t_c + PC.KELVIN_OFFSET))
	if absf(rho_n2 - want) > want * 1.0e-6:
		ok = _fail("N2 at 1 atm reads %s kg/m3 against the ideal gas law's %s. density() is not solving "
			% [String.num(rho_n2, 6), String.num(want, 6)] + "p M / R T for a gas.")

	# One scale height up the pressure is down by 1/e and so is the density, at fixed temperature.
	var g: float = 9.81
	var h: float = PC.scale_height_m(t_c, g)
	if not (h > 0.0):
		ok = _fail("scale_height_m returned %s; the altitude leg of this test has no column." % h)
	var p_up: float = P_ATM * exp(-1.0)
	var rho_up: float = S.density("n2", t_c, p_up)
	if not (rho_up < rho_n2):
		ok = _fail("N2 at %s Pa is not thinner than at %s Pa. Air does not fall off with altitude."
			% [String.num(p_up, 1), String.num(P_ATM, 1)])
	if absf(rho_up - rho_n2 * exp(-1.0)) > rho_n2 * 1.0e-6:
		ok = _fail("N2 one scale height up reads %s, not the %s the ideal gas law gives."
			% [String.num(rho_up, 6), String.num(rho_n2 * exp(-1.0), 6)])

	# Warming a gas at fixed pressure thins it.
	if not (S.density("n2", 100.0, P_ATM) < rho_n2):
		ok = _fail("Warm N2 is not lighter than cold N2 at the same pressure.")

	# Liquid water is denser cold than hot.
	var rho_4: float = S.density("h2o", 4.0, P_ATM)
	var rho_40: float = S.density("h2o", 40.0, P_ATM)
	if not (rho_4 > rho_40):
		ok = _fail("Water at 4 C reads %s kg/m3 and at 40 C reads %s. A lake cannot stratify if its "
			% [String.num(rho_4, 4), String.num(rho_40, 4)] + "water does not get heavier as it cools.")
	var expect_gap: float = rho_4 * PC.WATER_VOLUME_EXPANSION_PER_K * 36.0
	if absf((rho_4 - rho_40) - expect_gap) > expect_gap * 0.05:
		ok = _fail("The 4 C to 40 C density gap is %s kg/m3 against the %s the expansivity gives. The "
			% [String.num(rho_4 - rho_40, 4), String.num(expect_gap, 4)] + "EOS is not the one declared.")

	# Rock is squeezed by the crust above it.
	var rho_shallow: float = S.density("silicate", 25.0, P_ATM)
	var rho_deep: float = S.density("silicate", 25.0, PC.LITHIFICATION_PRESSURE_PA)
	if not (rho_deep > rho_shallow):
		ok = _fail("Rock at the base of the modelled crust is not denser than rock at the surface. "
			+ "The bulk modulus is not reaching density().")
	var squeeze: float = (PC.LITHIFICATION_PRESSURE_PA - P_ATM) / PC.ROCK_BULK_MODULUS_PA
	if absf((rho_deep / rho_shallow - 1.0) - squeeze) > squeeze * 0.01:
		ok = _fail("Rock compresses by %s over that pressure against the %s its bulk modulus gives."
			% [String.num(rho_deep / rho_shallow - 1.0, 8), String.num(squeeze, 8)])

	if not (S.density("silicate", PC.BASALT_LIQUIDUS_C, P_ATM) < rho_shallow):
		ok = _fail("Silicate at its liquidus is not lighter than silicate at the surface. Magma has no "
			+ "buoyancy of its own.")

	# Ice floats.
	if not (S.density("h2o", -5.0, P_ATM) < S.density("h2o", 1.0, P_ATM)):
		ok = _fail("Ice is not lighter than the water beside it. Lakes would freeze from the bottom.")

	# A substance with no expansivity or bulk modulus reports its reference value.
	if S.has_eos("cellulose"):
		ok = _fail("cellulose claims an equation of state; this test's premise is stale.")
	var rho_ref: float = float(S.table()["cellulose"]["density"])
	if absf(S.density("cellulose", 200.0, 5.0e7) - rho_ref) > 0.0:
		ok = _fail("cellulose moved off its reference value without a coefficient to move it.")

	return ok
