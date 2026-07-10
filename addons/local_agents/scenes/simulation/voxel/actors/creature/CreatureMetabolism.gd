class_name LACreatureMetabolism
extends RefCounted

## Per-frame survival for LACreature, factored out of the hot _physics_process: energy metabolism, thirst,
## ageing, and environmental temperature/drowning read from the shared MaterialField. Static + dependency-free
## of the LACreature type (dynamic access, like the other Creature* helpers). Each tick returns TRUE if the
## creature DIED this frame — the caller must then stop processing it. (Explicit types only — no ':=' .)

# Temperature comfort band (°C), read from the field at the creature's feet. Between COOL and WARM costs
# nothing; beyond, heat parches + burns energy (past LETHAL → heatstroke), cold burns energy (past LETHAL →
# frozen); at COMBUST organic tissue catches fire. (Drowning/suffocation is its own rule — see tick_breath.)
const WARM_COMFORT: float = 28.0
const COOL_COMFORT: float = 8.0
const HEAT_THIRST_FACTOR: float = 0.15     # extra thirst/sec per °C above WARM_COMFORT
const HEAT_ENERGY_FACTOR: float = 0.08     # extra energy/sec burned per °C above WARM_COMFORT
const COLD_ENERGY_FACTOR: float = 0.15     # energy/sec burned per °C below COOL_COMFORT
const LETHAL_HEAT: float = 50.0            # °C at/above which it dies of heatstroke (no flame)
const COMBUST_TEMP: float = 200.0          # °C — organic tissue catches FIRE (in a wildfire/lava)
const LETHAL_COLD: float = -18.0           # °C at/below which it freezes
# Breathing (one emergent rule, read in TRUE 3D at the creature's head cell — no 2.5D column, no can_fly):
# a creature breathes its MEDIUM. LUNGS need breathable air (water OR smoke displacing O2 → can't breathe);
# GILLS need to be submerged (a beached gill-breather suffocates in air). Out of medium it burns its per-animal
# breath reserve (Creature.breath_capacity), refilling at BREATH_REFILL/sec back in it; at zero, SUFFOCATE_DRAIN
# kills fast. Big lungs = long dives to hunt. One rule → drowning + smoke/CO2 suffocation + beached fish.
const BREATHE_MIN_O2: float = 0.3          # O2 below this can't sustain a lung (water displaces it, or fire smoke)
const BREATH_REFILL: float = 25.0          # breath reserve refilled per sec while in the breathing medium
const SUFFOCATE_DRAIN: float = 45.0        # energy/sec once the breath reserve is exhausted — death comes fast


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


## Temperature comfort + combustion from the shared field at `pos`. Returns true if the creature died
## (combusted / heatstroke / frozen). Drowning/suffocation is now its own emergent rule — see tick_breath.
static func tick_environment(c, pos: Vector3, delta: float) -> bool:
	if c._material == null:
		return false
	var t: float = c._material.temp_at(pos)
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
	return false


## Breathing (emergent, TRUE 3D): a creature breathes its medium at its actual head cell — a LUNG needs
## breathable air (water OR smoke displacing O2 → can't breathe), a GILL needs to be submerged. It burns a
## per-animal breath reserve out of medium and suffocates when it runs out; a big breath_capacity = long dives.
## Altitude falls out of the 3D read (a bird high above water reads air; a diver's head cell reads water) — no
## depth column, no can_fly. Returns true if the creature died. One rule = drowning + smoke + beached gills.
static func tick_breath(c, pos: Vector3, delta: float) -> bool:
	if c._material == null:
		return false
	var head_y: float = pos.y + c.size          # read at the head, in true 3D
	var can_breathe: bool
	if c.breathes == "water":
		can_breathe = c._material.is_submerged_at(pos.x, head_y, pos.z)              # gills: must be in water
	else:
		can_breathe = c._material.breathable_o2_at(pos.x, head_y, pos.z) >= BREATHE_MIN_O2   # lungs: need air
	if can_breathe:
		c._breath = minf(c._breath + BREATH_REFILL * delta, c.breath_capacity)
		return false
	# Out of medium: hold breath from the reserve, then suffocate hard once it is spent.
	c._breath -= delta
	if c._breath <= 0.0:
		c.energy -= SUFFOCATE_DRAIN * delta
		if c.energy <= 0.0:
			var drowned: bool = c.breathes != "water" and c._material.is_submerged_at(pos.x, head_y, pos.z)
			c.die("drowned" if drowned else "suffocated")
			return true
	return false
