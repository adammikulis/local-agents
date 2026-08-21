extends SceneTree

## THE COMPOSITION GATE'S RUNNER. Rebuilds the planet's elemental mass fractions from what the seed
## lays down — LAPlanetComposition's proportions, LASubstances' formulas and traces — and holds them
## against the cited registry (LAElementAbundances): core vs the core model, shell vs the silicate
## Earth, their mass-weighted sum vs bulk Earth. A drifted formula, trace map or solve goes red here.
## Prints ELEMENT_COMPOSITION={"elements":N,"violations":M} last; zero elements must FAIL. No ':='.

## Relative tolerance per element: the reconciliation spread between the independently derived
## reservoir tables (McDonough 2003).
const TOL: float = 0.10

var _violations: int = 0
var _elements: int = 0


## Reconstruct kg of each element per kg of a reservoir built from `parts` (id -> kg/kg).
func _reconstruct(parts: Dictionary) -> Dictionary:
	var table: Dictionary = LASubstances.table()
	var out: Dictionary = {}
	for id in parts:
		var w: float = float(parts[id])
		var s: Dictionary = table.get(String(id), {})
		var fr: Dictionary = LAElementAbundances.mass_fractions(s.get("formula", {}))
		for el in fr:
			out[el] = float(out.get(el, 0.0)) + w * float(fr[el])
		var tr: Dictionary = s.get("traces", {})
		for el2 in tr:
			out[el2] = float(out.get(el2, 0.0)) + w * float(tr[el2])
	return out


func _check(label: String, got: Dictionary, want: Dictionary) -> void:
	for el in want:
		_elements += 1
		var w: float = float(want[el])
		var g: float = float(got.get(el, 0.0))
		if w <= 0.0:
			continue
		var rel: float = absf(g - w) / w
		if rel > TOL:
			_violations += 1
			print("ELEMENT_COMPOSITION_VIOLATION=%s" % JSON.stringify({
				"reservoir": label, "element": String(el), "seeded_kg_per_kg": g,
				"registry_kg_per_kg": w, "rel_error": snappedf(rel, 0.001), "tolerance": TOL}))


func _init() -> void:
	var shell: Dictionary = LAPlanetComposition.shell_minerals()
	if shell.is_empty():
		print("ELEMENT_COMPOSITION_ERROR: the normative solve produced no mineral proportions.")
		print('ELEMENT_COMPOSITION={"elements":0,"violations":-1}')
		quit(2)
		return
	# The core as the SUBSTANCE TABLE carries it — formula and trace map both — against the core model.
	var core: Dictionary = _reconstruct({"metal": 1.0})
	_check("core", core, LAElementAbundances.CORE)

	var shell_got: Dictionary = _reconstruct(shell)
	_check("silicate_earth", shell_got, LAElementAbundances.SILICATE_EARTH)

	var f_core: float = LAElementAbundances.CORE_MASS_FRACTION
	var bulk: Dictionary = {}
	for el4 in core:
		bulk[el4] = f_core * float(core[el4])
	for el5 in shell_got:
		bulk[el5] = float(bulk.get(el5, 0.0)) + (1.0 - f_core) * float(shell_got[el5])
	_check("bulk_earth", bulk, LAElementAbundances.BULK_EARTH)

	print("ELEMENT_COMPOSITION=" + JSON.stringify({"elements": _elements,
		"violations": _violations}))
	quit(0 if _violations == 0 and _elements > 0 else 1)
