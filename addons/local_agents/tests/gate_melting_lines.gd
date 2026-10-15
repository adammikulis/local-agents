extends SceneTree

## Every melting line the table carries, read by LASubstances.melt_c_at, against a point its source
## publishes, and every Clapeyron line against T dv / L_fus off the table's own two phases.

## (substance, pressure Pa, melting point K, tolerance K, source).
const PUBLISHED: Array = [
	["n2", 2.25e9, 287.0, 0.5, "Span et al. 2000: 2.25 GPa at 287 K"],
	["n2", 6.8e7, 77.0, 0.2, "Span et al. 2000: 68 MPa at 77 K"],
	["co2", 1.8207591e8, 250.0, 0.05, "Span & Wagner 1996 melting equation at 250 K"],
	["co2", 5.4844742e8, 300.0, 0.05, "Span & Wagner 1996 melting equation at 300 K"],
	["ch4", 2.8077331e8, 150.0, 0.05, "Abramson 2011 Simon equation at 150 K"],
	["o2", 5.0997880e7, 60.0, 0.05, "Younglove 1982 Simon equation at 60 K"],
	["co", 5.7548516e7, 80.0, 0.05, "Barreiros et al. 1982 Simon equation at 80 K"],
]
const CLAPEYRON: Array = ["olivine", "pyroxene", "halite", "metal"]

func _init() -> void:
	var failures: int = 0
	var asked: int = 0
	for row in PUBLISHED:
		asked += 1
		var t_k: float = LASubstances.melt_c_at(String(row[0]), float(row[1])) + LAPhysical.KELVIN_OFFSET
		if not (absf(t_k - float(row[2])) <= float(row[3])):
			failures += 1
			printerr("%s melts at %.3f K at %s Pa; %s" % [row[0], t_k, row[1], row[4]])
	for id in CLAPEYRON:
		asked += 1
		var s: Dictionary = LASubstances.table()[id]
		var t_m: float = float(s["melt_c"])
		var p_ref: float = float(s["melt_p_pa"])
		var eps: float = 1.0e-3
		var v_s: float = 1.0 / LASubstances.density(id, t_m - eps, p_ref)
		var v_l: float = 1.0 / LASubstances.density(id, t_m + eps, p_ref)
		var want: float = (t_m + LAPhysical.KELVIN_OFFSET) * (v_l - v_s) / float(s["latent_fusion_j_kg"])
		var dp: float = 1.0e8
		var got: float = (LASubstances.melt_c_at(id, p_ref + dp) - LASubstances.melt_c_at(id, p_ref)) / dp
		if not (absf(got - want) <= absf(want) * 1.0e-3):
			failures += 1
			printerr("%s melting slope %s K/Pa against T dv / L_fus %s" % [id, got, want])
	print('MELTING_LINES={"asked":%d,"failures":%d}' % [asked, failures])
	quit(1 if failures > 0 else 0)
