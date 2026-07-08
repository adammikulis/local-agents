class_name LACreatureMetabolism
extends RefCounted

## Per-frame survival for LACreature, factored out of the hot _physics_process: energy metabolism, thirst,
## ageing, and environmental temperature/drowning read from the shared MaterialField. Static + dependency-free
## of the LACreature type (dynamic access, like the other Creature* helpers). Each tick returns TRUE if the
## creature DIED this frame — the caller must then stop processing it. (Explicit types only — no ':=' .)

# Temperature comfort band (°C), read from the field at the creature's feet. Between COOL and WARM costs
# nothing; beyond, heat parches + burns energy (past LETHAL → heatstroke), cold burns energy (past LETHAL →
# frozen); at COMBUST organic tissue catches fire. Submersion past DROWN_DEPTH drains energy fast.
const WARM_COMFORT: float = 28.0
const COOL_COMFORT: float = 8.0
const HEAT_THIRST_FACTOR: float = 0.15     # extra thirst/sec per °C above WARM_COMFORT
const HEAT_ENERGY_FACTOR: float = 0.08     # extra energy/sec burned per °C above WARM_COMFORT
const COLD_ENERGY_FACTOR: float = 0.15     # energy/sec burned per °C below COOL_COMFORT
const LETHAL_HEAT: float = 50.0            # °C at/above which it dies of heatstroke (no flame)
const COMBUST_TEMP: float = 200.0          # °C — organic tissue catches FIRE (in a wildfire/lava)
const LETHAL_COLD: float = -18.0           # °C at/below which it freezes
const DROWN_DEPTH: float = 2.5             # water depth a non-flyer drowns in
const DROWN_DRAIN: float = 40.0            # energy/sec lost while submerged


## Energy metabolism (exertion-scaled) + thirst + ageing. Returns true if the creature died (starve/thirst/age).
static func tick(c, delta: float) -> bool:
	# Metabolism drains energy; exertion costs more, sleeping costs less; eating (elsewhere) refills.
	var exertion: float = 1.0
	if c.state == "flee" or c.state == "panic" or c.state == "chase":
		exertion = 1.6
	elif c.state == "sleep" or c.state == "rest" or c.state == "roost":
		exertion = 0.5                        # sleeping/resting conserves energy — why animals do it
	c.energy -= c.metabolism * exertion * delta
	if c.energy <= 0.0:
		c.die("starvation")
		return true
	# Thirst drains steadily; dehydration kills like starvation. Drinking (elsewhere) refills it.
	c.hydration -= c.thirst_rate * delta
	if c.hydration <= 0.0:
		c.die("thirst")
		return true
	if c.age >= c.max_age:
		c.die("old age")
		return true
	return false


## Temperature comfort + combustion + drowning from the shared field at `pos`. Returns true if the creature
## died (combusted / heatstroke / frozen / drowned).
static func tick_environment(c, pos: Vector3, delta: float) -> bool:
	if c._material == null:
		return false
	var t: float = c._material.temp_at(pos.x, pos.z)
	# Flesh doesn't glow like hot metal — it COMBUSTS. In fire/lava heat the creature bursts into flame and
	# dies burned (organic matter ignites; inorganic ground glows via the shader instead).
	if t >= COMBUST_TEMP:
		c._combust()
		return true
	if t > WARM_COMFORT:
		var over: float = t - WARM_COMFORT
		c.hydration -= over * HEAT_THIRST_FACTOR * delta   # heat parches → seek water (existing drive)
		c.energy -= over * HEAT_ENERGY_FACTOR * delta
		if t >= LETHAL_HEAT:
			c.die("heatstroke")
			return true
	elif t < COOL_COMFORT:
		c.energy -= (COOL_COMFORT - t) * COLD_ENERGY_FACTOR * delta
		if t <= LETHAL_COLD:
			c.die("frozen")
			return true
	if not c.can_fly and c._material.depth_at(pos.x, pos.z) >= DROWN_DEPTH:
		c.energy -= DROWN_DRAIN * delta
		if c.energy <= 0.0:
			c.die("drowned")
			return true
	return false
