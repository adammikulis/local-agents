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
# Old-age FRAILTY (senescence-driven mortality — see LACreatureSenescence). Past FRAILTY_ONSET on the 0..1
# senescence factor, failing resilience drains health at up to FRAILTY_HP_FRAC of max_health/sec (scaled by how
# far past onset), so an old, worn-out animal dies of "old age" — sooner if it is also stressed/hurt. A hard
# backstop at factor 1.0 (age == the effective max_age) guarantees death even for an unstressed elder.
const FRAILTY_ONSET: float = 0.5           # senescence factor above which frailty begins draining health
const FRAILTY_HP_FRAC: float = 0.06        # fraction of max_health drained per second at full (factor→1) frailty


## Energy metabolism (exertion-scaled) + thirst + ageing. Returns true if the creature died (starve/thirst/age).
static func tick(c, delta: float) -> bool:
	# LA_EVO_FAST compresses the WHOLE life — metabolism/eating AND life-events — by the SAME factor, so the
	# energy economy is scale-invariant: a creature burns energy `evo`× faster but (see CreatureDigestion) also
	# digests `evo`× faster and ages `evo`× faster, so it still banks breeding energy before it dies. Inert at 1.
	var evo: float = LAAblate.evo_fast()
	# Metabolism drains energy; exertion costs more, sleeping costs less; eating (elsewhere) refills.
	var exertion: float = 1.0
	if c.state == "flee" or c.state == "panic" or c.state == "chase":
		exertion = 1.6
	elif c.state == "sleep" or c.state == "rest" or c.state == "roost":
		exertion = 0.5                        # sleeping/resting conserves energy — why animals do it
	c.energy -= c.metabolism * exertion * delta * evo
	if c.energy <= 0.0:
		c.die("starvation")
		return true
	# Thirst drains steadily; dehydration kills like starvation. Drinking (elsewhere) refills it. Left UNSCALED by
	# evo on purpose: drinking cadence is brain-driven (not compressed), so compressing thirst too would cause a
	# dehydration die-off at high factors — thirst just becomes a lesser pressure over a compressed life.
	c.hydration -= c.thirst_rate * delta
	if c.hydration <= 0.0:
		c.die("thirst")
		return true
	# Old-age mortality, driven by the SENESCENCE CURVE (LACreatureSenescence) rather than a hard age cliff:
	# as the factor rises past prime, the body's reserve (max_energy) shrinks (see the senescence tick) and
	# frailty mounts, draining health so a worn-out animal dies of "old age" — earlier if it is also stressed
	# or hurt (its declining health has less margin). A hard backstop at factor 1.0 (age == the evo-compressed
	# max_age) guarantees death even for an unstressed elder, matching the old lifespan schedule. Lifespan still
	# compresses by the full LA_EVO_FAST factor (the factor() curve measures against max_age / evo).
	var sen: float = c.senescence.factor(c) if c.senescence != null else clampf(c.age / maxf(c.max_age / evo, 0.001), 0.0, 1.0)
	if sen >= 1.0:
		c.die("old age")
		return true
	if sen > FRAILTY_ONSET:
		c.health -= c.max_health * FRAILTY_HP_FRAC * (sen - FRAILTY_ONSET) * evo * delta
		if c.health <= 0.0:
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
const AEROBIC_SPEED: float = 1.0           # exertion up to cruise speed is aerobic (sustainable); above → anaerobic
const LACTATE_BUILD: float = 0.60          # /sec lactate produced per unit of over-aerobic exertion (anaerobic)
const LACTATE_CLEAR: float = 0.30          # /sec lactate cleared at rest (aerobic recovery)

## Short-term exertion CHEMISTRY: exertion past the aerobic threshold (a sprint/flee) is powered anaerobically and
## produces muscle LACTATE, which accumulates and — via the speed cap + conserve drive in Creature — forces rest;
## walking/resting clears it aerobically. This is why animals don't sprint everywhere: they conserve energy.
## Uses last frame's decided speed (carried in _eff_speed). (0.4 deepens this into full ATP/glycogen/O₂ chemistry.)
static func tick_exertion(c, delta: float) -> void:
	var exert: float = c._eff_speed / maxf(c.speed, 0.01)      # 0 still · 1 cruise · >1 sprint/flee
	if exert > AEROBIC_SPEED:
		c.lactate = minf(1.0, c.lactate + LACTATE_BUILD * (exert - AEROBIC_SPEED) * delta)
	else:
		c.lactate = maxf(0.0, c.lactate - LACTATE_CLEAR * (1.0 - exert * 0.6) * delta)


## Altitude falls out of the 3D read (a bird high above water reads air; a diver's head cell reads water) — no
## depth column, no can_fly. Returns true if the creature died. One rule = drowning + smoke + beached gills.
static func tick_breath(c, pos: Vector3, delta: float) -> bool:
	if c._material == null:
		return false
	# Head cell is RADIALLY "up" from the body on the spherical planet — world +Y is wrong away from the poles.
	var up: Vector3 = c.terrain.up_at(pos) if c.terrain != null and c.terrain.has_method("up_at") else Vector3.UP
	var head: Vector3 = pos + up * c.size
	var can_breathe: bool
	if c.breathes == "water":
		can_breathe = c._material.is_submerged_at(head.x, head.y, head.z)              # gills: must be in water
	else:
		can_breathe = c._material.breathable_o2_at(head.x, head.y, head.z) >= BREATHE_MIN_O2   # lungs: need air
	if can_breathe:
		c._breath = minf(c._breath + BREATH_REFILL * delta, c.breath_capacity)
		return false
	# Out of medium: hold breath from the reserve, then suffocate hard once it is spent.
	c._breath -= delta
	if c._breath <= 0.0:
		c.energy -= SUFFOCATE_DRAIN * delta
		if c.energy <= 0.0:
			var drowned: bool = c.breathes != "water" and c._material.is_submerged_at(head.x, head.y, head.z)
			c.die("drowned" if drowned else "suffocated")
			return true
	return false
