class_name LASituationSignature
extends RefCounted


const ENERGY_BUCKETS: int = 4      # starving / low / ok / full
const HYDRATION_BUCKETS: int = 3   # parched / thirsty / ok


static func energy_bucket(frac: float) -> int:
	if frac < 0.25:
		return 0
	if frac < 0.5:
		return 1
	if frac < 0.85:
		return 2
	return 3


static func hydration_bucket(frac: float) -> int:
	if frac < 0.3:
		return 0
	if frac < 0.6:
		return 1
	return 2


static func compute(c) -> Dictionary:
	# Reads are DUCK-TYPED via Object.get (returns null for a missing property, never errors) so an aquatic
	# actor that lacks a land-only field (e.g. a fish with no hydration) still computes a valid signature. For a
	# land creature every read resolves to the exact same value it always did — behaviour is identical.
	var max_e = c.get("max_energy")
	var e_frac: float = 0.0
	if max_e != null and float(max_e) > 0.0:
		e_frac = clampf(float(c.get("energy")) / float(max_e), 0.0, 1.0)
	var max_h = c.get("max_hydration")
	var h_frac: float = 0.0
	if max_h != null and float(max_h) > 0.0:
		h_frac = clampf(float(c.get("hydration")) / float(max_h), 0.0, 1.0)
	var e: int = energy_bucket(e_frac)
	var h: int = hydration_bucket(h_frac)

	var mat = c.get("_material")
	var at_water: int = 0
	if mat != null and mat.has_method("is_water_at"):
		if mat.is_water_at(c.global_position):
			at_water = 1
	var eco = c.get("_ecology")
	var night: int = 0
	if eco != null and eco.has_method("is_night_at") and eco.is_night_at(c.global_position):
		night = 1

	var key: int = ((e * HYDRATION_BUCKETS + h) * 2 + at_water) * 2 + night
	var text: String = "e%d/h%d/%s/%s" % [
		e, h,
		"wet" if at_water == 1 else "dry",
		"night" if night == 1 else "day",
	]
	return {"key": key, "text": text, "e": e, "h": h, "w": at_water, "n": night}
