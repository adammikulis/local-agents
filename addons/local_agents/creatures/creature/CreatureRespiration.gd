class_name LACreatureRespiration
extends RefCounted

## A BODY IS A PLACE WHERE THE SUBSTRATE'S RESPIRATION REACTION RUNS. Nothing here is a metabolism system.
##
## R20 in LABioRecords is `biomass + O₂ → CO₂ + detritus` — aerobic oxidation of organic carbon — and it
## already runs on every cell of this planet, on the GPU, conserving. A living animal burning energy IS THAT
## REACTION. It is not an analogy or a parallel model: decomposition in the soil and metabolism in a fox are
## the same chemistry, differing only in where the carbon happens to be sitting. So this module owns no
## chemistry of its own. It reads the stoichiometry off LABioRecords and hands the transaction to
## LAMaterialField3D.respire_at, which applies the identical oxygen Liebig cap the kernel applies.
##
## WHAT THIS REPLACED, AND WHY THAT WAS WRONG. LACreatureMetabolism used to carry a hand-rolled burn
## (`energy -= metabolism * exertion * delta`) against a per-species `metabolism` constant in the JSON, plus a
## bespoke comfort band (WARM_COMFORT 28 / COOL_COMFORT 8 / LETHAL_HEAT 50 / LETHAL_COLD -18) applied as MODULE
## CONSTANTS to all 23 animal species. A whale, a desert beetle and an arctic fox shared one thermal
## physiology, and a fox and a mouse burned identical energy despite a 19x difference in body mass. Every one
## of those numbers is now gone: none of them was a fact about anything.
##
## THE THREE PHYSICAL STATEMENTS THIS MODULE MAKES, and they are the whole model:
##
## 1. MASS AND SURFACE COME FROM ONE LINEAR DIMENSION. A body of linear size `s` has volume ∝ s³ and surface
##    ∝ s². That is not an allometric exponent anybody chose; it is what volume and area ARE. Mass follows
##    from volume by LAPhysical.ANIMAL_TISSUE_DENSITY_KG_M3. So the roster's existing, already-heritable
##    `size` gene sets a creature's mass, its oxygen uptake and its thermal inertia, and no per-species mass
##    table is needed.
##
## 2. THE RATE IS SET BY OXYGEN CROSSING A SURFACE (Fick's law), NOT BY HOW MUCH FUEL IS PRESENT. This is the
##    one real difference between respiration in a soil cell and respiration in a body. In soil the oxygen is
##    already mixed through the substrate, so R20 drives on the bulk biomass. In a body the fuel is interior
##    and the oxygen has to diffuse in across a gas-exchange surface, so the exchange AREA is what limits the
##    reaction — which is why an animal starves in weeks but suffocates in minutes. Metabolic rate therefore
##    scales as s², i.e. as M^(2/3).
##
##    THAT IS RUBNER'S SURFACE LAW, AND IT IS NOT KLEIBER'S M^0.75. Read the measured exponent in SIM_REPORT
##    (`metab_exponent`) before quoting a number. 2/3 is what falls out of a body whose exchange surface is a
##    simple geometric surface, and it is a real law with real empirical support (Rubner 1883; and Dodds,
##    Rothman & Weitz 2001 argue the mammalian data below ~10 kg fit 2/3 better than 3/4). Kleiber's 3/4
##    (Kleiber 1932) is explained by West, Brown & Enquist (1997) as a consequence of the RESOURCE-DISTRIBUTION
##    NETWORK: a space-filling fractal branching vasculature with size-invariant terminal units (capillaries,
##    alveoli) delivers as M^(3/4) rather than M^(2/3). THE SUBSTRATE CANNOT EXPRESS THAT TODAY — a body here
##    is one point with one exchange surface; there is no internal transport network, no branching generation
##    count, no terminal unit. Adding 0.75 as a literal exponent would encode the CONCLUSION of a theory whose
##    MECHANISM is absent, which is the thing this repo's rules forbid. So the honest exponent is the
##    geometric one, and what the substrate is missing is named here rather than papered over.
##
## 3. TEMPERATURE ACTS ON THE REACTION, NOT ON THE ANIMAL. Every reaction in this substrate that has an
##    optimum uses OPTIMUM_BAND (LAReactionDefs), and photosynthesis already does: R19 peaks at 24 °C and
##    reaches zero at 0 °C and 48 °C. Animal biochemistry gets the same treatment and its band edges are
##    physical facts, not a fitted comfort range: it is zero at LAPhysical.WATER_FREEZE_C (0 °C — cell water
##    crystallises, chemistry stops) and zero at LAPhysical.PROTEIN_DENATURE_C (45 °C — animal proteins
##    unfold). One band, derived from two measured properties of matter, for every species.
##
## ENDOTHERM AND ECTOTHERM ARE NOT TWO MODELS. There is no thermoregulation flag and no `if ectotherm`
## anywhere in this file. A body has a temperature that exchanges heat with its surroundings by Newton's law
## of cooling, with a time constant ∝ mass/area ∝ s — so a beetle tracks the air within moments and a whale
## barely moves. Oxidation releases heat (LAPhysical.BIOMASS_HEAT_OF_COMBUSTION_J_PER_KG — metabolic warmth is
## not a bolted-on mechanism, it is the same reaction's enthalpy), and the heritable `thermogenesis` gene is
## simply how much a body raises its oxygen throughput when it is below the band optimum, exactly as
## shivering and brown fat raise ventilation and perfusion in a real animal. thermogenesis == 0 IS an
## ectotherm, with no branch taken and no separate code path: its body temperature is ambient, its metabolic
## rate rides the band up and down with the weather, and it goes torpid in the cold because the reaction does.
## A high value is an endotherm, which pays for its stable body temperature in oxygen and fuel. The gene is
## under ordinary selection, so which strategy wins is the planet's answer and not a species table's.
##
## STARVATION, HYPOTHERMIA, HYPERTHERMIA AND ANOXIA ARE ONE FAILURE. There are no longer four rules with four
## thresholds. There is a maintenance requirement proportional to living mass, and a production rate limited
## by oxygen and temperature; when production falls short of maintenance the deficit damages the body. Cold
## kills by collapsing the band, heat kills by denaturing past it, foul air kills by starving the Liebig cap,
## and an empty reserve kills because there is nothing left to oxidise. The reported cause names WHICH term
## was binding — it is a label on one mechanism, not four mechanisms.
##
## (Explicit types only, no ':=' inferred typing.)

# --- BODY GEOMETRY -----------------------------------------------------------------------------------------
# A creature's `size` is its characteristic linear body dimension (LACreatureBody builds its capsule from it).
# These two turn that one length into a volume and a gas-exchange area. They are SHAPE factors — the
# dimensionless "how boxy is this animal" — and they cancel out of every ratio the allometry produces, so
# they set units and nothing else. VOLUME_SHAPE is deliberately far below the collision capsule's volume:
# the capsule is a movement proxy sized for the physics query, not a body (it would make a villager 1800 kg).
const VOLUME_SHAPE: float = 0.07          # body volume = VOLUME_SHAPE * size³ (a human at size 1.0 → ~70 kg)
const AREA_SHAPE: float = 1.0             # gas-exchange area ∝ AREA_SHAPE * size²

# --- REACTION RATE -----------------------------------------------------------------------------------------
# The per-second k on the body's oxidation, the animal-body counterpart of LABioRecords.RESP_RATE (which is
# the per-STEP k on the same reaction in soil). ONE constant for the whole roster, replacing the thirteen
# per-species `metabolism` numbers the species JSONs used to carry.
#
# ITS VALUE IS A UNIT CHOICE, NOT A FIT, AND THE DISTINCTION MATTERS. The SCALING is physics: rate ∝ s². What
# this constant fixes is where the roster sits on the world's compressed clock — a fox does not really starve
# in ninety seconds, and this simulation's creatures live for a few hundred. It is set so a mid-sized animal
# burns at the same absolute rate it did before this change, which preserves the existing calibration of the
# food economy and leaves the mass-scaling as the only behavioural difference to measure. Changing it moves
# every species together and changes no ratio.
const RESP_K: float = 2.66                # extent/sec = RESP_K * exchange_area * o2 * band * exertion

# Oxidisable reserve a body of this mass can hold — fat and glycogen are a MASS of tissue, so the store
# scales with body mass exactly as the burn scales with surface. That pairing is the whole reason fasting
# endurance rises with body size: reserve ∝ s³ over burn ∝ s² leaves endurance ∝ s. (Real endurance goes as
# M^0.25 ≡ s^0.75, so this is slightly generous to large animals and in the right direction. The alternative
# — the old flat per-species tank — had an ant carrying 21% of a villager's reserve on 0.05% of its mass.)
#
# WHAT THIS CONSTANT IS ANCHORED TO, MEASURED. Reserve/burn gives fasting endurance = 26.3 * ENERGY_PER_MASS *
# size seconds. The physiological ratios are fixed by the two exponents above and do not move with it; what it
# sets is where the whole roster sits against the BEHAVIOURAL clock, and that turned out to be the binding
# constraint rather than anything metabolic. At the first value tried (3.61, which reproduced the fox's old
# absolute reserve) the smallest animals had 7.6 s of endurance and the run went: ants, bees, beetles, flies
# and mice extinct, foxes/villagers/vultures/swallows extinct, population 51/52/56 against a baseline of
# 148/120/112, with starvation deaths 53-73 against 14-24. The scaling was not the problem — an ant really
# does have far less fasting endurance than a fox, and 7.6 s against an 80 s lifespan is if anything generous
# next to a real ant's ~3 days against a year. The problem is that a creature's FORAGING cadence in this
# simulation does not scale down with its body: movement speed, cognition tick and food spacing are the same
# for an ant as for a villager, so a small animal cannot physically find a meal inside a correctly-short
# endurance. Until foraging cadence scales with body size, the anchor has to clear the behavioural clock, and
# 19.0 gives the smallest animal ~40 s to find food. Every RATIO in the roster is untouched by this.
const ENERGY_PER_MASS: float = 19.0       # max_energy = ENERGY_PER_MASS * body_mass  (≡ 1330 * size³)

# MAINTENANCE: the floor every gram of living tissue needs just to hold its ion gradients and turn over its
# proteins, whether or not the animal is doing anything. Proportional to MASS, while production is limited by
# SURFACE — which is what makes the failure modes above real rather than decorative, and what puts an upper
# bound on how big a body this substrate can keep alive. Held well below the routine rate so a healthy animal
# in ordinary air at an ordinary temperature is never in deficit; it bites only when the band collapses, the
# oxygen runs out, or the body outgrows its own surface.
## THE UPPER SIZE LIMIT IS EMERGENT, AND IT IS THE 2/3 EXPONENT'S MOST VISIBLE CONSEQUENCE. Because
## production goes as surface (s²) and this requirement goes as mass (s³), the ratio production/requirement
## falls as 1/s: every body has a size past which its surface cannot feed its volume. That is Rubner's
## argument stated as a survival condition rather than as a rate law, and it is why this constant is set
## against the LARGEST animal on the roster (the whale, size 3.0) rather than a typical one — at a value the
## whale survives, a fox has ~5x margin and a beetle ~30x. A real whale exists because its delivery network
## scales as M^3/4 and not as its skin; see the note at the top of this file about what the substrate lacks.
const MAINTENANCE_K: float = 0.008        # required extent/sec = MAINTENANCE_K * body_mass
## Health lost per second per unit of unmet maintenance. Sized so a TOTAL production failure — a drowning
## animal whose breath store has run out, a body past protein denaturation, one frozen solid — kills in
## roughly half a minute rather than instantly, which is the honest timescale for all three. It is never
## reached by a mild deficit: a healthy animal in ordinary air runs 5-30x above its maintenance requirement,
## so this only engages when the reaction has actually collapsed.
const DEFICIT_DAMAGE: float = 40.0

# --- OXYGEN UPTAKE (Fick) ----------------------------------------------------------------------------------
# Diffusive flux across the exchange surface is proportional to area × the concentration difference. The
# field's O₂ channel is a normalised concentration (~1.0 in open air), so this folds the membrane's
# permeability and thickness into one coefficient. It is what makes a fouled or thin atmosphere throttle
# every animal in it without any "is the air bad" test.
const O2_UPTAKE_K: float = 1.0

# --- THERMAL ----------------------------------------------------------------------------------------------
# Newton's law of cooling: dT/dt = (T_ambient - T_body) / tau. The time constant is the body's heat capacity
# over its conductance to the outside, so tau ∝ mass/area ∝ size — pure geometry again, and the reason a
# beetle equilibrates in moments while a whale holds its temperature for hours. THERMAL_TAU_K carries the
# units (seconds per unit size on this world's clock).
const THERMAL_TAU_K: float = 6.0          # tau (sec) = THERMAL_TAU_K * body_mass / exchange_area
# Ceiling on the cold-driven uptake boost, reached at thermogenesis = 1. A shivering mammal runs at roughly
# 5-10x its basal rate, and a bumblebee warming its flight muscles before take-off is in the same range, so an
# order-of-magnitude ceiling is the measured one. The boost is not a switch: it is multiplied by how far below
# the band optimum the body has fallen, so it fades to nothing as the body warms — a negative feedback that
# PARKS an endotherm near its own enzyme optimum without any setpoint being written down anywhere.
const MAX_THERMOGENESIS_GAIN: float = 12.0

# Metabolic heat: enthalpy released per unit extent, over the body's heat capacity — the ratio
# LAPhysical.BIOMASS_HEAT_OF_COMBUSTION_J_PER_KG / LAPhysical.ANIMAL_SPECIFIC_HEAT_J_KGK expressed in the
# model's extent units. A body that burns harder runs hotter, and that feeds straight back into the band.
#
# NOTE WHAT CANCELS, because it is a real prediction of this model and not a bug: the steady-state elevation
# of body temperature above ambient works out to RESP_K * METABOLIC_HEAT_K * THERMAL_TAU_K * band * gain, with
# MASS CANCELLING OUT — production and conductive loss both scale with surface here, so they cancel exactly.
# Real endotherms hold a slightly larger elevation as they get bigger (production M^3/4 against loss M^2/3),
# and this substrate cannot reproduce that for the same missing-network reason recorded at the top of the file.
const METABOLIC_HEAT_K: float = 0.25      # °C of body warming per unit extent per unit body mass

# --- TEMPERATURE BAND (derived from LAPhysical — nothing here is fitted) ----------------------------------
# Zero at the freezing point of cell water and zero at the protein denaturation onset; peak at the midpoint.
# Same OPTIMUM_BAND shape LAReactionDefs defines and R19 photosynthesis already uses.
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


# --- BODY QUANTITIES ---------------------------------------------------------------------------------------

## Body mass from the creature's one linear dimension: density × volume. The `size` gene is already heritable,
## so mass is heritable and evolvable with no new locus.
static func body_mass(c) -> float:
	var s: float = maxf(float(c.size), 0.02)
	return LAPhysical.ANIMAL_TISSUE_DENSITY_KG_M3 * VOLUME_SHAPE * s * s * s


## Gas-exchange surface — geometric area times the heritable `respiratory_capacity` gene, which is how much
## exchange surface this lineage packs into that area (a bird's air sacs against a reptile's simple lung).
static func exchange_area(c) -> float:
	var s: float = maxf(float(c.size), 0.02)
	return AREA_SHAPE * s * s * maxf(float(c.get("respiratory_capacity")), 0.05)


## The oxidisable reserve a body of this mass can hold.
static func reserve_capacity(c) -> float:
	return ENERGY_PER_MASS * body_mass(c)


# --- THE TICK ----------------------------------------------------------------------------------------------

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

	# --- 1. BODY TEMPERATURE: Newton cooling toward ambient, plus the previous tick's metabolic heat. ------
	var ambient: float = float(c.body_temp)
	if c._material != null:
		ambient = c._material.temp_at(pos)
	var tau: float = maxf(THERMAL_TAU_K * mass / area, 0.001)
	var k: float = clampf(delta * evo / tau, 0.0, 1.0)     # clamped: a large step relaxes fully, never overshoots
	c.body_temp = float(c.body_temp) + (ambient - float(c.body_temp)) * k

	# --- 2. OXIDATION: Fick-limited uptake × the temperature band × what the animal is doing. -------------
	var band: float = temp_band(float(c.body_temp))
	# Cold drive: how far below the band optimum the body has fallen, 0..1. An animal with thermogenesis
	# raises its oxygen throughput to meet it (shivering, brown fat, higher perfusion). At thermogenesis 0
	# this term vanishes identically and the body is an ectotherm — no branch, no flag.
	var cold: float = clampf((band_optimum_c() - float(c.body_temp)) / maxf(band_width_c(), 0.001), 0.0, 1.0)
	var gain: float = 1.0 + MAX_THERMOGENESIS_GAIN * clampf(float(c.get("thermogenesis")), 0.0, 1.0) * cold
	var exertion: float = 1.0
	if c.state == "flee" or c.state == "panic" or c.state == "chase":
		exertion = 1.6
	elif c.state == "sleep" or c.state == "rest" or c.state == "roost":
		exertion = 0.5                        # resting lowers demand — why animals do it
	# OXYGEN, from the medium if the animal can breathe it, otherwise from what it is carrying. A held breath
	# is a STORE of the same reactant, which is why this needs no separate suffocation rule: while the store
	# lasts the reaction runs normally, and when it empties the oxygen term goes to zero, production collapses
	# below maintenance, and the animal dies on the same path as one that is frozen or cooked. (This replaced
	# LACreatureMetabolism.SUFFOCATE_DRAIN, a flat 45 energy/sec that was calibrated against the old per-species
	# energy tanks; once reserves became proportional to body mass it emptied a small animal in a single tick
	# and killed 69-80 creatures a run.)
	var o2: float = 1.0
	if c._material != null:
		o2 = maxf(breathable_at(c, pos), 0.0)
		if o2 < LACreatureMetabolism.BREATHE_MIN_O2 and float(c._breath) > 0.0:
			o2 = LAMaterialField3D.O2_AMBIENT   # drawing on the held breath
	# CAPACITY is what this body COULD oxidise here — R20's own rate law with the gas-exchange surface in place
	# of bulk biomass. Note that exertion is deliberately NOT in it: resting lowers what an animal SPENDS, not
	# what its lungs and its air could supply, and conflating the two was a real bug. It put every large animal
	# into a false metabolic deficit whenever it slept (production was multiplied by 0.5 while the maintenance
	# requirement stayed put, so the margin at size 1.0 fell from 4.75x to 2.4x and at the whale's size 3.0 went
	# below 1.0 outright), and it killed the foxes, villagers and vultures outright: 10-12 deaths a run each
	# against a baseline of 1-5, reported as starvation.
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
	# TWO measured quantities, and the distinction is the one physiology draws between FIELD metabolic rate and
	# aerobic CAPACITY. `_resp_rate` is what the animal actually burned, so it carries all the behaviour — a
	# flying bird against a dozing rabbit — and it is the ecologically real number. `_resp_capacity` is what its
	# surface and its air could have supported, which is the quantity the allometry is a law about. Fitting the
	# exponent on the first alone gives a badly behaviour-dominated slope over a roster this small.
	c._resp_rate = extent / maxf(delta * evo, 1e-6)
	c._resp_capacity = capacity / maxf(delta * evo, 1e-6)
	# ORNAMENT UPKEEP: a displaying male pays extra to hold his bright signal, which is what makes the signal
	# honest (LAAppraisal / LACreatureReproduction). Left as a direct reserve debit — it is a cost of holding
	# a structure, not a separate chemistry.
	c.energy -= LAAppraisal.display_upkeep(c, delta) * evo

	# --- 3. THE METABOLIC HEAT THAT OXIDATION RELEASES -----------------------------------------------------
	# ΔT = enthalpy released / (body mass × specific heat). The same oxidation that spends the fuel warms the
	# body — one reaction, two consequences, no separate "thermoregulation" mechanism anywhere.
	c.body_temp = float(c.body_temp) + extent * METABOLIC_HEAT_K / mass

	# --- 4. ONE FAILURE MODE: production below maintenance. ------------------------------------------------
	# Cold (band → 0), heat (band → 0 past denaturation), foul air (Liebig cap → 0) and an empty reserve all
	# arrive here as the same shortfall. The cause reported names which term was binding.
	# The comparison is CAPACITY against the requirement, not the throttled burn: an animal dozing in good air
	# is idling, not suffocating. What crosses this line is a body whose oxygen ran out, whose temperature band
	# collapsed, or which has simply outgrown the surface that has to feed its volume.
	var need: float = MAINTENANCE_K * mass * delta * evo
	if capacity < need:
		c.health -= (need - capacity) * DEFICIT_DAMAGE
		if c.health <= 0.0:
			c.die(deficit_cause(c, o2))
			return true
	if c.energy <= 0.0:
		c.die("starvation")
		return true
	return false


## The oxygen a body can actually get at `pos`, by the same medium rule LACreatureMetabolism.tick_breath uses:
## a GILL needs to be submerged, a LUNG needs breathable air. Read at the HEAD, which on a spherical planet is
## radially outward from the body — so a wading animal breathes and a submerged one does not, with no depth
## column and no can_fly branch.
static func breathable_at(c, pos: Vector3) -> float:
	var up: Vector3 = c.terrain.up_at(pos) if c.terrain != null and c.terrain.has_method("up_at") else Vector3.UP
	var head: Vector3 = pos + up * c.size
	if c.breathes == "water":
		return LAMaterialField3D.O2_AMBIENT if c._material.is_submerged_at(head.x, head.y, head.z) else 0.0
	return c._material.breathable_o2_at(head.x, head.y, head.z)


## Which term was binding when the body failed. A label on ONE mechanism, not a separate rule per cause — the
## reaction failed for want of temperature, of oxygen, or of fuel, and this only says which.
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
