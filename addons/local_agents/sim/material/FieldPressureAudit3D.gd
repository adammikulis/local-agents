class_name LAFieldPressureAudit
extends RefCounted

## Pressure may not fall as you go DOWN: a decrease inward is the kernel contradicting gravity.
## A pure instrument -- it reads the drained mirrors and requests nothing.
##
## ROCK OVER A VOID IS NOT COMPARED. A solid cell holds a lithostatic stress and an open one holds a gas
## pressure; the two are different quantities sharing a buffer by the decision CLAUDE.md records, so
## differencing them measures nothing. A cave roof at lithostatic over air at one atmosphere is why a deep
## mine needs support. Open-over-solid IS compared: the rock column starts from the fluid on it.

## Inward neighbours holding a LOWER pressure.
static func inversions(f) -> Dictionary:
	var cc: int = int(f._cell_count)
	var out: Dictionary = {"pressure_inversions": null, "pressure_audited": null}
	if cc <= 0 or f._pressure.size() != cc:
		return out
	var bad: int = 0
	var audited: int = 0
	var rock: int = 0
	var void_below: int = 0
	var surface: int = 0
	var wet: int = 0
	var dry: int = 0
	# No reduce row can compare a cell with the one BELOW it, so this walks the drained mirror.
	for c in cc:
		var below: int = LAFieldGeometry.below(f, c)
		if below < 0:
			continue
		if f._solid[c] != 0 and f._solid[below] == 0:
			continue
		var here: float = f._pressure[c]
		var deeper: float = f._pressure[below]
		if here <= 0.0 and deeper <= 0.0:
			continue
		audited += 1
		if deeper < here:
			bad += 1
			var s_here: bool = f._solid[c] != 0
			var s_deep: bool = f._solid[below] != 0
			if s_here and s_deep:
				rock += 1
			elif not s_here and not s_deep:
				# Which open pairs: condensed-packed (an ocean cell) or gas?
				if f._h2o[c] > 0.5 or f._h2o[below] > 0.5:
					wet += 1
				else:
					dry += 1
			elif s_here:
				void_below += 1     # rock standing over an open cell
			else:
				surface += 1        # open cell standing on rock
	out["pressure_inversions"] = bad
	out["pressure_audited"] = audited
	out["pressure_inv_rock"] = rock
	out["pressure_inv_void"] = void_below
	out["pressure_inv_surface"] = surface
	out["pressure_inv_wet"] = wet
	out["pressure_inv_dry"] = dry
	if bad > 0:
		print("PRESSURE_BROKEN=", JSON.stringify(out))
	return out
