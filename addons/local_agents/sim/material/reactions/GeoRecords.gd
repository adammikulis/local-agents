class_name LAGeoRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## GEOLOGICAL mineral records (M4 dust loft, M3 susp settle, D1a frost shattering, D1b the Urey reaction,
## D1c metamorphic decarbonation, D2 lithification).
##
## ===== THE ROCK HAS A CHEMISTRY NOW (2026-08-08), AND WHAT THIS DOMAIN OMITS ==============================
##
## Three mineral species, the division every long-term carbon-cycle model uses: silicate CaSiO3 (what the
## mantle makes), silica SiO2 (the weathering residue) and carbonate CaCO3 (where weathered carbon goes).
## Every pre-existing mineral phase — ROCK_FILL, LAVA, SEDIMENT, DUST, SUSP — is SILICATE, and has to be:
## they all exchange mass with one another at 1:1 through composition-preserving transfers, so they form one
## connected component and carry one composition. See LAReactionDefs.CARBONATE for that argument in full.
##
## WHAT IS DELIBERATELY NOT MODELLED, so nobody reads the omission as a claim:
##   * carbonate and silica DO NOT TRAVEL. They are own-cell stocks in the near-ground cell that weathered,
##     which is where a weathering rind and a carbonate crust physically are (in-situ basalt carbonation is a
##     real and well-measured process — it is what the CarbFix injections do). Real dissolved carbonate also
##     rides rivers to the sea; modelling that needs per-species SUSP and DUST channels, which needs
##     per-species erosion, slump, plate and dust-transport kernels, and no record in this table asks for one.
##   * neither lithifies. There is no limestone and no sandstone BEDROCK phase, so weathered material cannot
##     become new rock except by the decarbonation record D1c below, which reverses the whole reaction.
##     Adding sedimentary rock types means splitting `rock_fill`, and `solid` is derived from `rock_fill`, so
##     that reaches solidity, overburden, plate advection and the mineral stamp. It is the next increment,
##     not this one.
##   * carbonate and silica are not eroded, lofted or slumped, for the same reason.
## Each of those is an omission with a stated cost, not a physical claim that limestone is immobile.
##
## WHAT THE SINK MEASURES, three 600-frame runs at seed 4242, --sandbox --planet-only --fast=8, against three
## matched runs at the parent commit. All three of each, `field_step` 590 and `field_sim_s` 79.8:
##   carbonate_total  0.0288 / 0.0288 / 0.0288      (did not exist before)
##   silica_total     0.0177 / 0.0177 / 0.0177      ratio 1.627, against the stoichiometric 1.629
##   carbon_co2       26.75 / 26.75 / 26.72         against a baseline 81.64 / 81.53 / 81.27 — a 67% drawdown
##   carbon_all + the carbon in carbonate:
##                    845.90 / 845.88 / 845.87      against a baseline 845.95 / 845.95 / 846.02
## That last line is the conservation claim and it is mask-free: the reaction MOVED 91.4 units of carbon out
## of the air and into rock and destroyed 0.1 of them, which is fp noise on 846. `lith_ca_rel_drift_per_step`
## and its silicon twin both read 9.6e-11 per step, so calcium and silicon are conserved to eight decimal
## places over the run. Everything else is unmoved: temp_ground_p50 29.61-29.62 (baseline 29.56-29.59),
## soil_total 2929-2937 (2932-2944), snow_cells 944-949 (938-942), energy_imbalance_cool -1.0908 to -1.0914
## (-1.0918 to -1.0954), biomass_total 11.45 (11.52-11.59).
##
## D1c DID NOT FIRE IN ANY OF THOSE RUNS, and that is worth saying plainly rather than leaving as an
## assumption. Its threshold is 280.7 C and the hottest cell in the whole field reached 256.1 C (baseline
## 279.5); the hottest ground-level hot spring reached 185 C. So the return leg is present, wired and dormant:
## it needs hot rock sitting on weathered ground, which is a lava flow over an old surface, and this run drew
## one eruption. The sink is therefore ONE-WAY at these temperatures, and CO2 declines monotonically.
##
## ===== WHAT REPLACED THE OLD "WEATHERING" RECORD, AND WHY (2026-08-03) ====================================
##
## There used to be ONE record called D1 WEATHERING whose entire physics was `rate = max(0, 20 - T) * 0.004`.
## Its own comment justified the 20 by "the sim's actual open-cell temperature range", which is the exact tell
## CLAUDE.md names for a fitted constant, and the sign was backwards for both real mechanisms: it got FASTER
## the colder the planet got, without bound (0.152 of the bedrock per step at -18 C). It was also gated
## GATE_SURFACE, which on a shell is the TOP OF THE ATMOSPHERE, where `rock_fill` is 0 — so the record could
## not fire at all, and the runaway was theoretical only because the reaction was dead.
##
## The fix is not a better fitted law. Weathering is not a temperature rule; it is two DIFFERENT physical
## processes that the substrate already has all the parts for:
##
##   * FROST SHATTERING is WATER FREEZING IN A CRACK. Water is one of the few substances that EXPANDS on
##     freezing (9.07 %, from the measured densities of liquid water and ice Ih), and that expansion against
##     confining rock is what breaks it. So the rate is not a function of how cold it is — it is the mass of
##     pore water that actually turns to ice, times the rock that much expansion can displace. Every property
##     the old law tried to fake then falls out for free:
##       - Ground that NEVER freezes does no damage: no ice forms.
##       - Ground that never THAWS does no damage either: its pore water is already ice, so there is nothing
##         left to freeze. The reactant is liquid water, and permafrost has none.
##       - Damage therefore peaks where temperature CYCLES ACROSS 0 C, which is where real frost weathering
##         peaks, and no band model, no cycle counter and no `if freeze_thaw` is written anywhere.
##     It shares LAPhaseRecords.FREEZE_RATE with R21 because it is the same phase change; there is one
##     freezing kinetics in this substrate, not two.
##
##   * CHEMICAL WEATHERING is DISSOLUTION — silicate rock attacked by water carrying dissolved CO2 (carbonic
##     acid). Both reactants are already channels. It follows the ARRHENIUS law, which is what chemical
##     kinetics IS, so it is fastest WARM and stops without water, and the "roughly doubles per +10 C" that
##     every weathering textbook quotes is a consequence of the measured activation energy rather than a
##     number anyone typed. *(Its products were SUSP until 2026-08-08, on the grounds that dissolved load
##     leaves in the river. They are now CARBONATE and SILICA, because the reaction is CaSiO3 + CO2 ->
##     CaCO3 + SiO2 and neither product is calcium silicate. The transport that used to carry it downstream
##     is what the omission list above gives up.)*
##
## The mechanical leg deposits SEDIMENT in place (scree at the foot of the outcrop it broke off); the chemical
## leg leaves a carbonate-and-silica weathering rind on the outcrop. Two mechanisms, two products, and the
## difference between a talus slope and a weathering profile is not written down anywhere either.
##
## ===== WHY BOTH READ THE BEDROCK *BELOW* =================================================================
##
## The reaction engine runs in OPEN cells only (solid cells are skipped for race-freedom) and `rock_fill` is
## seeded 1.0/0.0 from solidity, so an open cell's OWN rock_fill is zero almost everywhere: there is no
## "partial boundary bedrock" for a surface record to eat. The rock a weathering process actually attacks is
## the cell it is standing on. That is the BEDROCK_BELOW slot — the same cross-cell move
## erosion_pickup_sphere3d.glsl already makes for river scour, and race-free for the same reason: each solid
## bed cell is the radial-DOWN neighbour of EXACTLY ONE open cell, so the write address is unique per thread.
## GATE_NEAR_GROUND is what guarantees the cell below is rock in the first place.

# --- MINERAL phase transfers (rock unification Stage A) — same-cell, conserving, own-cell writes only -------
# LOFT (M4, replaces dust_loft_sphere3d.glsl): wind over LOFT_WIND scours dry loose SEDIMENT into the SAME
# cell's airborne DUST (the box/sphere loft kernel scattered into the cell ABOVE — a cross-cell write that
# forbade a DEFS record; re-aiming to own-cell makes it a clean record and dust_transport lofts it up next
# step, design-blessed as near-identical). Constants copied from dust_loft_sphere3d.glsl. The reactant cap on
# SEDIMENT enforces "can't loft more than present"; the LOFT_MAX per-step cap is dropped (perf-over-parity —
# it only bit at hspeed>~22, and sediment-capped extent stays bounded regardless).
const LOFT_WIND: float = 6.0             # horizontal wind speed a dry surface must exceed to loft sand
const LOFT_RATE: float = 0.003           # sediment lofted per step per unit wind OVER the threshold
# SETTLE (M3, susp→sediment): turbid water drops its load. CONST_FRAC, ungated — the SAME fraction settles in
# every open cell, still or racing, which is what a constant Stokes settling velocity looks like on a fixed
# timestep: how fast a grain falls to the bed is a property of the GRAIN, not of the flow. What varies is how
# far the flow carries it while it falls, and that is ErosionTransportPass's job. So "drops its load when calm"
# was never what this record did — it drops the same fraction everywhere, and slack water keeps the sediment
# only because slack water does not move it anywhere. (Wording corrected 2026-08-03; the rate is unchanged.)
# NOT MODELLED: re-suspension of already-settled sediment by turbulent flow. Erosion pickup only lifts BEDROCK.
const SUSP_SETTLE_RATE: float = 0.05     # per-step fraction of suspended sediment that settles out

# --- D1a FROST SHATTERING (bedrock below → loose SEDIMENT here) --------------------------------------------
# ROCK DISPLACED PER UNIT OF PORE ICE FORMED. Freezing a mass m of water grows its volume by
# LAPhysical.ICE_FREEZE_EXPANSION (9.07 %, straight out of the measured densities of liquid water and ice Ih).
# In a confined pore that extra volume has to come from somewhere, and the only thing available is the rock
# around it, so the rock mass displaced is (excess volume) x (rock density):
#     dV = ICE_FREEZE_EXPANSION * m / rho_water   ->   dm_rock = dV * rho_rock
#        = ICE_FREEZE_EXPANSION * (rho_rock / rho_water) * m = 0.0907 * 2.9004 = 0.263 * m
# Nothing here is fitted: it is three measured densities and one arithmetic identity. It is also an UPPER
# bound (perfect confinement), which is the honest side to err on for a process whose real-world rate depends
# on fracture geometry nobody is modelling.
const FROST_ROCK_PER_ICE: float = LAPhysical.ICE_FREEZE_EXPANSION \
	* (LAPhysical.ROCK_DENSITY_KG_M3 / LAPhysical.WATER_DENSITY_0C_KG_M3)
# HOW MUCH WATER CAN BE IN THE ROCK AT ALL: its POROSITY. Only pore water is confined, and only confined water
# breaks anything — a puddle freezing on a flat slab just makes ice. The aux cap therefore limits the extent to
# ROCK_POROSITY_NEAR_SURFACE of the bedrock mass beneath, expressed as the divisor the record's cap applies.
const FROST_PORE_CAP_COEFF: float = 1.0 / LAPhysical.ROCK_POROSITY_NEAR_SURFACE

# --- D1b THE UREY REACTION: CHEMICAL WEATHERING AS A CARBON SINK -------------------------------------------
#     CaSiO3 + CO2 -> CaCO3 + SiO2
# Silicate rock, attacked by water carrying dissolved CO2, becomes carbonate plus a silica residue. This is
# the long-term carbon sink that has regulated Earth's climate for four billion years, and until 2026-08-08
# this planet did not have it.
#
# WHAT THE RECORD USED TO BE, AND WHY IT WAS WRONG. It read `[[BEDROCK_BELOW, 1.0]] -> [[SUSP, 1.0]]` with
# WATER as driver and CO2 as driver2 — both CATALYSTS, consumed by neither side. Its own comment said so and
# defended it: "CO2 IS A DRIVER, NOT A REACTANT, AND THAT IS DELIBERATE ... This substrate has no carbonate
# reservoir, so debiting CO2 here would DESTROY carbon". The defence was sound about the ledger and wrong
# about the fix: the answer to "there is nowhere for the carbon to go" is to build the place it goes, not to
# leave the reaction chemically false. It also made the conservation gate's own justification circular — the
# gate declared minerals a lumped mass because "nothing converts between M and C/H/O/N", which was true only
# because of this record.
#
# THE RATE LAW is unchanged and is Arrhenius, first order in the solvent (WATER, the driver) and first order
# in the acid (CO2, driver2):
#     x = DISSOLUTION_K * water * co2 * exp(-(Ea/R) * (1/T - 1/T_ref))
# with Ea and T_ref the measured activation energy of silicate dissolution and the temperature laboratory
# rates are quoted at (both LAPhysical). None of that shape is adjustable. What IS a model parameter is the
# PREFACTOR: this substrate has no mineral surface area, no molality and no pH, so there is no way to carry a
# laboratory mol/m^2/s through to a per-cell per-step extent. DISSOLUTION_K is the model's timescale for the
# reaction, exactly like FREEZE_RATE and SOLIDIFY_RATE are for theirs.
#
# CO2 IS NOW A REACTANT AS WELL AS THE SECOND CONCENTRATION, which is ordinary chemistry: a reaction is first
# order in a species it consumes. The coefficient is not typed, it is `unit_ratio(CO2, BEDROCK_BELOW)` — one
# mole of CO2 per mole of CaSiO3, converted between the two channels' molar bases by the one declaration in
# LAReactionBalance.mol_per_unit(). It comes out near 2925, because a cell full of rock holds 24966 mol of
# silicate and a cell of air holds 8.5 mol of gas per unit: carbonating a whole cell of basalt takes thousands
# of cells' worth of air, which is exactly why the sink is slow and why it is CO2-supply-limited rather than
# rock-limited. That limitation is the thermostat.
#
# THE VALUE OF DISSOLUTION_K, stated plainly so it is never mistaken for a physical fact.
# *(Corrected 2026-08-08. The paragraph here quoted the ambient CO2 channel value as "0.28" and "0.277". It is
# LAMaterialField3D.CO2_AMBIENT = O2_AMBIENT * (AIR_MOLE_FRAC_CO2 / AIR_MOLE_FRAC_O2) = 0.00200 — 139 times
# smaller. The old figures were measured before the atmosphere was re-seeded finite at Earth's measured
# composition and were never re-taken, so every extent this comment quoted was 139x too large.)*
# THE VALUE IS LEFT WHERE IT WAS, AND MEASUREMENT SAYS IT IS ABOUT RIGHT. It was set against the ROCK side
# alone, back when CO2 was a catalyst, so making CO2 a real reactant could easily have exposed it as fitted.
# It did not. Measured over three 600-frame runs at seed 4242 (`carbonate_total` 0.0288 in all three, over
# 12817-12828 weathering cells), the reaction removes 0.0312 cell-units of bedrock, which spread over those
# cells and multiplied by the 500 model metres a cell stands for is a surface lowered by 1.22 mm. On the
# geological clock this project already declares (LAPlateTectonics.GEOLOGIC_TIME_ACCELERATION = 3.0e5), a
# 600-frame run covers 242 accelerated years, in which real basaltic chemical denudation — ~17 um/yr, the
# figure PlateTectonics.gd:39 already cites — lowers 4.12 mm. So this record runs at 0.30x the real chemical
# denudation rate of basalt: the right process at the right order, not a number chosen to make an output look
# good. That file's rule ("anything that makes weathering visible in one run has broken the ratio") is
# satisfied — 1.22 mm against a 500 m cell is invisible in the terrain and is meant to be.
#
# THE CARBON SIDE IS NOT INVISIBLE, and that asymmetry is real rather than an artefact: a cell full of rock is
# thousands of cells' worth of air, so a denudation nobody can see is a CO2 flux everybody can. Measured:
# `carbon_co2` ends at 26.7 units against a baseline 81.5, a 67% drawdown of the atmosphere's CO2 in 242
# accelerated years. Earth loses about 8% of its atmospheric carbon to silicate weathering over the same span,
# and the difference is structural, not a mis-set rate — this planet's atmosphere is a few cells deep over
# every weathering cell, so its CO2 reservoir is thin relative to the reacting surface, and D1c (the volcanic
# return that balances the sink on Earth) never fires at these temperatures. See the module header.
const DISSOLUTION_K: float = 2.0e-5

# --- D1c METAMORPHIC DECARBONATION: THE RETURN LEG ---------------------------------------------------------
#     CaCO3 + SiO2 -> CaSiO3 + CO2
# The same reaction run backwards, which is what happens when carbonate rock gets hot. It is the
# wollastonite-forming reaction of contact and regional metamorphism, and it is how buried and subducted
# limestone gives its carbon back to the air — volcanic CO2 outgassing IS this reaction, so the substrate gets
# it as a record and not as a scripted emission from a volcano actor.
#
# WITHOUT IT THE SINK IS ONE-WAY, and a one-way sink strips an atmosphere. That is not a hypothetical: with
# only D1b, `co2` decays toward zero and nothing can ever return it, so the planet's carbon would end as
# limestone permanently. Earth has both legs and so does this.
#
# The threshold is LAPhysical.DECARBONATION_TEMP_C, DERIVED as dH/dS from the standard-state thermodynamics of
# the four phases (280.7 C at one bar of CO2), not chosen. The rate constant is LAPhaseRecords.ROCK_MELT_RATE,
# shared rather than duplicated for the same reason D1a shares FREEZE_RATE: this is a temperature-driven
# solid-state transformation of rock and the substrate has ONE kinetics for that, not two. Inventing a second
# per-step constant here would be a fitted number with nothing behind it.
#
# It fires where hot rock and carbonate coexist — a lava flow over a weathered surface, a geothermal cell. On
# a cool planet that is rare, and rare is correct: the return leg is a geological one.

# --- D2 LITHIFICATION (loose SEDIMENT → bedrock) -----------------------------------------------------------
# Sediment becomes rock because it is BURIED. It used to become rock because there was more than half a cell
# of it (`LITH_DEPTH 0.5`, ungated), which fires on exposed surface sediment — including in the same cell and
# the same step as weathering, a futile cycle the registry's own header names.
#
# The real condition is an EFFECTIVE STRESS: the weight of the solid column overhead. That is now a computed
# quantity, the OVERBURDEN slot, not a threshold anybody picked, and the pressure it must reach is the one
# LAPhysical already defines from the depth at which porosity closes under lithostatic load. The futile cycle
# ends without a gate: a cell with sky above it has no overburden, so lithification cannot fire where
# weathering can.
#
# THE OBJECTION THAT THIS "TURNS WEATHERED SAND BACK INTO IGNEOUS BEDROCK" WAS RIGHT ABOUT THE OLD TABLE AND
# IS ANSWERED BY THE SPECIES SPLIT, not by changing this record. `sediment` is no longer any kind of sand: it
# is MECHANICALLY shattered calcium silicate — frost-shattered chips (D1a), river load scoured off bedrock
# (erosion pickup, settled by M3) and wind-deposited dust of the same. Cementing that into silicate bedrock is
# greywacke and arkose, real sedimentary rocks made of exactly the minerals of the rock they came from, and it
# conserves every element because both sides are CaSiO3. What was chemically weathered is CARBONATE and
# SILICA, and neither has a lithification record at all — the only way out of them is D1c decarbonation at
# 280.7 C. So the CHEMICAL cycle closes only through heat, which is the property that was actually wanted;
# the mechanical one closes through burial, which is how the rock cycle works.
const LITH_RATE_PER_PA: float = 1.0e-9   # per-step k on x = max(0, P - P_lith) * k. One extra cell of rock
                                         # burial is 14.2 MPa, so it lithifies ~1.4 % of its sediment per step.


## The records this domain contributes to the live table (see LAMaterialReactions3D).
static func records() -> Array:
	return [
		# M4 — DUST LOFT (loose → airborne): wind over LOFT_WIND scours dry loose SEDIMENT into the OWN cell's
		# airborne DUST. EXCESS_OVER_THRESHOLD on WINDSPEED (sqrt(vel_x²+vel_z²), the derived driver), gated
		# GATE_DRY (water<=WET_MAX_LOFT) + GATE_NOT_RAINING. Reactant cap on SEDIMENT. REPLACES + DELETES
		# dust_loft_sphere3d.glsl (the cross-cell scatter into the cell above → re-aimed own-cell; transport
		# lofts it up next step). A conserving sediment→dust transfer of the ONE mineral substance.
		rec(EXCESS_OVER_THRESHOLD, LOFT_RATE, WINDSPEED, [[SEDIMENT, 1.0]], [[DUST, 1.0, TGT_SELF]],
			GATE_DRY | GATE_NOT_RAINING, LOFT_WIND),

		# M3 — SUSP SETTLE (suspended → loose): turbid water drops its load. CONST_FRAC on SUSP →
		# SEDIMENT (own-cell, conserving). LIVE: ErosionPickupPass (MaterialSphereGPU3D.gd) scours rock_fill
		# into susp immediately before ReactionsPass, and D1b below adds the dissolved load, so the settle
		# reads the same step's suspension and closes rock→susp→sediment.
		rec(CONST_FRAC, SUSP_SETTLE_RATE, SUSP, [[SUSP, 1.0]], [[SEDIMENT, 1.0, TGT_SELF]], 0),

		# D1a — FROST SHATTERING (bedrock below → loose SEDIMENT here). Pore water in the rock beneath freezes,
		# expands, and displaces rock. DEFICIT_BELOW_THRESHOLD on TEMP at the REAL freezing point of water
		# (LAPhysical.WATER_FREEZE_C, shared with R21) times the same FREEZE_RATE, because this IS R21's phase
		# change happening inside a pore. Extent x = the mass of water that freezes; it is capped three ways,
		# and every cap is a physical statement:
		#   * by the liquid WATER present  — no water, no ice, no damage (and permafrost has none left);
		#   * by BEDROCK_BELOW / FROST_ROCK_PER_ICE — cannot break rock that is not there;
		#   * by the aux cap BEDROCK_BELOW / FROST_PORE_CAP_COEFF — only the POROSITY fraction of the rock can
		#     hold water in the first place, and only confined water breaks anything.
		# Conserving twice over: H2O water→snow 1:1, mineral rock→sediment 1:1 at FROST_ROCK_PER_ICE.
		# (The pore water modelled here is the cell's own liquid water in contact with the outcrop. Real
		# periglacial ground also draws water UP from the water table by cryosuction to grow ice lenses; that
		# would be the SOIL_ROOT slot as the reactant, and it is not modelled.)
		rec(DEFICIT_BELOW_THRESHOLD, LAPhaseRecords.FREEZE_RATE, TEMP,
			[[WATER, 1.0], [BEDROCK_BELOW, FROST_ROCK_PER_ICE]],
			[[SNOW, 1.0, TGT_SELF], [SEDIMENT, FROST_ROCK_PER_ICE, TGT_SELF]],
			GATE_NEAR_GROUND, LAPhysical.WATER_FREEZE_C, -1, 0.0, BEDROCK_BELOW, FROST_PORE_CAP_COEFF),

		# D1b — THE UREY REACTION (bedrock below + atmospheric CO2 → carbonate + silica here).
		#     CaSiO3 + CO2 -> CaCO3 + SiO2
		# ARRHENIUS on the settled TEMP, first order in WATER (the driver, because the reaction needs a
		# solvent) and in CO2 (driver2, the acid), capped by the bedrock beneath AND by the CO2 present.
		# Fastest warm and wet, zero where there is no liquid water, and roughly doubling per +10 C because
		# that is what LAPhysical.SILICATE_DISSOLUTION_EA_J_MOL says, not because anyone tuned it.
		#
		# EVERY COEFFICIENT IS 1:1 IN MOLES. `unit_ratio(slot, BEDROCK_BELOW)` is how many units of `slot`
		# hold the moles that one unit of bedrock holds, read off LAReactionBalance.mol_per_unit(), so the
		# stoichiometry stays visible as the 1:1:1:1 it is and the conversion cannot be mistyped.
		#
		# THE AQUEOUS CEILING IS THIS RECORD'S, NOT THE RATE MODEL'S. *(Moved 2026-08-09; behaviour
		# unchanged.)* A reaction between rock and LIQUID WATER cannot proceed where there is no liquid
		# water, so the exponential is evaluated at min(T, water's boiling point) — without it a 154 C
		# lava-adjacent cell asks for a rate a thousand times the reference and this record dissolves a whole
		# cell of bedrock in one step. That clamp used to be a LITERAL inside the kernel's ARRHENIUS branch,
		# which applied WATER's phase boundary to every Arrhenius record there will ever be. It is the
		# `t_ceiling_k` argument now; combustion, which has no solvent, passes 0 for "no ceiling".
		rec(ARRHENIUS, DISSOLUTION_K, WATER,
			[[BEDROCK_BELOW, 1.0], [CO2, LAReactionBalance.unit_ratio(CO2, BEDROCK_BELOW)]],
			[[CARBONATE, LAReactionBalance.unit_ratio(CARBONATE, BEDROCK_BELOW), TGT_SELF],
				[SILICA, LAReactionBalance.unit_ratio(SILICA, BEDROCK_BELOW), TGT_SELF]],
			GATE_NEAR_GROUND, LAPhysical.SILICATE_DISSOLUTION_EA_OVER_R_K, CO2,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, LAPhysical.WATER_BOIL_C + LAPhysical.KELVIN_OFFSET),

		# D1c — METAMORPHIC DECARBONATION (carbonate + silica → bedrock below + CO2 here). D1b run backwards
		# at metamorphic temperature: CaCO3 + SiO2 -> CaSiO3 + CO2. EXCESS_OVER_THRESHOLD on TEMP at
		# LAPhysical.DECARBONATION_TEMP_C, capped by both solid reactants → a conserving return of the carbon
		# to the air and of the calcium and silicon to the rock. It is placed AFTER D1b deliberately: the two
		# share CARBONATE and SILICA, and within one cell records chain in list order (see
		# LAMaterialReactions3D's ORDER IS NOT IRRELEVANT note). Running the sink first and the source second
		# is the physically ordered pair — a cell cannot decarbonate carbonate that this step's weathering has
		# not made yet — and no futile cycle results, because the Arrhenius ceiling at boiling plus the
		# absence of liquid water make D1b's extent negligible wherever D1c can fire at all.
		rec(EXCESS_OVER_THRESHOLD, LAPhaseRecords.ROCK_MELT_RATE, TEMP,
			[[CARBONATE, 1.0], [SILICA, LAReactionBalance.unit_ratio(SILICA, CARBONATE)]],
			[[BEDROCK_BELOW, LAReactionBalance.unit_ratio(BEDROCK_BELOW, CARBONATE), TGT_SELF],
				[CO2, LAReactionBalance.unit_ratio(CO2, CARBONATE), TGT_SELF]],
			GATE_NEAR_GROUND, LAPhysical.DECARBONATION_TEMP_C),

		# D2 — LITHIFICATION (loose → bedrock): buried SEDIMENT compacts and cements into ROCK_FILL under the
		# weight of the solid column above it. EXCESS_OVER_THRESHOLD on the derived OVERBURDEN pressure (Pa):
		# x = max(0, P - LITHIFICATION_PRESSURE_PA) * LITH_RATE_PER_PA, capped by the SEDIMENT present →
		# conserving sediment→rock_fill transfer. Surface sediment has no overburden and therefore cannot
		# lithify, which is what ends the D1/D2 futile cycle — no gate, no threshold anybody chose.
		rec(EXCESS_OVER_THRESHOLD, LITH_RATE_PER_PA, OVERBURDEN, [[SEDIMENT, 1.0]],
			[[ROCK_FILL, 1.0, TGT_SELF]], 0, LAPhysical.LITHIFICATION_PRESSURE_PA),
	]
