class_name LAFieldPressureAudit
extends RefCounted

## Pressure may not fall as you go DOWN. A pure instrument over LAReducePressureRows' device rows: it
## requests nothing and reads no mirror.

## The pair classes, each carrying its own inversion count and the pairs that count was taken over.
const CLASSES: PackedStringArray = ["rock", "surface", "open"]

## Inward neighbours holding a LOWER pressure, per pair class. Null when any row is unmeasured.
## `pressure_empty` is the pairs the emptiness floor kept out: a cell the derive gives no bulk state
## has no pressure to compare, so the audit's population is the derive's own.
static func inversions(f) -> Dictionary:
	var out: Dictionary = {"pressure_inversions": null, "pressure_audited": null,
		"pressure_empty": null}
	var r: Dictionary = f._queries.reduced() if f != null and f._queries != null else {}
	var bad: int = 0
	var audited: int = 0
	var pairs: int = 0
	for cls: String in CLASSES:
		var inv: String = "pressure_inv_" + cls
		if not r.has(inv) or not r.has("pressure_aud_" + cls) or not r.has("pressure_pairs_" + cls):
			return out
		out[inv] = int(round(float(r[inv])))
		bad += int(out[inv])
		audited += int(round(float(r["pressure_aud_" + cls])))
		pairs += int(round(float(r["pressure_pairs_" + cls])))
	out["pressure_inversions"] = bad
	out["pressure_audited"] = audited
	out["pressure_empty"] = maxi(pairs - audited, 0)
	if bad > 0:
		print("PRESSURE_BROKEN=", JSON.stringify(out))
	return out
