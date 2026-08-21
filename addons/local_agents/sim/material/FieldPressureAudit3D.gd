class_name LAFieldPressureAudit
extends RefCounted

## Pressure may not fall as you go DOWN. A pure instrument over LAReducePressureRows' device rows: it
## requests nothing and reads no mirror.

## Inward neighbours holding a LOWER pressure, per pair class. Null when any row is unmeasured.
static func inversions(f) -> Dictionary:
	var out: Dictionary = {"pressure_inversions": null, "pressure_audited": null}
	var r: Dictionary = f._queries.reduced() if f != null and f._queries != null else {}
	var bad: int = 0
	var audited: int = 0
	for key: String in ["pressure_aud_rock", "pressure_aud_surface", "pressure_aud_open"]:
		if not r.has(key):
			return out
		audited += int(round(float(r[key])))
	for key: String in ["pressure_inv_rock", "pressure_inv_surface", "pressure_inv_wet", "pressure_inv_dry"]:
		if not r.has(key):
			return out
		out[key] = int(round(float(r[key])))
		bad += int(out[key])
	out["pressure_inversions"] = bad
	out["pressure_audited"] = audited
	if bad > 0:
		print("PRESSURE_BROKEN=", JSON.stringify(out))
	return out
