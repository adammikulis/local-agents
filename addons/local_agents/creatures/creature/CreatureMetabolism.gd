class_name LACreatureMetabolism
extends RefCounted


const COMBUST_TEMP: float = 200.0          # °C — organic tissue catches FIRE (in a wildfire/lava)

const EVAPORATIVE_OVER_TURNOVER: float = 0.15

const BREATHE_MIN_O2: float = 0.3          # O2 below this can't sustain a lung (water displaces it, or fire smoke)
const BREATH_REFILL: float = 25.0          # breath reserve refilled per sec while in the breathing medium
const FRAILTY_ONSET: float = 0.5           # senescence factor above which frailty begins draining health
const FRAILTY_HP_FRAC: float = 0.06        # fraction of max_health drained per second at full (factor→1) frailty


## Thirst + ageing. The ENERGY side of this tick is LACreatureRespiration.tick, which the caller runs first.
## Returns true if the creature died (thirst/age).
static func tick(c, delta: float) -> bool:
	# LA_EVO_FAST compresses the WHOLE life — metabolism/eating AND life-events — by the SAME factor, so the
	# energy economy is scale-invariant: a creature burns energy `evo`× faster but (see CreatureDigestion) also
	# digests `evo`× faster and ages `evo`× faster, so it still banks breeding energy before it dies. Inert at 1.
	var evo: float = LAAblate.evo_fast()
	var lost: float = c.thirst_rate * delta
	c.hydration -= lost
	transpire(c, c.global_position, lost)
	if c.hydration <= 0.0:
		c.die("thirst")
		return true
	LACreatureBodyMass.tick(c)                # a body is worth what it weighs; keep food_value in step
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


static func tick_environment(c, pos: Vector3, delta: float) -> bool:
	if c._material == null:
		return false
	if c._material.temp_at(pos) >= COMBUST_TEMP:
		c._combust()
		return true
	var over: float = float(c.body_temp) - LACreatureRespiration.band_optimum_c(c)
	if over > 0.0:
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


const AEROBIC_SPEED: float = 1.0           # exertion up to cruise speed is aerobic (sustainable); above → anaerobic
const LACTATE_BUILD: float = 0.60          # /sec lactate produced per unit of over-aerobic exertion (anaerobic)
const LACTATE_CLEAR: float = 0.30          # /sec lactate cleared at rest (aerobic recovery)

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
	c._breath = maxf(c._breath - delta, 0.0)
	return false
