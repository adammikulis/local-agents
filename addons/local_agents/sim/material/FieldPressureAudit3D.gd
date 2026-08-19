class_name LAFieldPressureAudit
extends RefCounted

## Pressure may not fall as you go DOWN: a decrease inward is the kernel contradicting gravity.
## A pure instrument -- it reads the drained mirrors and requests nothing.

## Inward neighbours holding a LOWER pressure.
static func inversions(f) -> Dictionary:
	var cc: int = int(f._cell_count)
	var out: Dictionary = {"pressure_inversions": null, "pressure_audited": null}
	if cc <= 0 or f._pressure.size() != cc:
		return out
	var bad: int = 0
	var audited: int = 0
	var rock: int = 0
	var air: int = 0
	var skin: int = 0
	# No reduce row can compare a cell with the one BELOW it, so this walks the drained mirror.
	for c in cc:
		var below: int = LAFieldGeometry.below(f, c)
		if below < 0:
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
				air += 1
			else:
				skin += 1
	out["pressure_inversions"] = bad
	out["pressure_audited"] = audited
	out["pressure_inv_rock"] = rock
	out["pressure_inv_air"] = air
	out["pressure_inv_skin"] = skin
	if bad > 0:
		print("PRESSURE_BROKEN=", JSON.stringify(out))
	return out
