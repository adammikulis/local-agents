@tool
extends RefCounted


const CombustionScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/CombustionRecords.gd")
const DefsScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionDefs.gd")

# The condition the sweep is evaluated at: a cell holding litter, in ambient air.
const FUEL_AT_CELL: float = 0.02          # the ground-surface fuel seed's order of magnitude
## The rate law is tested in AIR. The planet no longer seeds free oxygen — it is a product of life — so
## this cannot borrow the world's seed without testing combustion in a vacuum.
const O2_IN_AIR: float = 1.0
const O2_IN_AIR: float = 1.0             # one unit of `o2` IS a cell of ambient air, by definition


## The extent, evaluated exactly as reactions_sphere3d.glsl does: the ARRHENIUS rate, then the reactant caps
## with the quench floor subtracted from the quenched species. `t_ceiling_k` is read off the record (0 = none)
## the same way the kernel reads it.
func _extent(rec: Dictionary, t_c: float, fuel: float, o2: float) -> float:
	var t_k: float = t_c + LAPhysical.KELVIN_OFFSET
	var ceiling: float = float(rec.get("t_ceiling_k", 0.0))
	if ceiling > 0.0:
		t_k = minf(t_k, ceiling)
	var t_ref: float = maxf(float(rec.get("param2", 1.0)), 1.0)
	var x: float = float(rec.get("rate_k", 0.0)) * fuel * o2 \
		* exp(-float(rec.get("threshold", 0.0)) * (1.0 / maxf(t_k, 1.0) - 1.0 / t_ref))
	var quench_slot: int = int(rec.get("quench_slot", -1))
	var quench_min: float = float(rec.get("quench_min", 0.0))
	for r in rec.get("reactants", []):
		var slot: int = int(r[0])
		var coeff: float = maxf(float(r[1]), 1.0e-6)
		var avail: float = fuel if slot == DefsScript.FUEL else (o2 if slot == DefsScript.O2 else INF)
		if slot == quench_slot:
			avail = maxf(0.0, avail - quench_min)
		x = minf(x, avail / coeff)
	return maxf(x, 0.0)


func _coeff(rec: Dictionary, side: String, slot: int) -> float:
	for e in rec.get(side, []):
		if int(e[0]) == slot:
			return float(e[1])
	return 0.0


## Moles of substance in one unit of a channel — the conversion the balance gate applies, so the ratios below
## are compared as a chemist writes them and not as two arbitrary channel scales.
func _mol(slot: int) -> float:
	return float(LAReactionBalance.mol_per_unit().get(slot, 0.0))


func run_test(_tree: SceneTree) -> bool:
	var recs: Array = CombustionScript.records()
	if recs.size() != 1:
		push_error("combustion rate law: expected exactly one record in LACombustionRecords, found %d."
			% recs.size())
		return false
	var burn: Dictionary = recs[0]
	if int(burn.get("rate_model", -1)) != DefsScript.ARRHENIUS:
		push_error("combustion is not an ARRHENIUS record. A solid fuel has no ignition point — it pyrolyses "
			+ "at a rate rising exponentially with temperature — so any threshold model here is the state "
			+ "machine coming back.")
		return false

	var ok: bool = true
	var o2_per_fuel: float = _coeff(burn, "reactants", DefsScript.O2)
	var co2_per_fuel: float = _coeff(burn, "products", DefsScript.CO2)
	var w_per_fuel: float = _coeff(burn, "products", DefsScript.MOISTURE)
	var n_per_fuel: float = _coeff(burn, "products", DefsScript.FERT)
	var enthalpy: float = float(burn.get("enthalpy_j_m3", 0.0))
	var quench: float = float(burn.get("quench_min", 0.0))

	print("COMBUSTION_RECORD={\"rate_k\":%s,\"ea_over_r_k\":%.1f,\"t_ref_k\":%.1f,\"t_ceiling_k\":%.1f,"
		% [String.num_scientific(float(burn.get("rate_k", 0.0))), float(burn.get("threshold", 0.0)),
			float(burn.get("param2", 0.0)), float(burn.get("t_ceiling_k", 0.0))]
		+ "\"o2_per_fuel\":%.2f,\"co2_per_fuel\":%.2f,\"h2o_per_fuel\":%s,\"n_per_fuel\":%s,"
		% [o2_per_fuel, co2_per_fuel, String.num_scientific(w_per_fuel), String.num_scientific(n_per_fuel)]
		+ "\"enthalpy_j_m3\":%s,\"o2_quench\":%.3f}"
		% [String.num_scientific(enthalpy), quench])

	var temps: PackedFloat64Array = PackedFloat64Array(
		[-20.0, 0.0, 27.0, 100.0, 200.0, 227.0, 300.0, 327.0, 400.0, 427.0, 500.0, 800.0])
	print("COMBUSTION_RATE_LAW={\"note\":\"extent per step at fuel %.3f, o2 %.2f\"}" % [FUEL_AT_CELL, O2_IN_AIR])
	var prev: float = -1.0
	var prev_t: float = 0.0
	for t in temps:
		var x: float = _extent(burn, t, FUEL_AT_CELL, O2_IN_AIR)
		print("  T=%7.1f C   extent=%s   fuel_frac=%s" % [
			t, String.num_scientific(x), String.num_scientific(x / FUEL_AT_CELL)])
		if x <= 0.0:
			push_error("combustion extent is exactly zero at %.1f C. An Arrhenius rate is positive at every "
				% t + "temperature; a hard zero means a threshold has been reintroduced.")
			ok = false
		if x < prev:
			push_error("combustion is not monotone in temperature (%.1f C -> %.1f C). " % [prev_t, t]
				+ "Pyrolysis rises with temperature, always.")
			ok = false
		prev = x
		prev_t = t

	var cold: float = _extent(burn, 27.0, FUEL_AT_CELL, O2_IN_AIR)
	var hot: float = _extent(burn, 427.0, FUEL_AT_CELL, O2_IN_AIR)
	if hot / maxf(cold, 1.0e-300) < 1.0e12:
		push_error("combustion at 427 C is only %s times its rate at 27 C. A pyrolysis activation energy of "
			% String.num_scientific(hot / maxf(cold, 1.0e-300))
			+ "%.0f kJ/mol spans far more than that; the exponential has been flattened."
			% (LAPhysical.CELLULOSE_PYROLYSIS_EA_J_MOL / 1000.0))
		ok = false
	# At 27 C a cell's fuel must effectively never burn: less than a part in 1e12 of it per step.
	if cold / FUEL_AT_CELL > 1.0e-12:
		push_error("combustion consumes %s of a cell's fuel per step at 27 C. Litter on warm ground does not "
			% String.num_scientific(cold / FUEL_AT_CELL) + "smoulder; the rate constant is far too large.")
		ok = false
	# ...and in the flaming regime the extent must be reactant-limited, not rate-limited — the cell burns
	# everything it can reach in one step. That is the runaway having happened. What it CAN reach is the
	# oxygen above the quench floor, not all of it.
	var reachable: float = minf(FUEL_AT_CELL, (O2_IN_AIR - quench) / o2_per_fuel)
	if hot < reachable * 0.999:
		push_error("at 427 C combustion is still rate-limited (%s against a reactant cap of %s). "
			% [String.num_scientific(hot), String.num_scientific(reachable)]
			+ "Above the pyrolysis regime a fire is limited by its supply, not by its kinetics.")
		ok = false

	# --- 3. THE STOICHIOMETRY IS THE REACTION: CH2O + O2 -> CO2 + H2O + N ------------------------------------
	# Compared in MOLES. Channel units differ by up to 6484x, which is exactly how a 1:1 gas-to-water
	# coefficient shipped in this substrate while being wrong by that factor.
	var mol_fuel: float = _mol(DefsScript.FUEL)
	var checks: Array = [
		["O2 per carbon", o2_per_fuel * _mol(DefsScript.O2) / mol_fuel, 1.0],
		["CO2 per carbon", co2_per_fuel * _mol(DefsScript.CO2) / mol_fuel, 1.0],
		["H2O per carbon", w_per_fuel * _mol(DefsScript.MOISTURE) / mol_fuel, 1.0],
		["N per carbon", n_per_fuel * _mol(DefsScript.FERT) / mol_fuel,
			float(LAReactionBalance.composition()[DefsScript.FUEL]["N"])],
	]
	for c in checks:
		var got: float = float(c[1])
		var want: float = float(c[2])
		print("  %-16s %.6f mol (expected %.6f)" % [String(c[0]), got, want])
		if absf(got - want) > 1.0e-6 * maxf(want, 1.0):
			push_error("combustion's %s is %.6f, expected %.6f. The reaction is CH2O + O2 -> CO2 + H2O and "
				% [String(c[0]), got, want] + "the nitrogen the litter carried is conserved into the ash.")
			ok = false

	# --- 4. THE OXYGEN QUENCH: a flame goes out before the oxygen does ---------------------------------------
	# Measured as a MOLE FRACTION (0.15) and converted to the channel's ambient-air unit, so 0.716.
	var want_quench: float = LAPhysical.LIMITING_OXYGEN_CONCENTRATION_FRAC / LAPhysical.AIR_MOLE_FRAC_O2
	if absf(quench - want_quench) > 1.0e-6:
		push_error("the oxygen quench is %.4f, expected %.4f = LIMITING_OXYGEN_CONCENTRATION_FRAC / "
			% [quench, want_quench] + "AIR_MOLE_FRAC_O2. It is a measured property of the flame, not a knob.")
		ok = false
	if _extent(burn, 800.0, FUEL_AT_CELL, want_quench * 0.99) != 0.0:
		push_error("combustion still proceeds below the limiting oxygen concentration at 800 C. A flame in a "
			+ "sealed room goes out with most of the oxygen still in the room.")
		ok = false
	if _extent(burn, 800.0, FUEL_AT_CELL, want_quench * 1.01) <= 0.0:
		push_error("combustion does not proceed just ABOVE the limiting oxygen concentration. The quench is a "
			+ "floor, not an off switch.")
		ok = false
	# THE FLOOR MUST BIND WITHIN THE STEP, not only on the next one. A cell with a full charge of ambient air
	# may burn only the oxygen ABOVE the flammability limit — the difference between a flame landing at a real
	# wildfire's temperature and one reaching the full stoichiometric adiabatic rise.
	var burned: float = _extent(burn, 800.0, FUEL_AT_CELL, O2_IN_AIR)
	var o2_left: float = O2_IN_AIR - burned * o2_per_fuel
	print("  a full charge of ambient air at 800 C burns %s fuel and leaves o2 %.4f (quench %.4f)"
		% [String.num_scientific(burned), o2_left, quench])
	if o2_left < quench - 1.0e-6:
		push_error("one step of combustion drew the cell's oxygen to %.4f, below the limiting concentration "
			% o2_left + "%.4f. The quench must bind INSIDE the step or the flame burns air a real one cannot."
			% quench)
		ok = false

	# --- 5. WET FUEL RESISTS LIGHTING WITH NO WET-CELL GATE --------------------------------------------------
	# The heat capacity is the mechanism (reactions_sphere3d.glsl's rc_of, the same expression
	# heat3d_cool_sphere3d uses). The reaction is identical in both cells; only the cell's thermal mass differs.
	var rc_dry: float = LAPhysical.VOL_HEAT_CAP_AIR_J_M3K
	var rc_wet: float = LAPhysical.VOL_HEAT_CAP_AIR_J_M3K * (1.0 - 0.05) \
		+ LAPhysical.VOL_HEAT_CAP_WATER_J_M3K * 0.05
	var d_dry: float = enthalpy * burned / rc_dry
	var d_wet: float = enthalpy * burned / rc_wet
	print("  one full charge of ambient air: dry cell +%.1f K, 5%%-wet cell +%.1f K (ratio %.0fx)"
		% [d_dry, d_wet, d_dry / maxf(d_wet, 1.0e-9)])
	if d_dry / maxf(d_wet, 1.0e-9) < 50.0:
		push_error("a cell holding 5%% water warms only %.0fx less than a dry one. Liquid water holds 3500x "
			% (d_dry / maxf(d_wet, 1.0e-9)) + "the heat of the same volume of air; if that ratio is gone, so "
			+ "is the reason wet fuel does not light.")
		ok = false
	# And the enthalpy itself is the measured one: the oxygen this record consumes times Huggett's figure.
	var want_enthalpy: float = o2_per_fuel * LAPhysical.AMBIENT_O2_DENSITY_KG_M3 * LAPhysical.HEAT_PER_KG_OXYGEN_J
	if absf(enthalpy - want_enthalpy) > 1.0e-6 * want_enthalpy:
		push_error("combustion's enthalpy is %s J/m3 per unit, expected %s = (the O2 it consumes) x "
			% [String.num_scientific(enthalpy), String.num_scientific(want_enthalpy)]
			+ "LAPhysical.HEAT_PER_KG_OXYGEN_J.")
		ok = false

	if ok:
		print("COMBUSTION_RATE_LAW_OK=1")
	return ok
