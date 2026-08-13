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
	if model == DefsScript.RM_DEFICIT_BELOW_THRESHOLD:
		x = maxf(0.0, thr - t_c) * k
	elif model == DefsScript.RM_EXCESS_OVER_THRESHOLD:
		x = maxf(0.0, t_c - thr) * k
	elif model == DefsScript.RM_ARRHENIUS:
		# Same expression as the kernel, including the temperature ceiling, which comes off the record as
		# `t_ceiling_k` (zero means none) rather than being hardcoded to water's boiling point.
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
## the record's bedrock coefficient is.
func _rock_removed(rec: Dictionary, t_c: float) -> float:
	var x: float = _extent(rec, t_c)
	for r in rec.get("reactants", []):
		if int(r[0]) == DefsScript.BEDROCK_BELOW:
			return x * float(r[1])
	return 0.0




func run_test(_tree: SceneTree) -> bool:
	var recs: Array = GeoScript.records()
	var chem: Dictionary = {}
	for r in recs:
		if int(r.get("rate_model", -1)) == DefsScript.RM_ARRHENIUS:
			chem = r
	if chem.is_empty():
		push_error("weathering rate law: LAGeoRecords carries no RM_ARRHENIUS record, so chemical "
			+ "dissolution is not modelled at all.")
		return false

	var temps: PackedFloat64Array = PackedFloat64Array(
		[-40.0, -30.0, -20.0, -10.0, -2.0, 0.0, 5.0, 15.0, 25.0, 35.0, 60.0, 100.0])
	print("WEATHER_RATE_LAW={\"note\":\"bedrock removed per step at water %.2f, co2 %.3f, rock_below %.1f\"}"
		% [WATER_AT_CELL, CO2_AT_CELL, ROCK_BELOW])
	# GDScript's % has no %e, so scientific formatting goes through String.num_scientific.
	for t in temps:
		print("  T=%7.1f C   chemical=%s   old_law=%s" % [
			t, String.num_scientific(_rock_removed(chem, t)),
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

	# 2. The record may not reproduce the old fitted runaway at the cold end.
	var old_at_minus18: float = (20.0 - -18.0) * 0.004        # 0.152 of the bedrock per step
	for r2 in [chem]:
		if _rock_removed(r2, -18.0) >= old_at_minus18:
			push_error("a weathering record removes %s of bedrock per step at -18 C, at or above the old "
				% String.num_scientific(_rock_removed(r2, -18.0)) + "fitted law's %s. The runaway is back." % String.num_scientific(old_at_minus18))
			ok = false
	return ok
