class_name LAGeoRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## GEOLOGICAL mineral records (M4 dust loft, M3 susp settle, D1a frost shattering, D1b chemical dissolution,
## D2 lithification).
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
##     number anyone typed. Its product is SUSP, the waterborne mineral phase: dissolved load leaves in the
##     river. ErosionTransportPass then carries it downstream and M3 settles it where the flow slackens, so
##     chemical weathering feeds the depositional system through machinery that already exists.
##
## The mechanical leg deposits SEDIMENT in place (scree at the foot of the outcrop it broke off); the chemical
## leg deposits SUSP into the water (dissolved load). Two mechanisms, two products, and the difference between
## a talus slope and a river's sediment budget is not written down anywhere either.
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
	* (LAPhysical.ROCK_DENSITY_KG_M3 / LAPhysical.WATER_DENSITY_KG_M3)
# HOW MUCH WATER CAN BE IN THE ROCK AT ALL: its POROSITY. Only pore water is confined, and only confined water
# breaks anything — a puddle freezing on a flat slab just makes ice. The aux cap therefore limits the extent to
# ROCK_POROSITY_NEAR_SURFACE of the bedrock mass beneath, expressed as the divisor the record's cap applies.
const FROST_PORE_CAP_COEFF: float = 1.0 / LAPhysical.ROCK_POROSITY_NEAR_SURFACE

# --- D1b CHEMICAL WEATHERING (bedrock below → waterborne SUSP) ---------------------------------------------
# The rate law is Arrhenius, first order in the solvent (WATER) and first order in the acid (CO2):
#     x = DISSOLUTION_K * water * co2 * exp(-(Ea/R) * (1/T - 1/T_ref))
# with Ea and T_ref the measured activation energy of silicate dissolution and the temperature laboratory
# rates are quoted at (both LAPhysical). That shape is the physics and none of it is adjustable. What IS a
# model parameter is the PREFACTOR: this substrate has no mineral surface area, no molality and no pH, so
# there is no way to carry a laboratory mol/m^2/s through to a per-cell per-step extent. DISSOLUTION_K is the
# model's timescale for the reaction, exactly like FREEZE_RATE and SOLIDIFY_RATE are for theirs, and it is the
# only number in this record that a measurement may move.
#
# CO2 IS A DRIVER, NOT A REACTANT, AND THAT IS DELIBERATE. Real silicate weathering CONSUMES CO2 — it is the
# long-term sink that regulates Earth's climate — and the carbon ends up locked in carbonate rock. This
# substrate has no carbonate reservoir, so debiting CO2 here would DESTROY carbon rather than move it, and the
# carbon ledger (LAMaterialFieldMassBudget3D: carbon_total = co2 + biomass + detritus) would book it as a leak.
# Creating or destroying matter is not a modelling shortcut this repo takes. The acid still sets the rate,
# which is the part that matters for the rock; closing the loop needs a carbonate leg in the mineral ledger,
# and that is a decision for whoever owns the carbon cycle.
#
# WHERE THE VALUE COMES FROM, stated plainly so it is never mistaken for a physical fact. The binding
# constraint is the HOT end, because Arrhenius spans a factor of 240 between this planet's median ground
# temperature (17.6 C) and water's boiling point, and the hot cells are the geothermal springs. At 2.0e-5 a
# boiling spring cell (water 1, co2 0.28) dissolves 7.3e-4 of a bedrock cell per step — about 0.4 of a cell
# over an 80-simulated-second run — so hydrothermal alteration is a real, bounded process rather than a hole
# appearing in the ground. The same constant at the median temperate condition (water 0.5, co2 0.277) gives
# 1.5e-6 per step, which is the correct SHAPE and not an accident: chemical weathering of cold rock IS slow,
# and it is hot water that eats rock quickly.
const DISSOLUTION_K: float = 2.0e-5

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

		# D1b — CHEMICAL WEATHERING (bedrock below → waterborne SUSP here). Silicate dissolution by water
		# carrying dissolved CO2. ARRHENIUS on the settled TEMP, first order in WATER (the driver) and in CO2
		# (driver2), capped by the bedrock beneath → a conserving rock_fill→susp transfer. Fastest warm and wet,
		# zero where there is no liquid water, and roughly doubling per +10 C because that is what
		# LAPhysical.SILICATE_DISSOLUTION_EA_J_MOL says, not because anyone tuned it. The dissolved load then
		# rides the river (ErosionTransportPass) and settles downstream (M3) with no further code.
		rec(ARRHENIUS, DISSOLUTION_K, WATER, [[BEDROCK_BELOW, 1.0]], [[SUSP, 1.0, TGT_SELF]],
			GATE_NEAR_GROUND, LAPhysical.SILICATE_DISSOLUTION_EA_OVER_R_K, CO2,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET),

		# D2 — LITHIFICATION (loose → bedrock): buried SEDIMENT compacts and cements into ROCK_FILL under the
		# weight of the solid column above it. EXCESS_OVER_THRESHOLD on the derived OVERBURDEN pressure (Pa):
		# x = max(0, P - LITHIFICATION_PRESSURE_PA) * LITH_RATE_PER_PA, capped by the SEDIMENT present →
		# conserving sediment→rock_fill transfer. Surface sediment has no overburden and therefore cannot
		# lithify, which is what ends the D1/D2 futile cycle — no gate, no threshold anybody chose.
		rec(EXCESS_OVER_THRESHOLD, LITH_RATE_PER_PA, OVERBURDEN, [[SEDIMENT, 1.0]],
			[[ROCK_FILL, 1.0, TGT_SELF]], 0, LAPhysical.LITHIFICATION_PRESSURE_PA),
	]
