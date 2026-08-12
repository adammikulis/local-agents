class_name LAMixtureEnthalpy
extends RefCounted

## A CELL IS NOT A SUBSTANCE. Rock, water and air sit in one cell at ONE temperature; LASubstances answers
## per substance and in J/kg. This sums their curves by mass and inverts. `n_gas_mol` is the cell's moles
## of gas that cannot condense here.

const S: GDScript = preload("res://addons/local_agents/sim/material/Substances.gd")
const PC: GDScript = preload("res://addons/local_agents/sim/material/PhysicalConstants.gd")

## Where this substance's last condensed phase leaves: the frost point below the triple-point pressure,
## the boiling point above it.
static func vapour_boundary_c(id: String, p_pa: float) -> float:
	if S.sublimes_at(id, p_pa):
		return S.sublimation_c_at(id, p_pa)
	return S.boil_c_at(id, p_pa)


## The vapour pressure of the phase actually present: sublimation while the condensate is solid, saturation
## once it is liquid. ONE owner per boundary, both read off this table — the Magnus fit is not consulted.
static func vapour_p_at(id: String, t_c: float, p_pa: float) -> float:
	var melt: float = S.melt_c_at(id, p_pa)
	if S.sublimes_at(id, p_pa) or (is_finite(melt) and t_c < melt):
		return S.sublimation_p_at(id, t_c)
	return S.saturation_p_at(id, t_c)


## Latent heat to take the condensed phase present at this temperature into the vapour, J/kg.
static func latent_out_of_condensed(id: String, t_c: float, p_pa: float) -> float:
	var melt: float = S.melt_c_at(id, p_pa)
	if S.sublimes_at(id, p_pa) or (is_finite(melt) and t_c < melt):
		return S.latent_sublimation_j_kg(id)
	return S.latent_vaporisation_at(id, t_c)


## THE SATURATION SPLIT, by Dalton at the cell's TOTAL pressure: n_v / n_gas = p_v / (p - p_v). When p_v
## reaches p there is no room for anything else and the condensate is gone — that is what boiling IS.
static func vapour_fraction(id: String, t_c: float, p_pa: float, m_kg: float,
		n_gas_mol: float) -> float:
	if m_kg <= 0.0 or p_pa <= 0.0:
		return 0.0
	var vap_t: float = vapour_boundary_c(id, p_pa)
	if not is_finite(vap_t):
		return 0.0
	# STRICTLY above: at the boundary itself the Dalton form decides, so the value stays the LOWER end
	# of any jump there — the convention the boundary walk counts on.
	if t_c > vap_t:
		return 1.0
	if n_gas_mol <= 0.0:
		return 0.0
	var p_v: float = vapour_p_at(id, t_c, p_pa)
	if p_v <= 0.0:
		return 0.0
	if p_v >= p_pa:
		return 1.0
	var mm: float = float(S.table().get(id, {}).get("molar_mass", 0.0))
	if mm <= 0.0:
		return 0.0
	return minf(n_gas_mol * p_v / (p_pa - p_v) * mm / m_kg, 1.0)


## Specific enthalpy of one substance AS IT SITS IN THIS CELL: its own curve plus the latent heat of the
## share held as vapour. Above the vapour boundary the curve already carries it.
static func specific_enthalpy(id: String, t_c: float, p_pa: float, m_kg: float,
		n_gas_mol: float) -> float:
	var h: float = S.enthalpy_at(id, t_c, p_pa)
	var vap_t: float = vapour_boundary_c(id, p_pa)
	if not is_finite(vap_t) or t_c > vap_t:
		return h
	var f_v: float = vapour_fraction(id, t_c, p_pa, m_kg, n_gas_mol)
	if f_v <= 0.0:
		return h
	return h + f_v * latent_out_of_condensed(id, t_c, p_pa)


## Total enthalpy of the cell at a temperature, J.
static func enthalpy_at(masses: Dictionary, n_gas_mol: float, t_c: float, p_pa: float) -> float:
	var h: float = 0.0
	for id in masses:
		var m: float = float(masses[id])
		if m > 0.0:
			h += m * specific_enthalpy(id, t_c, p_pa, m, n_gas_mol)
	return h


## Every phase boundary of every substance present at this pressure, ascending and deduplicated.
static func breakpoints(masses: Dictionary, p_pa: float) -> Array[float]:
	var out: Array[float] = []
	for id in masses:
		if float(masses[id]) <= 0.0:
			continue
		for t in [S.melt_c_at(id, p_pa), S.liquidus_c_at(id, p_pa), vapour_boundary_c(id, p_pa),
				float(S.table().get(id, {}).get("critical_t_c", INF))]:
			if is_finite(t) and not out.has(t):
				out.append(float(t))
	out.sort()
	return out


## The height of the discontinuity at a boundary, J: the latent heat of whatever is still CONDENSED there.
## The boiling step vanishes when non-condensable gas is present — the vapour share reaches one smoothly.
static func jump_at(masses: Dictionary, n_gas_mol: float, t_b: float, p_pa: float) -> Dictionary:
	var per_id: Dictionary = {}
	var total: float = 0.0
	for id in masses:
		var m: float = float(masses[id])
		if m <= 0.0:
			continue
		var j: float = 0.0
		var solidus: float = S.melt_c_at(id, p_pa)
		var liquidus: float = S.liquidus_c_at(id, p_pa)
		if is_finite(solidus) and is_equal_approx(solidus, t_b) and is_equal_approx(liquidus, t_b):
			var l_fus: float = float(S.table().get(id, {}).get("latent_fusion_j_kg", 0.0))
			j += m * (1.0 - vapour_fraction(id, t_b, p_pa, m, n_gas_mol)) * l_fus
		var vap_t: float = vapour_boundary_c(id, p_pa)
		if is_finite(vap_t) and is_equal_approx(vap_t, t_b) and n_gas_mol <= 0.0:
			j += m * latent_out_of_condensed(id, t_b, p_pa)
		if j > 0.0:
			per_id[id] = j
			total += j
	return {"total": total, "per_id": per_id}


## THE CELL'S TEMPERATURE from its total enthalpy, ITERATIVE and not closed form: a condensable substance
## is split by its saturation curve, which carries exp(-L / R_v T). Boundaries are walked, a jump the
## enthalpy lands inside PINS the temperature, and the smooth stretch between them is bracketed and solved.
static func state(masses: Dictionary, n_gas_mol: float, h_total_j: float,
		p_pa: float) -> Dictionary:
	var lo: float = -PC.KELVIN_OFFSET
	var h_lo: float = enthalpy_at(masses, n_gas_mol, lo, p_pa)
	if h_total_j <= h_lo:
		return _report(masses, n_gas_mol, lo, p_pa, {}, false)
	var hi: float = INF
	for t_b in breakpoints(masses, p_pa):
		if t_b <= lo:
			continue
		var h_b: float = enthalpy_at(masses, n_gas_mol, t_b, p_pa)
		if h_total_j <= h_b:
			hi = t_b
			break
		var jump: Dictionary = jump_at(masses, n_gas_mol, t_b, p_pa)
		var top: float = h_b + float(jump["total"])
		if h_total_j < top:
			return _pinned(masses, n_gas_mol, t_b, p_pa, jump, h_total_j - h_b)
		lo = t_b
		h_lo = top
	if not is_finite(hi):
		# Past the last boundary the curve only rises, so doubling the span always finds the far end.
		var span: float = 100.0
		for _i in range(64):
			hi = lo + span
			if enthalpy_at(masses, n_gas_mol, hi, p_pa) >= h_total_j:
				break
			span *= 2.0
	return _report(masses, n_gas_mol, _solve(masses, n_gas_mol, h_total_j, p_pa, lo, hi),
		p_pa, {}, false)


## Illinois false position over a bracket the boundary walk already proved. Exact in one step on a linear
## segment; the halving keeps an end from sticking where the saturation split makes it curve.
static func _solve(masses: Dictionary, n_gas_mol: float, h_total_j: float, p_pa: float,
		lo: float, hi: float) -> float:
	var a: float = lo
	var b: float = hi
	var f_a: float = enthalpy_at(masses, n_gas_mol, a, p_pa) - h_total_j
	var f_b: float = enthalpy_at(masses, n_gas_mol, b, p_pa) - h_total_j
	var t: float = a
	var width: float = b - a
	for _i in range(120):
		var denom: float = f_b - f_a
		t = a - f_a * (b - a) / denom if absf(denom) > 0.0 else 0.5 * (a + b)
		t = clampf(t, a, b)
		var f_t: float = enthalpy_at(masses, n_gas_mol, t, p_pa) - h_total_j
		if f_t > 0.0:
			b = t
			f_b = f_t
			f_a *= 0.5
		else:
			a = t
			f_a = f_t
			f_b *= 0.5
		if b - a >= width:
			break
		width = b - a
	return t


## DECISION, not a law: two substances sharing a boundary split the residual by latent capacity. Nothing
## on this planet melts at another substance's melting point.
static func _pinned(masses: Dictionary, n_gas_mol: float, t_b: float, p_pa: float,
		jump: Dictionary, residual_j: float) -> Dictionary:
	var per_id: Dictionary = jump["per_id"]
	var total: float = float(jump["total"])
	var share: Dictionary = {}
	for id in per_id:
		share[id] = clampf(residual_j / total, 0.0, 1.0) if total > 0.0 else 0.0
	return _report(masses, n_gas_mol, t_b, p_pa, share, true)


static func _report(masses: Dictionary, n_gas_mol: float, t_c: float, p_pa: float,
		pinned_share: Dictionary, pinned: bool) -> Dictionary:
	var melted: Dictionary = {}
	var vaporised: Dictionary = {}
	for id in masses:
		var m: float = float(masses[id])
		if m <= 0.0:
			continue
		var solidus: float = S.melt_c_at(id, p_pa)
		var liquidus: float = S.liquidus_c_at(id, p_pa)
		var f_m: float = 1.0
		if is_finite(solidus):
			if t_c <= solidus:
				f_m = 0.0
			elif t_c < liquidus:
				f_m = (t_c - solidus) / (liquidus - solidus)
		var f_v: float = vapour_fraction(id, t_c, p_pa, m, n_gas_mol)
		if pinned_share.has(id):
			var vap_t: float = vapour_boundary_c(id, p_pa)
			if is_finite(vap_t) and is_equal_approx(vap_t, t_c):
				f_v = float(pinned_share[id])
			else:
				f_m = float(pinned_share[id])
		melted[id] = f_m
		vaporised[id] = f_v
	return {"t_c": t_c, "pinned": pinned, "melted": melted, "vaporised": vaporised}
