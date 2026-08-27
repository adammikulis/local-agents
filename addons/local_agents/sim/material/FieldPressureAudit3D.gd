class_name LAFieldPressureAudit
extends RefCounted

## Pressure may not fall as you go DOWN. A pure instrument over LAReducePressureRows' device rows: it
## requests nothing and reads no mirror.

## The pair classes, each carrying its own inversion count and the pairs that count was taken over.
const CLASSES: PackedStringArray = ["rock", "surface", "open"]

## Inward neighbours holding a LOWER pressure, per pair class. Null when any row is unmeasured.
static func inversions(f) -> Dictionary:
	var out: Dictionary = {"pressure_inversions": null, "pressure_audited": null}
	var r: Dictionary = f._queries.reduced() if f != null and f._queries != null else {}
	var bad: int = 0
	var audited: int = 0
	for cls: String in CLASSES:
		var inv: String = "pressure_inv_" + cls
		var aud: String = "pressure_aud_" + cls
		if not r.has(inv) or not r.has(aud):
			return out
		out[inv] = int(round(float(r[inv])))
		bad += int(out[inv])
		audited += int(round(float(r[aud])))
	out["pressure_inversions"] = bad
	out["pressure_audited"] = audited
	if bad > 0:
		print("PRESSURE_BROKEN=", JSON.stringify(out))
	return out
