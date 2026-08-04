class_name LACreatureMetabolism
extends RefCounted

## Per-frame survival for LocalAgentCreature, factored out of the hot _physics_process: energy metabolism, thirst,
## ageing, and environmental temperature/drowning read from the shared MaterialField. Static + dependency-free
## of the LocalAgentCreature type (dynamic access, like the other Creature* helpers). Each tick returns TRUE if the
## creature DIED this frame, and the caller must then stop processing it. (Explicit types only, no ':=' inferred typing.)
##
## THE BURN IS A REAL RESPIRATION NOW. Every joule an animal spent used to vanish: `c.energy -= …` and that was
## the end of it. Nothing consumed oxygen, nothing produced carbon dioxide, and no body heat ever reached the
## temperature field — while the substrate's own respiration record R20 does all three correctly for plant
## biomass. Animals were exempt from the chemistry the rest of the world obeys. The burn now goes through
## `LAMaterialFieldBiota3D.respire`, which debits O₂ and credits CO₂ one for one in the animal's head cell and
## warms it, so the carbon it spends comes off the body and lands in the air where it belongs.
##
## AND BREATHING TAKES OXYGEN. `tick_breath` used to be a READ-ONLY THRESHOLD TEST — `breathable_o2_at(...) >=
## BREATHE_MIN_O2` — which let an animal breathe air it never took. The threshold is still what decides whether
## it can breathe AT ALL (water and smoke displace O₂), but the oxygen it actually uses is drawn by the
## respiration above, in the cell its head is in.
##
## THE THERMAL COMFORT BAND IS GONE — see LACreatureThermal. Four module constants (`WARM_COMFORT 28`,
## `COOL_COMFORT 8`, `LETHAL_HEAT 50`, `LETHAL_COLD -18`) used to give a whale, a desert beetle and an arctic
## fox one identical thermal physiology, when two-thirds of the roster are ectotherms who do not have a comfort
## band at all. Endotherms now pay a Scholander heat-defence cost below their own thermoneutral zone and
## ectotherms follow a Q10 rate curve, both driven by species config.

const COMBUST_TEMP: float = 200.0          # °C — organic tissue catches FIRE (in a wildfire/lava). Kept as a
                                           # module constant because it is a property of TISSUE, not of thermal
                                           # strategy: a beetle and a whale burn at the same temperature.
# Breathing (one emergent rule, read in TRUE 3D at the creature's head cell — no 2.5D column, no can_fly):
# a creature breathes its MEDIUM. LUNGS need breathable air (water OR smoke displacing O2 → can't breathe);
# GILLS need to be submerged (a beached gill-breather suffocates in air). Out of medium it burns its per-animal
# breath reserve (Creature.breath_capacity), refilling at BREATH_REFILL/sec back in it; at zero, SUFFOCATE_DRAIN
# kills fast. Big lungs = long dives to hunt. One rule → drowning + smoke/CO2 suffocation + beached fish.
const BREATHE_MIN_O2: float = 0.3          # O2 below this can't sustain a lung (water displaces it, or fire smoke)
const BREATH_REFILL: float = 25.0          # breath reserve refilled per sec while in the breathing medium
## Energy per second burned once the breath reserve is spent, as a multiple of the animal's own basal rate.
## It was a flat 45.0/sec for every creature, which is more than a mouse's entire body and a rounding error to
## a whale — the same one-size-fits-all mistake as the comfort band. Anoxia kills fast in proportion to how
## fast the animal lives, so it is a multiple of basal, not a constant.
const SUFFOCATE_OVER_BASAL: float = 30.0
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
	# `c.metabolism` is this frame's true resting cost, set by LACreatureThermal from the animal's own thermal
	# strategy and the ambient temperature (an endotherm's rises in the cold, an ectotherm's falls). `exertion`
	# is the ACTIVE multiplier — the `active_metabolism` gene scales it, so a lineage can evolve toward a
	# thriftier or a more powerful working animal.
	var burned: float = c.metabolism * exertion * float(c.active_metabolism) * delta * evo
	# ORNAMENT UPKEEP: a displaying male pays extra energy every tick to hold his bright signal (0 for females /
	# undisplayed genomes). This is what makes the display HONEST — only a genuinely well-fed male can afford to
	# stay bright — so the sexual-selection loop (LAAppraisal / LACreatureReproduction) selects real fitness.
	burned += LAAppraisal.display_upkeep(c, delta) * evo
	c.energy -= burned
	# RESPIRE what was burned: the carbon leaves the body as CO₂ and the oxygen to oxidise it comes out of the
	# cell the animal is breathing. This is the leg that used to be missing entirely — the energy simply ceased
	# to exist. The head cell is radially outward from the body on a spherical planet (world +Y is wrong away
	# from the poles), the same read `tick_breath` uses.
	if burned > 0.0 and c._material != null and c._material.has_method("respire_at"):
		var up: Vector3 = c.terrain.up_at(c.global_position) if (c.terrain != null and c.terrain.has_method("up_at")) else Vector3.UP
		c._material.respire_at(c.global_position + up * c.size, burned)
	if c.energy <= 0.0:
		c.die("starvation")
		return true
	# Thirst drains steadily; dehydration kills like starvation. Drinking (elsewhere) refills it. Left UNSCALED by
	# evo on purpose: drinking cadence is brain-driven (not compressed), so compressing thirst too would cause a
	# dehydration die-off at high factors — thirst just becomes a lesser pressure over a compressed life.
	# WHERE THE WATER GOES: it leaves as vapour (breath, sweat) and as the water in urine, so it is handed to
	# the field's airborne moisture rather than deleted. Both legs of the animal's water budget are now real —
	# `LACreatureThirst.handle_thirst` empties a puddle to refill this.
	var lost: float = c.thirst_rate * delta
	c.hydration -= lost
	if lost > 0.0 and c._material != null and c._material.has_method("transpire_at"):
		c._material.transpire_at(c.global_position, lost)
	if c.hydration <= 0.0:
		c.die("thirst")
		return true
	LACreatureBodyMass.tick(c)                # a body is worth what it weighs; keep food_value in step
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


## Thermal physiology + combustion from the shared field at `pos`. Returns true if the creature died.
##
## The physiology itself lives in LACreatureThermal, which models an endotherm and an ectotherm as the
## different animals they are: an endotherm defends a core temperature and its burn RISES in the cold
## (Scholander), an ectotherm's body temperature is ambient and its burn FALLS with a Q10 curve while it slows
## down instead. What used to be here was one comfort band and two lethal thresholds shared by every species.
##
## This must run BEFORE the metabolism burn each frame, because it is what SETS `c.metabolism` for the frame.
## Drowning/suffocation is its own emergent rule — see tick_breath.
static func tick_environment(c, pos: Vector3, delta: float) -> bool:
	if c._material == null:
		return false
	var t: float = c._material.temp_at(pos)
	# Flesh doesn't glow like hot metal — it COMBUSTS. In fire/lava heat the creature bursts into flame and
	# dies burned (organic matter ignites; inorganic ground glows via the shader instead). A property of
	# TISSUE, so it is shared across every thermal strategy.
	if t >= COMBUST_TEMP:
		c._combust()
		return true
	var cause: String = LACreatureThermal.tick(c, t, delta)
	if cause != "":
		c.die(cause)
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
	# Out of medium: hold breath from the reserve, then suffocate hard once it is spent. The drain scales with
	# the animal's own basal rate — a flat 45/sec was more than a mouse's whole body and nothing to a whale.
	c._breath -= delta
	if c._breath <= 0.0:
		c.energy -= float(c.basal_metabolism) * SUFFOCATE_OVER_BASAL * delta
		if c.energy <= 0.0:
			var drowned: bool = c.breathes != "water" and c._material.is_submerged_at(head.x, head.y, head.z)
			c.die("drowned" if drowned else "suffocated")
			return true
	return false
