class_name LACreatureThirst
extends RefCounted

## Thirst / water-seeking drive for LACreature, factored out of the main brain. Emergent watering holes:
## nothing scripts where animals gather — they simply drink from, or walk toward, the nearest wet cell of
## the shared water field, so they cluster wherever water actually pools. Static + dynamic access on the
## passed creature so there is no cyclic class reference. (Explicit types only — no ':=' typing.)

const DRINK_RATE: float = 45.0             # hydration/sec restored while drinking (mirrors LACreature.DRINK_RATE)
const THIRSTY_FRACTION: float = 0.5        # below this, seeking water interrupts other drives


## Thirst drive. Returns "" (not thirsty enough / no water known), "drink" (standing at water — refill in
## place) or "seek" (head toward the nearest water via the creature's _water_dir_cache).
static func handle_thirst(c, pos: Vector3, delta: float) -> String:
	if c._material == null or not c._material.has_method("is_water_at"):
		return ""
	if c.hydration >= c.max_hydration * THIRSTY_FRACTION:
		return ""
	if c._material.is_water_at(pos.x, pos.z):
		c.hydration = minf(c.max_hydration, c.hydration + DRINK_RATE * delta)
		return "drink"
	c._water_search_cd -= delta
	if c._water_search_cd <= 0.0:
		c._water_search_cd = 0.5
		c._water_dir_cache = find_water_dir(c, pos)
	if c._water_dir_cache != Vector3.ZERO:
		return "seek"
	return ""


## Probe rings of increasing radius for the nearest wet cell and return a flat unit heading toward it, or
## ZERO if no water is within reach. Cheap: index-math queries.
static func find_water_dir(c, pos: Vector3) -> Vector3:
	if c._material == null or not c._material.has_method("is_water_at"):
		return Vector3.ZERO
	var radii: Array = [c.sense_radius, c.sense_radius * 2.0, c.sense_radius * 3.5]
	var dirs: int = 12
	for r in radii:
		for k in range(dirs):
			var ang: float = TAU * float(k) / float(dirs)
			var px: float = pos.x + cos(ang) * float(r)
			var pz: float = pos.z + sin(ang) * float(r)
			if c._material.is_water_at(px, pz):
				var d: Vector3 = Vector3(px - pos.x, 0.0, pz - pos.z)
				if d.length() > 0.001:
					return d.normalized()
	return Vector3.ZERO
