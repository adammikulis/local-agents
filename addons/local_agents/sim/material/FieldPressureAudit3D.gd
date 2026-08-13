class_name LAFieldPressureAudit
extends RefCounted

## Pressure may not fall as you go DOWN: a decrease inward is the kernel contradicting gravity.
## A pure instrument -- it reads the drained mirrors and requests nothing.

## Inward neighbours holding a LOWER pressure, plus cells left negative by no column walk reaching them.
static func inversions(f) -> Dictionary:
	var out: Dictionary = {"pressure_inversions": 0, "pressure_audited": 0, "pressure_unwritten": 0}
	var cc: int = int(f._cell_count)
	if cc <= 0 or f._pressure.size() != cc:
		return out
	var unwritten: int = 0
	for c in cc:
		if f._pressure[c] < 0.0:
			unwritten += 1
	out["pressure_unwritten"] = unwritten
	var bad: int = 0
	var audited: int = 0
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
	out["pressure_inversions"] = bad
	out["pressure_audited"] = audited
	if bad > 0 or unwritten > 0:
		print("PRESSURE_BROKEN=", JSON.stringify(
			{"inversions": bad, "unwritten": unwritten, "audited": audited}))
	return out
