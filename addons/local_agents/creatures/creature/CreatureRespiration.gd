class_name LACreatureRespiration
extends RefCounted


const SPHERE_AREA_COEFF: float = 4.835976   # (36π)^(1/3): surface of a sphere per V^(2/3)

const RESP_K: float = 4.2558e-4           # extent/sec = RESP_K * exchange_area * o2 * band * exertion


const MAINTENANCE_K: float = 8.4211e-5    # required extent/sec = MAINTENANCE_K * live_mass (field mass units)
const DEFICIT_HP_FRAC: float = 1.0 / 30.0

const O2_UPTAKE_K: float = 1.0

const THERMAL_TAU_K: float = 5.1318       # tau (sec) = THERMAL_TAU_K * body_mass_kg / exchange_area
const MAX_THERMOGENESIS_GAIN: float = 12.0

const METABOLIC_HEAT_K: float = 1826.9    # °C of body warming per unit extent per kg of body mass

static func band_optimum_c() -> float:
	return (LAPhysical.WATER_FREEZE_C + LAPhysical.PROTEIN_DENATURE_C) * 0.5


static func band_width_c() -> float:
	return (LAPhysical.PROTEIN_DENATURE_C - LAPhysical.WATER_FREEZE_C) * 0.5


## The reaction-rate factor at body temperature `t` — 1.0 at the optimum, 0 at freezing and at denaturation.
static func temp_band(t: float) -> float:
	var w: float = band_width_c()
	if w <= 0.0:
		return 1.0
	var d: float = (t - band_optimum_c()) / w
	return maxf(0.0, 1.0 - d * d)


## Body mass in KILOGRAMS — the species' measured mass, carried on the creature as `mass_kg` by
## LACreatureBodyMass.apply. Not derived from `size`; see statement 1 in the header.
static func body_mass(c) -> float:
	return maxf(float(c.get("mass_kg")), 1.0e-7)


## The body's characteristic linear dimension, in metres: the cube root of the volume its measured mass
## occupies at tissue density. Volume → length is a definition, not an exponent anybody picked.
static func body_length(m_kg: float) -> float:
	return pow(maxf(m_kg, 1.0e-9) / LAPhysical.ANIMAL_TISSUE_DENSITY_KG_M3, 1.0 / 3.0)


static func exchange_area(c) -> float:
	var l: float = body_length(body_mass(c))
	return SPHERE_AREA_COEFF * l * l * maxf(float(c.get("respiratory_capacity")), 0.05)


static func capacity_rate(c) -> float:
	return RESP_K * exchange_area(c)


## The floor this body has to produce every second just to stay alive, in the field's mass units. Proportional
## to LIVING TISSUE, which is where LACreatureBodyMass's one kilogram→mass-unit conversion enters the rate law.
static func maintenance_rate(c) -> float:
	return MAINTENANCE_K * LACreatureBodyMass.TISSUE_PER_KG * body_mass(c)


## Advance body temperature, then run the oxidation. Returns true if the creature died.
## `pos` is the body position; `head` is where it breathes (the caller already computes it for tick_breath).
static func tick(c, pos: Vector3, delta: float) -> bool:
	if delta <= 0.0:
		return false
	var evo: float = LAAblate.evo_fast()
	var mass: float = body_mass(c)
	var area: float = exchange_area(c)
	if mass <= 0.0 or area <= 0.0:
		return false

	var ambient: float = float(c.body_temp)
	if c._material != null:
		ambient = c._material.temp_at(pos)
	var tau: float = maxf(THERMAL_TAU_K * mass / area, 0.001)
	var k: float = clampf(delta * evo / tau, 0.0, 1.0)     # clamped: a large step relaxes fully, never overshoots
	c.body_temp = float(c.body_temp) + (ambient - float(c.body_temp)) * k

	var band: float = temp_band(float(c.body_temp))
	var cold: float = clampf((band_optimum_c() - float(c.body_temp)) / maxf(band_width_c(), 0.001), 0.0, 1.0)
	var gain: float = 1.0 + MAX_THERMOGENESIS_GAIN * clampf(float(c.get("thermogenesis")), 0.0, 1.0) * cold
	var exertion: float = 1.0
	if c.state == "flee" or c.state == "panic" or c.state == "chase":
		exertion = 1.6
	elif c.state == "sleep" or c.state == "rest" or c.state == "roost":
		exertion = 0.5                        # resting lowers demand — why animals do it
	var o2: float = 1.0
	if c._material != null:
		o2 = maxf(breathable_at(c, pos), 0.0)
		if o2 < LACreatureMetabolism.BREATHE_MIN_O2 and float(c._breath) > 0.0:
			o2 = LAMaterialField3D.O2_AMBIENT   # drawing on the held breath
	var capacity: float = RESP_K * area * gain * O2_UPTAKE_K * o2 * band * delta * evo
	# What it actually burns. Exertion above 1 is a sprint, and exceeding the aerobic capacity is correct there
	# — that excess is anaerobic, which is exactly what the muscle-lactate rule in LACreatureMetabolism models.
	var want: float = capacity * exertion
	want = minf(want, maxf(float(c.energy), 0.0))          # cannot oxidise fuel that is not there
	# Hand the transaction to the substrate: it applies the same aerobic Liebig cap the kernel applies and
	# books O₂ → CO₂ + detritus into this cell. What comes back is what the local air could support.
	var extent: float = want
	if c._material != null and c._material.has_method("respire_at"):
		extent = c._material.respire_at(pos, want)
	c.energy -= extent
	c._resp_rate = extent / maxf(delta * evo, 1e-6)
	c._resp_capacity = capacity / maxf(delta * evo, 1e-6)
	c.energy -= LAAppraisal.display_upkeep(c, delta) * evo

	c.body_temp = float(c.body_temp) + extent * METABOLIC_HEAT_K / mass

	var need: float = maintenance_rate(c) * delta * evo
	if capacity < need and need > 0.0:
		# The shortfall as a FRACTION of the requirement (0 = met, 1 = producing nothing at all), so the damage
		# is on the animal's own scale at every body mass — see DEFICIT_HP_FRAC.
		var shortfall: float = clampf((need - capacity) / need, 0.0, 1.0)
		c.health -= shortfall * DEFICIT_HP_FRAC * float(c.max_health) * delta * evo
		if c.health <= 0.0:
			c.die(deficit_cause(c, o2))
			return true
	if c.energy <= 0.0:
		c.die("starvation")
		return true
	return false


static func breathable_at(c, pos: Vector3) -> float:
	var up: Vector3 = c.terrain.up_at(pos) if c.terrain != null and c.terrain.has_method("up_at") else Vector3.UP
	var head: Vector3 = pos + up * c.size
	if c.breathes == "water":
		return LAMaterialField3D.O2_AMBIENT if c._material.is_submerged_at(head.x, head.y, head.z) else 0.0
	return c._material.breathable_o2_at(head.x, head.y, head.z)


static func deficit_cause(c, o2: float) -> String:
	if float(c.body_temp) >= LAPhysical.PROTEIN_DENATURE_C:
		return "hyperthermia"
	if float(c.body_temp) <= LAPhysical.WATER_FREEZE_C:
		return "hypothermia"
	if o2 <= 0.01:
		# Same distinction the old suffocation rule drew, on the same test: a lung-breather that has run out of
		# oxygen while submerged drowned; anything else (a gill in air, a body in smoke or foul air) suffocated.
		if c._material != null and c.breathes != "water":
			var up: Vector3 = c.terrain.up_at(c.global_position) if c.terrain != null and c.terrain.has_method("up_at") else Vector3.UP
			if c._material.is_submerged_at(c.global_position.x + up.x * c.size,
					c.global_position.y + up.y * c.size, c.global_position.z + up.z * c.size):
				return "drowned"
		return "suffocated"
	return "starvation"
