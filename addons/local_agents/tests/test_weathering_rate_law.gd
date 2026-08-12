@tool
extends RefCounted


const GeoScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/GeoRecords.gd")
const DefsScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionDefs.gd")

# The condition the sweep is evaluated at: a wet, sky-exposed cell of ground on bedrock.
const WATER_AT_CELL: float = 0.5
const CO2_AT_CELL: float = 0.277        # this planet's measured mean ground CO2 — a CONDITION of the sweep,
                                        # not a constant of the model (the record is first order in it)
const ROCK_BELOW: float = 1.0           # a full bedrock cell under the reacting cell


## Evaluate one record's extent exactly as the kernel does, at temperature `t_c`.
func _extent(rec: Dictionary, t_c: float) -> float:
	var model: int = int(rec.get("rate_model", 0))
	var k: float = float(rec.get("rate_k", 0.0))
	var thr: float = float(rec.get("threshold", 0.0))
	var x: float = 0.0
	if model == DefsScript.DEFICIT_BELOW_THRESHOLD:
		x = maxf(0.0, thr - t_c) * k
	elif model == DefsScript.EXCESS_OVER_THRESHOLD:
		x = maxf(0.0, t_c - thr) * k
	elif model == DefsScript.ARRHENIUS:
		# Same expression as the kernel, including the temperature ceiling — which is READ OFF THE RECORD as
		# `t_ceiling_k` (0 = none) rather than hardcoded to water's boiling point. It was hardcoded here and in
		# the kernel until 2026-08-09; D1b's answer is unchanged, because D1b is the record that has a solvent.
		var t_k: float = t_c + LAPhysical.KELVIN_OFFSET
		var ceiling: float = float(rec.get("t_ceiling_k", 0.0))
		if ceiling > 0.0:
			t_k = minf(t_k, ceiling)
		var t_ref: float = maxf(float(rec.get("param2", 1.0)), 1.0)
		x = k * WATER_AT_CELL * CO2_AT_CELL * exp(-thr * (1.0 / maxf(t_k, 1.0) - 1.0 / t_ref))
	else:
		return 0.0
	# Reactant + aux caps, the kernel's own bounds. WATER and BEDROCK_BELOW are the two that bind here.
	for r in rec.get("reactants", []):
		var slot: int = int(r[0])
		var coeff: float = maxf(float(r[1]), 1.0e-6)
		if slot == DefsScript.WATER:
			x = minf(x, WATER_AT_CELL / coeff)
		elif slot == DefsScript.BEDROCK_BELOW:
			x = minf(x, ROCK_BELOW / coeff)
	var cap_slot: int = int(rec.get("cap_slot", -1))
	if cap_slot == DefsScript.BEDROCK_BELOW:
		x = minf(x, ROCK_BELOW / maxf(float(rec.get("cap_coeff", 1.0)), 1.0e-6))
	return maxf(x, 0.0)


## The BEDROCK actually removed per step, which is what "weathering rate" means — the extent times whatever
## the record's rock coefficient is (frost breaks FROST_ROCK_PER_ICE of rock per unit of ice).
func _rock_removed(rec: Dictionary, t_c: float) -> float:
	var x: float = _extent(rec, t_c)
	for r in rec.get("reactants", []):
		if int(r[0]) == DefsScript.BEDROCK_BELOW:
			return x * float(r[1])
	return 0.0


func _integrate_frost(rec: Dictionary, mean_c: float, swing_c: float, steps: int) -> float:
	var water: float = 0.2
	var snow: float = 0.0
	var removed: float = 0.0
	var pore_cap: float = ROCK_BELOW / maxf(float(rec.get("cap_coeff", 1.0)), 1.0e-6)
	var rock_per_ice: float = 0.0
	for r in rec.get("reactants", []):
		if int(r[0]) == DefsScript.BEDROCK_BELOW:
			rock_per_ice = float(r[1])
	var k: float = float(rec.get("rate_k", 0.0))
	for s in range(steps):
		# 24 steps to a day, so the swing crosses freezing twice a day wherever the mean is near it.
		var t_c: float = mean_c + swing_c * sin(TAU * float(s) / 24.0)
		if t_c > LAPhysical.WATER_MELT_C:
			var melt: float = minf((t_c - LAPhysical.WATER_MELT_C) * LAPhaseRecords.MELT_RATE, snow)
			snow -= melt
			water += melt
		else:
			# R21 freezes bulk liquid; the frost record freezes the share of it that is inside the rock, and
			# that share is what does the damage.
			var below: float = LAPhysical.WATER_FREEZE_C - t_c
			var pore: float = minf(minf(below * k, water), pore_cap)
			pore = minf(pore, ROCK_BELOW / maxf(rock_per_ice, 1.0e-6))
			if pore > 0.0:
				water -= pore
				snow += pore
				removed += pore * rock_per_ice
			var bulk: float = minf(below * LAPhaseRecords.FREEZE_RATE, water)
			water -= bulk
			snow += bulk
	return removed


func run_test(_tree: SceneTree) -> bool:
	var recs: Array = GeoScript.records()
	var frost: Dictionary = {}
	var chem: Dictionary = {}
	for r in recs:
		if int(r.get("rate_model", -1)) == DefsScript.ARRHENIUS:
			chem = r
		elif int(r.get("rate_model", -1)) == DefsScript.DEFICIT_BELOW_THRESHOLD:
			frost = r
	if chem.is_empty() or frost.is_empty():
		push_error("weathering rate law: expected an ARRHENIUS record (chemical dissolution) and a "
			+ "DEFICIT_BELOW_THRESHOLD one (frost shattering) in LAGeoRecords; found neither or one.")
		return false

	var temps: PackedFloat64Array = PackedFloat64Array(
		[-40.0, -30.0, -20.0, -10.0, -2.0, 0.0, 5.0, 15.0, 25.0, 35.0, 60.0, 100.0])
	print("WEATHER_RATE_LAW={\"note\":\"bedrock removed per step at water %.2f, co2 %.3f, rock_below %.1f\"}"
		% [WATER_AT_CELL, CO2_AT_CELL, ROCK_BELOW])
	# GDScript's % has no %e, so scientific formatting goes through String.num_scientific.
	for t in temps:
		print("  T=%7.1f C   chemical=%s   frost=%s   old_law=%s" % [
			t, String.num_scientific(_rock_removed(chem, t)),
			String.num_scientific(_rock_removed(frost, t)),
			String.num_scientific(maxf(0.0, 20.0 - t) * 0.004)])

	var ok: bool = true

	# 1. CHEMICAL: monotone increasing in temperature, and ~2x per +10 C at room temperature.
	var prev: float = -1.0
	for t in temps:
		var v: float = _rock_removed(chem, t)
		if v < prev - 1.0e-18:
			push_error("chemical weathering is not monotone in temperature at %.1f C (%s < %s). "
				% [t, String.num_scientific(v), String.num_scientific(prev)] + "Arrhenius rises with temperature; a fall means the sign is backwards again.")
			ok = false
		prev = v
	var r25: float = _rock_removed(chem, 25.0)
	var r35: float = _rock_removed(chem, 35.0)
	var q10: float = r35 / maxf(r25, 1.0e-30)
	if q10 < 1.8 or q10 > 2.8:
		push_error("chemical weathering Q10 is %.2f, expected ~2.2 from a %.0f kJ/mol activation energy. "
			% [q10, LAPhysical.SILICATE_DISSOLUTION_EA_J_MOL / 1000.0]
			+ "Either the activation energy or the Arrhenius arithmetic has drifted.")
		ok = false

	# 2. FROST: exactly zero at and above the real freezing point, and NOT maximal at the cold extreme.
	if _rock_removed(frost, 0.0) != 0.0 or _rock_removed(frost, 15.0) != 0.0:
		push_error("frost shattering fires at or above %.1f C. Rock is broken by water FREEZING in it; "
			% LAPhysical.WATER_FREEZE_C + "above the freezing point no ice forms.")
		ok = false
	if _rock_removed(frost, -2.0) <= 0.0:
		push_error("frost shattering does nothing just below freezing, which is where it should be strongest.")
		ok = false
	# The extent is capped by the pore water available, so it plateaus rather than climbing with the cold —
	# the property the old law lacked. Deep cold may equal the near-freezing rate but must never exceed it.
	if _rock_removed(frost, -40.0) > _rock_removed(frost, -2.0) + 1.0e-12:
		push_error("frost shattering is FASTER at -40 C than at -2 C. It is capped by the pore water present, "
			+ "so it must plateau; a rise means the cap is not binding and the law is the old runaway again.")
		ok = false

	var swing: float = 8.0
	var means: PackedFloat64Array = PackedFloat64Array([-40.0, -20.0, -10.0, -5.0, 0.0, 5.0, 20.0])
	var damage: Dictionary = {}
	print("FROST_BAND={\"note\":\"cumulative bedrock removed over 480 steps, diurnal swing +/-%.0f C\"}" % swing)
	for tm in means:
		damage[tm] = _integrate_frost(frost, float(tm), swing, 480)
		print("  mean T=%7.1f C   cumulative frost damage=%s" % [tm, String.num_scientific(damage[tm])])
	if float(damage[20.0]) != 0.0:
		push_error("frost damage accumulates on ground that never freezes.")
		ok = false
	if float(damage[0.0]) <= float(damage[-40.0]) or float(damage[0.0]) <= float(damage[-20.0]):
		push_error("frost damage does not PEAK near 0 C: cycling ground (%s) took no more damage than "
			% String.num_scientific(damage[0.0]) + "permanently frozen ground (-40 C: %s, -20 C: %s). "
			% [String.num_scientific(damage[-40.0]), String.num_scientific(damage[-20.0])]
			+ "Frost shattering needs the pore water to thaw before it can freeze again.")
		ok = false

	# 3. NEITHER mechanism may reproduce the old runaway at the cold end.
	var old_at_minus18: float = (20.0 - -18.0) * 0.004        # 0.152 of the bedrock per step
	for r2 in [chem, frost]:
		if _rock_removed(r2, -18.0) >= old_at_minus18:
			push_error("a weathering record removes %s of bedrock per step at -18 C, at or above the old "
				% String.num_scientific(_rock_removed(r2, -18.0)) + "fitted law's %s. The runaway is back." % String.num_scientific(old_at_minus18))
			ok = false
	return ok
