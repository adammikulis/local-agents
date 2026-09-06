class_name LACreatureThirst
extends RefCounted


## An animal at a waterhole takes a whole day's water in one bout of a few minutes: a camel drinks about
## 100 litres in ten (Schmidt-Nielsen 1964, Desert Animals, ch.3). The mouth rate is the daily turnover
## the body loses over that bout.
const DRINK_BOUT_S: float = 300.0
const THIRSTY_FRACTION: float = 0.5        # below this, seeking water interrupts other drives


## Moles of H2O a second a drinking animal takes in.
static func drink_rate(c) -> float:
	return float(c.thirst_rate) * LACreatureBodyMass.SECONDS_PER_DAY / DRINK_BOUT_S


## An animal standing in water drinks, whatever else it is doing: only SEEKING water competes with
## fleeing or foraging, and this runs on the body's clock, not on the stride its decisions run at.
static func sip(c, pos: Vector3, delta: float) -> void:
	if c._material == null or not c._material.has_method("is_water_at"):
		return
	if c.hydration >= c.max_hydration * THIRSTY_FRACTION:
		return
	if LAFakes.stands_in("drinking_water") or c._material.is_water_at(pos):
		drink(c, pos, delta)


static func handle_thirst(c, pos: Vector3, delta: float) -> String:
	if c._material == null or not c._material.has_method("is_water_at"):
		return ""
	if c.hydration >= c.max_hydration * THIRSTY_FRACTION:
		return ""
	# Wet ground is everywhere on a rained-on world, so while rain is faked there is always a drink here.
	if c._material.is_water_at(pos) or LAFakes.stands_in("drinking_water"):
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
	var want: float = minf(drink_rate(c) * delta,
		maxf(0.0, float(c.max_hydration) - float(c.hydration)))
	if want <= 0.0:
		return 0.0
	if c._material == null or not c._material.has_method("drink_water"):
		return 0.0
	var got: float = c._material.drink_water(pos, want)
	if got < want:
		got += LAFakes.draw("drinking_water", want - got)
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
