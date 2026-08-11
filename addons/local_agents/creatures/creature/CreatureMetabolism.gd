class_name LACreatureMetabolism
extends RefCounted

## Per-frame survival for LocalAgentCreature, factored out of the hot _physics_process: thirst, ageing,
## breathing and combustion. Static + dependency-free of the LocalAgentCreature type (dynamic access, like the
## other Creature* helpers). Each tick returns TRUE if the creature DIED this frame, and the caller must then
## stop processing it.
##
## METABOLISM DOES NOT LIVE HERE — see LACreatureRespiration. There is no comfort band and no per-species
## metabolism constant: "the temperature an animal is comfortable at" is not a measurable property of matter,
## whereas the freezing point of cell water and the denaturation temperature of protein are, and those are
## what bound the reaction (LAPhysical.WATER_FREEZE_C / PROTEIN_DENATURE_C, via
## LACreatureRespiration.temp_band).
##
## Heatstroke, freezing and starvation are ONE failure: the substrate's respiration reaction cannot meet the
## body's maintenance requirement, whether because the temperature band collapsed, the oxygen ran out, or the
## reserve is empty.
## (Explicit types only, no ':=' inferred typing.)

const COMBUST_TEMP: float = 200.0          # °C — organic tissue catches FIRE (in a wildfire/lava)

## Water lost per second per °C the BODY is above its own reaction optimum. Evaporative cooling is the only
## way an animal sheds heat once it is warmer than its surroundings, and it is paid for in water — which is
## why a hot animal seeks a drink and a dehydrated one overheats. Driven off BODY temperature against
## LACreatureRespiration's band optimum rather than off a comfort constant, so the temperature that makes an
## animal thirsty and the temperature that limits its chemistry are the same number and cannot drift apart.
const EVAPORATIVE_OVER_TURNOVER: float = 0.15

# Breathing (one emergent rule, read in TRUE 3D at the creature's head cell — no 2.5D column, no can_fly):
# a creature breathes its MEDIUM. LUNGS need breathable air (water OR smoke displacing O2 → can't breathe);
# GILLS need to be submerged (a beached gill-breather suffocates in air). Out of medium it burns its per-animal
# breath reserve (Creature.breath_capacity), refilling at BREATH_REFILL/sec back in it; at zero the
# respiration reaction's oxygen term is zero and the animal dies on the shared maintenance-failure path.
# Big lungs = long dives to hunt. One rule → drowning + smoke/CO2 suffocation + beached fish.
const BREATHE_MIN_O2: float = 0.3          # O2 below this can't sustain a lung (water displaces it, or fire smoke)
const BREATH_REFILL: float = 25.0          # breath reserve refilled per sec while in the breathing medium
# Old-age FRAILTY (senescence-driven mortality — see LACreatureSenescence). Past FRAILTY_ONSET on the 0..1
# senescence factor, failing resilience drains health at up to FRAILTY_HP_FRAC of max_health/sec (scaled by how
# far past onset), so an old, worn-out animal dies of "old age" — sooner if it is also stressed/hurt. A hard
# backstop at factor 1.0 (age == the effective max_age) guarantees death even for an unstressed elder.
const FRAILTY_ONSET: float = 0.5           # senescence factor above which frailty begins draining health
const FRAILTY_HP_FRAC: float = 0.06        # fraction of max_health drained per second at full (factor→1) frailty


## Thirst + ageing. The ENERGY side of this tick is LACreatureRespiration.tick, which the caller runs first.
## Returns true if the creature died (thirst/age).
static func tick(c, delta: float) -> bool:
	# LA_EVO_FAST compresses the WHOLE life — metabolism/eating AND life-events — by the SAME factor, so the
	# energy economy is scale-invariant: a creature burns energy `evo`× faster but (see CreatureDigestion) also
	# digests `evo`× faster and ages `evo`× faster, so it still banks breeding energy before it dies. Inert at 1.
	var evo: float = LAAblate.evo_fast()
	# Thirst drains steadily; dehydration kills like starvation. Drinking (elsewhere) refills it. Left UNSCALED by
	# evo on purpose: drinking cadence is brain-driven (not compressed), so compressing thirst too would cause a
	# dehydration die-off at high factors — thirst just becomes a lesser pressure over a compressed life.
	# WHERE THE WATER GOES: it leaves as vapour (breath, sweat) and as the water in urine, so it is handed to
	# the field's airborne moisture rather than deleted. `LACreatureThirst.drink` empties a puddle to refill
	# this, so both legs of the animal's water budget stay inside the H₂O ledger.
	var lost: float = c.thirst_rate * delta
	c.hydration -= lost
	transpire(c, c.global_position, lost)
	if c.hydration <= 0.0:
		c.die("thirst")
		return true
	LACreatureBodyMass.tick(c)                # a body is worth what it weighs; keep food_value in step
	# Old-age mortality, driven by the SENESCENCE CURVE (LACreatureSenescence) rather than a hard age cliff:
	# as the factor rises past prime, the body's reserve (max_energy) shrinks (see the senescence tick) and
	# frailty mounts, draining health so a worn-out animal dies of "old age" — earlier if it is also stressed
	# or hurt (its declining health has less margin). A hard backstop at factor 1.0 (age == the evo-compressed
	# max_age) guarantees death even for an unstressed elder. Lifespan compresses by the full LA_EVO_FAST
	# factor (the factor() curve measures against max_age / evo).
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


## COMBUSTION and evaporative water loss from the shared field at `pos`. Returns true if the creature died.
## Heat and cold do their damage through the respiration reaction's temperature band
## (LACreatureRespiration), not through a per-degree tax here. This owns the two things that are NOT
## metabolism:
##   * flesh does not glow like hot metal, it COMBUSTS — in fire or lava the animal bursts into flame;
##   * a body warmer than its own reaction optimum sheds heat by evaporating water, and pays in hydration.
static func tick_environment(c, pos: Vector3, delta: float) -> bool:
	if c._material == null:
		return false
	if c._material.temp_at(pos) >= COMBUST_TEMP:
		c._combust()
		return true
	var over: float = float(c.body_temp) - LACreatureRespiration.band_optimum_c()
	if over > 0.0:
		# EVAPORATIVE LOSS SCALES WITH THE ANIMAL, like every other rate on this body: it is a multiple of the
		# animal's own water turnover, so it is right at every body size. The water goes to the AIR — a panting
		# animal humidifies its own cell, which is what sweating physically does.
		var shed: float = over * EVAPORATIVE_OVER_TURNOVER * float(c.thirst_rate) * delta
		c.hydration -= shed
		transpire(c, pos, shed)
	return false


## Hand `mass` of body water to the field's airborne moisture at `pos`. One place, so no leg of the water
## budget can quietly forget to do it.
static func transpire(c, pos: Vector3, mass: float) -> void:
	if mass <= 0.0 or c._material == null or not c._material.has_method("transpire_at"):
		return
	c._material.transpire_at(pos, mass)


## Breathing (emergent, TRUE 3D): a creature breathes its medium at its actual head cell — a LUNG needs
## breathable air (water OR smoke displacing O2 → can't breathe), a GILL needs to be submerged. It burns a
## per-animal breath reserve out of medium and suffocates when it runs out; a big breath_capacity = long dives.
const AEROBIC_SPEED: float = 1.0           # exertion up to cruise speed is aerobic (sustainable); above → anaerobic
const LACTATE_BUILD: float = 0.60          # /sec lactate produced per unit of over-aerobic exertion (anaerobic)
const LACTATE_CLEAR: float = 0.30          # /sec lactate cleared at rest (aerobic recovery)

## Short-term exertion CHEMISTRY: exertion past the aerobic threshold (a sprint/flee) is powered anaerobically and
## produces muscle LACTATE, which accumulates and — via the speed cap + conserve drive in Creature — forces rest;
## walking/resting clears it aerobically. This is why animals don't sprint everywhere: they conserve energy.
## Uses last frame's decided speed (carried in _eff_speed).
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
	# Out of medium: draw down the held breath. NOTHING KILLS HERE. The store is a store of OXYGEN,
	# so LACreatureRespiration reads it as the reaction's oxygen source while it lasts, and once it is empty
	# that reaction's oxygen term is zero, production falls below maintenance, and the animal dies on the one
	# shared failure path (reported "drowned" or "suffocated").
	c._breath = maxf(c._breath - delta, 0.0)
	return false
