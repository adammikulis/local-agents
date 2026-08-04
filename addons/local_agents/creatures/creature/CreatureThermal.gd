class_name LACreatureThermal
extends RefCounted

## LACreatureThermal — AN ENDOTHERM AND AN ECTOTHERM ARE NOT THE SAME ANIMAL, AND NEITHER OF THEM HAS A
## "COMFORT BAND".
##
## What this replaces. `LACreatureMetabolism` carried four module constants — `WARM_COMFORT 28`,
## `COOL_COMFORT 8`, `LETHAL_HEAT 50`, `LETHAL_COLD -18` — and applied them to every creature in the game. A
## whale, a desert beetle and an arctic fox shared one thermal physiology, with no species configuration and no
## heritable gene. Worse than the missing per-species values: roughly sixteen of the twenty-three animals in
## the roster are ECTOTHERMS, whose thermal biology is not a comfort band at all. Modelling a beetle with a
## mammal's thermoneutral zone is not a simplification, it is the wrong physics.
##
## THE TWO REAL MODELS.
##
## **Endotherm** (mammal, bird). It holds a body temperature — 37 °C in a placental mammal, ~41 °C in a
## passerine — and pays for it. Between the lower and upper critical temperatures (the THERMONEUTRAL ZONE) that
## costs nothing beyond basal. Below the lower critical temperature the animal must replace heat as fast as it
## loses it, and metabolic rate rises LINEARLY with the gradient: this is the Scholander model, and the slope
## is the body's thermal conductance. Conductance per unit mass is far higher in a small animal (surface area
## scales as M^0.67 while mass scales as M^1.0), which is exactly why a shrew must eat constantly in the cold
## and a bear can sleep through it — and here it falls out of one exponent rather than a per-species number.
##   Death is not a magic number either. An animal dies of hypothermia when the metabolic rate needed to hold
##   its body temperature exceeds its SUMMIT METABOLISM — the maximum sustained heat production, roughly five
##   times basal in a cold-adapted mammal. Above the upper critical temperature it dumps heat evaporatively,
##   which costs WATER rather than energy, and it dies of hyperthermia once ambient reaches body temperature
##   plus its evaporative margin, because at that point there is no gradient left to shed heat down.
##
## **Ectotherm** (insect, fish, crustacean, mollusc, reptile). Its body temperature IS the ambient temperature,
## so it has no defence cost and no comfort band. What it has is a rate that tracks temperature: metabolic rate
## multiplies by Q10 for every 10 °C, with Q10 ≈ 2.3 across most ectotherms. Cold does not cost it energy — it
## SLOWS it down, which is why insects are sluggish at dawn, and that emerges here as a speed multiplier off
## the same curve. Its limits are the CRITICAL THERMAL MINIMUM (chill coma, then death) and the CRITICAL
## THERMAL MAXIMUM (heat death), both real measured per-species values.
##
## So an endotherm burns MORE in the cold and an ectotherm burns LESS, which is the single most important
## qualitative difference between the two strategies, and the old shared constant had it backwards for
## two-thirds of the roster.
##
## COMBUSTION IS SHARED, because it is a property of tissue rather than of physiology: organic matter ignites
## near 200 °C whatever animal it belongs to. That one stays in LACreatureMetabolism.
##
## Every value below is a per-species CONFIG default by thermal strategy, overridable in the species JSON —
## config over `if species == X`. Static + dynamic field access, like the other Creature* helpers.
## (Explicit types only, no ':=' inferred typing.)

# --- MEASURED PROPERTIES (facts; not tuning knobs) --------------------------------------------------------
const Q10: float = 2.3                     # ectotherm rate multiplier per 10 °C (typical across taxa)
const Q10_REFERENCE_C: float = 20.0        # temperature the ectotherm's basal rate is quoted AT
const SUMMIT_OVER_BASAL: float = 5.0       # maximum sustained heat production / basal, cold-adapted mammal
## Thermal conductance per °C of gradient, as a fraction of basal rate, for a 1 kg endotherm. Scales as
## M^-0.25 per unit of basal rate (surface/volume), so a small body loses heat far faster than a large one.
const CONDUCTANCE_COEFF: float = 0.055
const CONDUCTANCE_EXPONENT: float = -0.25
## Evaporative cooling: body water spent per °C of overheat per second, as a fraction of body water. An animal
## above its upper critical temperature sweats/pants; it costs water, not fuel.
const EVAP_WATER_FRAC: float = 0.0016
## How far above body temperature ambient may go before evaporation cannot keep up. Real animals hold a few
## degrees of margin on humid days and far more on dry ones; this is the dry-air figure.
const EVAP_MARGIN_C: float = 8.0

## Per-strategy thermal defaults. A species JSON overrides any of these by name.
##   endotherm/endotherm_avian: body temperature and the thermoneutral zone (lower/upper critical temperature).
##   ectotherm: the critical thermal minimum and maximum, and the temperature below which it is in chill coma.
const DEFAULTS: Dictionary = {
	"endotherm": {
		"body_temp_c": 37.0,             # placental mammal core temperature
		"lower_critical_c": 20.0,        # below this, heat production must rise to hold core temperature
		"upper_critical_c": 30.0,        # above this, evaporative cooling starts
	},
	"endotherm_avian": {
		"body_temp_c": 41.0,             # passerine core temperature
		"lower_critical_c": 25.0,
		"upper_critical_c": 35.0,
	},
	"ectotherm": {
		"ct_min_c": 0.0,                 # critical thermal minimum: below it the animal dies of cold
		"ct_max_c": 45.0,                # critical thermal maximum: above it, heat death
		"chill_coma_c": 8.0,             # below this it can barely move (no death, just torpor)
	},
}


static func _param(c, key: String, strategy: String) -> float:
	if c.config.has(key):
		return float(c.config[key])
	var d: Dictionary = DEFAULTS.get(strategy, DEFAULTS["endotherm"])
	return float(d.get(key, 0.0))


## Thermal conductance in mass units per second per °C of gradient. Derived from the animal's own basal rate
## and its mass, so the small-body penalty is structural rather than tuned.
static func conductance(c) -> float:
	return float(c.basal_metabolism) * CONDUCTANCE_COEFF * pow(maxf(float(c.mass_kg), 1.0e-7), CONDUCTANCE_EXPONENT)


## THE ONE PER-FRAME THERMAL TICK. Sets `c.metabolism` (this frame's true resting cost, which the exertion
## multiplier in LACreatureMetabolism then scales) and `c.thermal_speed_mult` (an ectotherm slows in the cold),
## charges evaporative water loss, and returns a non-empty cause string if the temperature killed the animal.
## `ambient` is the field temperature at the body, read once by the caller.
static func tick(c, ambient: float, delta: float) -> String:
	var strategy: String = String(c.thermal_strategy)
	if strategy == "ectotherm":
		return _tick_ectotherm(c, ambient, delta)
	return _tick_endotherm(c, ambient, strategy, delta)


## ENDOTHERM: hold the core temperature and pay for it (Scholander). Cold RAISES the burn; heat costs water.
static func _tick_endotherm(c, ambient: float, strategy: String, delta: float) -> String:
	var basal: float = float(c.basal_metabolism)
	var lct: float = _param(c, "lower_critical_c", strategy)
	var uct: float = _param(c, "upper_critical_c", strategy)
	var body_t: float = _param(c, "body_temp_c", strategy)
	c.thermal_speed_mult = 1.0
	if ambient < lct:
		# Below thermoneutral: replace heat as fast as it is lost. Linear in the gradient — the Scholander line.
		var extra: float = conductance(c) * (lct - ambient)
		var ceiling: float = basal * SUMMIT_OVER_BASAL
		c.metabolism = minf(basal + extra, ceiling)
		# HYPOTHERMIA is a failure to keep up, not a threshold on the thermometer. Once the required production
		# exceeds summit metabolism the core temperature falls whatever the animal does. An arctic species
		# survives -40 °C because its lower critical temperature is low; a tropical one does not, and neither
		# of them needs a `LETHAL_COLD` constant.
		if basal + extra > ceiling:
			return "hypothermia"
		return ""
	if ambient > uct:
		# Above thermoneutral: dump heat by evaporation. This costs BODY WATER, which is why a hot animal seeks
		# a drink — the existing thirst drive then does the rest with no new behaviour code.
		var over: float = ambient - uct
		c.metabolism = basal
		c.hydration -= float(c.max_hydration) * EVAP_WATER_FRAC * over * delta
		# HYPERTHERMIA: once ambient reaches core temperature plus the evaporative margin there is no gradient
		# left to shed heat down, and no amount of panting helps.
		if ambient >= body_t + EVAP_MARGIN_C:
			return "hyperthermia"
		return ""
	c.metabolism = basal
	return ""


## How far `t` lies outside THIS animal's own tolerated range, in °C; 0 inside it. What the mind learns to
## avoid and what the body actually suffers are the same threshold, which is the point — but the threshold is
## now the species' own, so an arctic fox and a reef fish do not learn to dread the same temperature. (The
## caller, LACognition, used to read `LACreatureMetabolism.WARM_COMFORT` / `COOL_COMFORT` — the shared module
## constants that gave every creature in the game one thermal physiology.)
static func discomfort(c, t: float) -> float:
	var strategy: String = String(c.thermal_strategy)
	if strategy == "ectotherm":
		var coma: float = _param(c, "chill_coma_c", "ectotherm")
		var hot: float = _param(c, "ct_max_c", "ectotherm")
		if t < coma:
			return coma - t
		return maxf(0.0, t - hot)
	var lct: float = _param(c, "lower_critical_c", strategy)
	var uct: float = _param(c, "upper_critical_c", strategy)
	if t < lct:
		return lct - t
	return maxf(0.0, t - uct)


## ECTOTHERM: body temperature IS ambient, so there is nothing to defend. The rate follows Q10 and the animal
## slows down in the cold rather than burning more.
static func _tick_ectotherm(c, ambient: float, _delta: float) -> String:
	var basal: float = float(c.basal_metabolism)
	var ct_min: float = _param(c, "ct_min_c", "ectotherm")
	var ct_max: float = _param(c, "ct_max_c", "ectotherm")
	var coma: float = _param(c, "chill_coma_c", "ectotherm")
	# Q10: the rate multiplies by Q10 for every 10 °C. Cold ectotherms burn LESS, which is the opposite of what
	# the shared comfort band did to them.
	var q: float = pow(Q10, (ambient - Q10_REFERENCE_C) * 0.1)
	c.metabolism = basal * clampf(q, 0.02, 20.0)
	# CHILL COMA: the same curve, expressed as movement. A cold insect is sluggish, not starving.
	c.thermal_speed_mult = clampf((ambient - ct_min) / maxf(coma - ct_min, 0.001), 0.05, 1.0) if ambient < coma else 1.0
	if ambient <= ct_min:
		return "chilled"
	if ambient >= ct_max:
		return "overheated"
	return ""
