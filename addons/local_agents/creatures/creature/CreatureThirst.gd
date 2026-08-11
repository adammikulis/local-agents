class_name LACreatureThirst
extends RefCounted

## Thirst / water-seeking drive for LocalAgentCreature, factored out of the main brain. Emergent watering holes:
## nothing scripts where animals gather. They simply drink from, or walk toward, the nearest wet cell of
## the shared water field, so they cluster wherever water actually pools. Static + dynamic access on the
## passed creature so there is no cyclic class reference. (Explicit types only, no ':=' inferred typing.)

## Drinking rate as a multiple of the animal's own water turnover: a thirsty animal refills far faster than it
## loses, but a big animal drinks more per second than a small one, from the mass scaling in
## `LACreatureBodyMass.thirst_rate` rather than from a constant.
const DRINK_OVER_TURNOVER: float = 60.0
const THIRSTY_FRACTION: float = 0.5        # below this, seeking water interrupts other drives


## Thirst drive. Returns "" (not thirsty enough / no water known), "drink" (standing at water — refill in
## place) or "seek" (head toward the nearest water via the creature's _water_dir_cache).
##
## DRINKING EMPTIES THE PUDDLE. `is_water_at` is a PREDICATE and takes nothing, so the intake is debited out
## of the field's `water` (or, failing surface water, the groundwater underfoot) through LAMaterialFieldBiota3D,
## and the loss returns as vapour in LACreatureMetabolism.tick. Both legs of the H₂O ledger are real.
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


## THE ONE DRINKING PATH. Takes water OUT of the world at `pos` and puts exactly that much into the body.
## Every caller that refills hydration goes through here — the thirst drive above and the `drink` action in
## LACreatureThink — so there is one place where the debit can be missed, instead of two that both forgot.
## Returns what the animal actually got; a puddle that has been drunk dry gives nothing.
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
