class_name LACreatureThirst
extends RefCounted


const DRINK_OVER_TURNOVER: float = 60.0
const THIRSTY_FRACTION: float = 0.5        # below this, seeking water interrupts other drives


static func handle_thirst(c, pos: Vector3, delta: float) -> String:
	if c._material == null or not c._material.has_method("is_water_at"):
		return ""
	if c.hydration >= c.max_hydration * THIRSTY_FRACTION:
		return ""
	if c._material.is_water_at(pos):
		drink(c, pos, delta)
		return "drink"
	c._water_search_cd -= delta
	if c._water_search_cd <= 0.0:
		c._water_search_cd = 0.5
		c._water_dir_cache = find_water_dir(c, pos)
	if c._water_dir_cache != Vector3.ZERO:
		return "seek"
	return ""


static func drink(c, pos: Vector3, delta: float) -> float:
	if c == null or delta <= 0.0:
		return 0.0
	var want: float = minf(float(c.thirst_rate) * DRINK_OVER_TURNOVER * delta,
		maxf(0.0, float(c.max_hydration) - float(c.hydration)))
	if want <= 0.0:
		return 0.0
	if c._material == null or not c._material.has_method("drink_water"):
		return 0.0
	var got: float = c._material.drink_water(pos, want)
	c.hydration = minf(c.max_hydration, c.hydration + got)
	return got


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
			var probe: Vector3 = Vector3(pos.x + cos(ang) * float(r), pos.y, pos.z + sin(ang) * float(r))
			if c._material.is_water_at(probe):
				var d: Vector3 = probe - pos
				d.y = 0.0
				if d.length() > 0.001:
					return d.normalized()
	return Vector3.ZERO
