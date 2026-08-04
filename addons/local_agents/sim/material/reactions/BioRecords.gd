class_name LABioRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## LIVING-CARBON records (R15 fungus decompose, R19 photosynthesis, R20 respiration + decay).

const DECOMPOSE_RATE: float = 0.05

# OXYGEN OBEYS AN IDENTITY, NOT A TUNING TARGET. Photosynthesis and aerobic oxidation are exact inverses:
#   CO₂ + H₂O + light -> CH₂O + O₂      one O₂ RELEASED per carbon fixed
#   CH₂O + O₂         -> CO₂ + H₂O      one O₂ CONSUMED per CO₂ produced
# So every oxidation record in this table must satisfy  O₂ consumed == CO₂ produced.  It did not:
# R15 decompose was 0.8 against 1.0, and R20 respiration 0.5 against 0.6 — both ~18% under-oxidised, both in
# the same direction. Traced through one unit of carbon (fix -> respire -> decompose the litter) the loop
# closed on carbon exactly (0.6 + 0.4 == 1.0, an unremarked and untested coincidence) while MINTING 0.18 O₂
# per cycle, forever. Measured by the new mass ledger before the fix: carbon +6.48/step, fertility +2.24/step
# from a first sample of exactly 0.0. Oxygen read flat only because R11's sky pin is an unbounded source that
# absorbed the surplus — the mint was real and invisible.
# Setting these equal closes oxygen ANALYTICALLY, for any rate, with nothing left to tune.
const CO2_PER_DECOMPOSE: float = 1.0
const O2_PER_DECOMPOSE: float = 1.0      # == CO2_PER_DECOMPOSE, by the identity above (was 0.8)

# FERTILITY COMES OUT OF THE LITTER, and litter has a finite nutrient content. This was 1.5 — one unit of
# detritus produced 1.5 units of nutrient, from no source pool at all, against an uptake of 0.02: a 29:1
# amplifier. Real mineralisation releases the nitrogen that was ALREADY in the litter, bounded by its C:N
# ratio — about 20:1 for leaf litter, 10:1 for soil organic matter. So the yield is 1/20, and plant uptake
# must debit at the same ratio or the books cannot close. FERT_UPTAKE_COST is set to match below.
# This is why the old FERT_UPTAKE_COST was cut 25x "so it only binds where fert is genuinely near-zero":
# nutrient limitation was removed rather than the nutrient SOURCE being fixed. With both at the C:N ratio,
# Liebig limitation by nutrient becomes real again and a barren soil genuinely limits growth.
# MOVED to LAPhysical 2026-08-03: the carbon-to-nitrogen ratio of leaf litter is a measured property of the
# material, not a model parameter, and it is now the SAME declaration LAReactionBalance uses to say what
# organic matter is made of. That is what turns "mineralisation releases the nitrogen that was already in the
# litter" from a comment into an arithmetic identity the balance gate checks: the release coefficient here,
# the uptake coefficient below, and the nitrogen content of biomass/detritus/fungus are one number.
const LITTER_C_TO_N: float = LAPhysical.LITTER_C_TO_N
const FERT_PER_DECOMPOSE: float = 1.0 / LITTER_C_TO_N      # 0.05 (was 1.5)

# PHOTOSYNTHESIS: CO₂ + H₂O + light → biomass + O₂. LIGHT drives it, and light is now the real thing —
# max(0, dot(cell_radial, sun_dir)) — not a stand-in.
#
# WHAT THIS REPLACED, and why it was wrong. The rate used to be x = PHOTO_RATE * co2 * TEMP, with temperature
# standing in for daylight on the argument that "the day side is warmer". Temperature is not light. It lags the
# terminator by the thermal time constant, it is raised by anything hot, and it is not raised at all by a bright
# cold day. So the old law had a hot desert fixing carbon at midnight, a bright polar summer fixing almost none,
# lava flows and wildfires growing plants, and dust dimming suppressing growth only second-hand by cooling.
# Every one of those is gone: light is light now, and it comes from the same sun_dir the solar kernel uses, so
# there is exactly one sun in this simulation and its magnitude (orbit distance² × atmospheric transmission)
# dims the chemistry directly.
#
# WHERE IT RUNS, and why that moved. The record was gated GATE_SURFACE, which on a shell means the outermost
# open cell of a radial line — the TOP OF THE ATMOSPHERE, ~78 world-units above the terrain. Measured on
# 2026-07-29 (seed=777, --fast=4, 400 frames): biomass at the sky skin 2334, biomass at the ground skin 0.0.
# All primary production was happening in the stratosphere, and two other systems had grown workarounds for it
# (EcologyService._biomass_at sampled at the shell-top radius; fungus_fert_sphere3d deposited the column's whole
# fertility into the sky cell). It is GATE_NEAR_GROUND now — the ground-hugging cell that has rock beneath it,
# which is where a plant is, where its roots can reach soil, and where the moisture it transpires belongs.
# GATE_NOT_STATIC additionally keeps it out of the infinite sea reservoir, which is an unsimulated abstraction.
#
# MEASURED INPUTS the constants below are set from (same run; 2156 land ground-skin cells):
#   light      mean 0.281, p50 0.069, max 0.988, lit (>0.05) 50.7% of cells
#   ground temp mean 12.2 °C, p10 2.9, p50 7.6, p90 24.5  (much colder than the 29.0 open-cell mean — the
#              ground skin is where the altitude lapse bites and where the night side actually cools)
#   ground CO₂  mean 0.0404, p10 0.0323  (RICHER than the 0.030 global mean — respiration happens at the ground,
#              so moving the record there does not starve it of carbon)
#   rooting-column water  mean 0.702, p10 2.6e-7, p50 0.805, p90 1.275, max 1.904;
#              13.4% of land is bone dry (<0.01) and 39.0% is dry (<0.5)
# PHOTO_RATE — MEASURED, and the measurement overturned the obvious guess. 0.04 reproduces the OLD per-cell
# extent (old x ≈ 0.4·co2 ≈ 0.012/step at co2 ≈ 0.030; new x at the mean lit ground cell = 0.04·0.554·0.55 ≈
# 0.012/step) and gave biomass_total 689. Reasoning that equilibrium biomass = fixation/RESP_RATE is linear in
# the rate, 0.12 was tried to lift the total back toward the 3271–4306 baseline. It did the OPPOSITE:
# biomass_total 320, and ground CO₂ fell from 0.0710 to 0.0313 with a p10 of 0.0015. Tripling the rate does not
# triple fixation, because on the GROUND the binding constraint is not the rate, it is how fast CO₂ gets down
# here from the sky trace. A rate that outruns delivery just strips the local carbon to zero every step, which
# also starves the cells that would otherwise have fixed slowly, so net production FALLS. Back near 0.05, where
# CO₂ sits comfortably above the extent and Liebig binds only at the brightest cells — which is the regime the
# whole record is supposed to be in.
const PHOTO_RATE: float = 0.05           # per-step k on x = PHOTO_RATE * light * band(temp)
const PHOTO_O2_YIELD: float = 1.0        # O₂ released per unit CO₂ fixed (stoichiometric ~1:1)
const PHOTO_BIOMASS_YIELD: float = 1.0   # biomass grown per unit CO₂ fixed
# TEMPERATURE OPTIMUM (the OPTIMUM_BAND parameters). Photosynthesis stops frozen and stops cooked; between
# those it peaks. band(T) = max(0, 1 - ((T - PHOTO_T_OPT)/PHOTO_T_WIDTH)^2) → zero at 0 °C and at 48 °C, peak at
# 24 °C. Against the measured ground temperature spread that gives band ≈ 0.23 at the p10 cold tail (2.9 °C),
# 0.53 at the median (7.6 °C), 0.76 at the mean (12.2 °C) and ~1.0 at the warm p90 (24.5 °C) — a real gradient,
# not an on/off gate. The upper edge is what stops a lava flow or a wildfire from growing plants: those cells
# are hundreds of °C, far outside the band, so the rate is exactly 0 with no "is it lava" test anywhere.
const PHOTO_T_OPT: float = 24.0          # °C at which carbon fixation peaks
const PHOTO_T_WIDTH: float = 24.0        # °C from the optimum to where it stops (so: 0 °C and 48 °C)
# TRANSPIRATION: water cost per unit of carbon fixed, moved soil → moisture as a CONSERVING PHASE TRANSFER
# (roots take up liquid groundwater, leaves release vapour) — the same debit-one-credit-the-other pattern R21/R22
# freeze/melt use, so nothing leaves the H₂O ledger. It is BOTH the third Liebig reactant (the extent cannot
# exceed rooting_column_water / PHOTO_WATER_COST) and the mechanism that makes deserts.
# SIZED, not guessed. The failure mode to avoid is documented directly below on FERT_UPTAKE_COST: a per-step
# SINK competes against a stock's NET ACCUMULATION RATE, not its peak. Measured land groundwater: 2156 columns
# × 0.702 = 1514 units, draining to the sea at ~5.8 units/step (2587 seeded → 1514 over ~169 steps).
#
# HOW WATER ACTUALLY LIMITS HERE, which is not what a first reading of "Liebig reactant" suggests. The reactant
# cap is a CLIP (`x ≤ stock/cost`), not a graded response, so it only bites once the local stock is nearly gone.
# It therefore does two distinct things at two timescales: IMMEDIATELY it zeroes the cells whose rooting column
# is already empty (the measured 13.4% of land at <0.01, and 2.6e-7 at the 10th percentile — these are deserts
# from the first step), and SLOWLY it expands that set, because transpiration pulls on every lit cell while
# lateral Darcy flow only refills the cells water CONVERGES into. Ground that gets no convergence loses the
# drawdown race and joins the desert. This constant sets the speed of the second process.
#
# SIZE IT AGAINST THE REALISED EXTENT, NOT THE LIGHT-LIMITED ONE. The realised extent is ~0.003/step, six times
# smaller than the light-limited ~0.02, because CO₂ and the night side hold it down — so a first sizing off the
# light-limited rate over-costs the water by 6x. Same trap the FERT_UPTAKE_COST note below records: a per-step
# sink competes against a RATE, and it has to be the rate that actually happens.
#
# MEASURED at 0.2, 0.45 and 0.0 (same seed, same everything else). 0.2 wins outright, and it wins for a reason
# worth writing down: raising the cost does not deepen the water limitation, it SHALLOWS it. At 0.45 growth on
# marginal ground is throttled, so those plants transpire less, so the table draws down LESS and fewer cells
# ever cross into limitation — biomass_total 318, lit wet/dry contrast 16.3x, dry land 41.0%. At 0.2 plants on
# marginal ground still grow, transpire more in total, and pull the table down further — biomass_total 781, lit
# wet/dry contrast 51.8x, dry land 43.3%. The sink is self-limiting, so the cheaper cost yields both more
# vegetation and more desert. That is not what the sizing argument above predicts; the runs said otherwise, and
# the runs win.
#
# THE TRANSFER DOES NOT LEAK, and the control that proves it is this constant set to 0.0 — transfer disabled,
# everything else identical, same seed. h2o_total 9556.61 (off) vs 9648.66 (on) = +0.96%, well inside the ±5%
# run-to-run spread the baseline shows on its own. And the mass is accounted for on both sides:
# soil_total 3942.75 -> 3590.86 (-351.9), moisture_total 4972.69 -> 5382.61 (+409.9). The same control also
# isolates the water leg's ONLY behavioural effect: lit wet/dry biomass contrast 0.94 with it off (flat — dry
# and wet ground carry the same biomass) against 51.8 with it on.
#
# RE-MEASURED 2026-07-30 AT 0.05, WHICH BEATS 0.2 ON EVERY AXIS. Every run quoted above used `--fast=4`, and
# that flag did nothing at all: Engine.time_scale had two owners and the command line's value was always
# overwritten (see LAVoxelTimeControl.set_multiplier). So those numbers are 1x over a shorter horizon than
# their author believed, and none of them reached even a tenth of a simulated day. Re-run with a working
# fast-forward — same seed 4242, --fast=2, 300 frames, 0.8 simulated days, everything else identical:
#     cost 0.2  -> biomass_ground  708, lit wet/dry 1.14, h2o_total 10300, trees 400
#     cost 0.05 -> biomass_ground 1143, lit wet/dry 6.86, h2o_total 10981, trees 400
# More vegetation, six times the wet/dry contrast, and less water lost. The reason inverts the note above: a
# cost this heavy makes the water cap bind almost EVERYWHERE, wet ground included, which flattens the very
# contrast the reactant exists to create. Liebig only says something when exactly ONE input is scarce. This is
# the FERT_UPTAKE_COST trap again — that constant was cut 25x for the same reason — and it is now twice in
# this one file that the honest size was far gentler than the sizing argument predicted.
const PHOTO_WATER_COST: float = 0.05     # soil water transpired per unit CO₂ fixed (debit SOIL_ROOT, credit MOISTURE)
# THE STOICHIOMETRIC WATER, WHICH WAS MISSING ENTIRELY. Photosynthesis is CO₂ + H₂O -> CH₂O + O₂: one water
# SPLIT per carbon fixed, its hydrogen built into the sugar and its oxygen released as the O₂. That leg had
# no coefficient at all, so the biomass this record produced contained hydrogen that came from nowhere and
# the O₂ it released came from nowhere with it. The old balance table could not see it, because it declared
# an `h2o` substance rather than H and O atoms.
#
# IT IS DERIVED, NOT CHOSEN: 1.0 per unit of CO₂, because that is the reaction. The root draw is therefore
# the stoichiometric water plus the transpiration above, and only the transpired part is returned to the air
# as vapour — the split part leaves as biomass and comes back when that biomass is respired or rots.
#
# NOTE WHAT THIS SAYS ABOUT THE MODEL, since it inverts a real ratio. Real transpiration moves 200-1000
# molecules of water per carbon fixed, so on Earth the stoichiometric leg is a rounding error beside it. Here
# the transpiration coefficient is 0.05, so the leg that is negligible in reality is TWENTY TIMES the leg
# this substrate models. That is a statement about PHOTO_WATER_COST being four orders too small, which is the
# same finding HANDOFF records as "the atmosphere holds 30% of the planet's H₂O against Earth's 0.001%". It
# is not a reason to leave the stoichiometry out.
const PHOTO_WATER_DRAW: float = 1.0 + PHOTO_WATER_COST   # split (1.0, becomes biomass) + transpired (returned)
# NUTRIENT UPTAKE (closes the "fertility actually feeds plants" gap — bio-0.4-shipped left this open): FERT is
# now a second reactant on R19, so growth is co-limited by CO₂ AND soil fertility (Liebig's-law-of-the-minimum,
# same reactant-cap machinery that already caps CO2 — no new rate model needed).
#
# TUNING HISTORY (measured, same-seed A/B on --sandbox, frame 600, seed=777 so both runs hit the identical
# eruption/impact timeline — isolates the code change from disaster-load noise): a naive per-cell estimate
# (fertility_peak ~3-6, typical CO2-capped extent ~0.02-0.06/step) suggested 0.5 would rarely bind — WRONG,
# because a per-step SINK competes against the STOCK'S NET ACCUMULATION RATE, not its accumulated peak. At
# 0.5 the new uptake drain (~0.02/step/cell) was comparable to or larger than the ~0.01/step net inflow that
# took 600 steps to build fertility_peak to 6.31 in the first place — planet-wide biomass_total crashed
# 9514->1873 (-80%) and fertility_peak crashed 6.31->0.36 (-94%), a self-reinforcing collapse (less biomass ->
# less respiration/detritus -> less decompose -> less fert -> even less photosynthesis), NOT the intended
# "only barren ground throttles" behaviour. Cut ~25x to 0.02, keeping the drain clearly subordinate to the
# natural replenishment rate so it only binds where fert is genuinely near-zero.
# SUPERSEDED, and the block above is kept because it is the evidence. That collapse was real, but it was the
# symptom of a SOURCE that produced 1.5 nutrient per unit litter — a 29:1 amplifier — not of an uptake that
# was too heavy. Cutting uptake 25x removed nutrient limitation instead of fixing the source, which is why
# fertility then ran away (measured: +2.24/step, from a first sample of exactly 0.0). With
# FERT_PER_DECOMPOSE now at the litter C:N ratio, uptake must debit at the SAME ratio or the books cannot
# close, and the two match by construction rather than by tuning. If the collapse above returns at this
# value, that is a real finding about primary production and must be reported, not tuned away again.
const FERT_UPTAKE_COST: float = 1.0 / LITTER_C_TO_N   # 0.05 — the same C:N ratio the litter releases at
# Respiration + decay: biomass + O₂ → CO₂ + detritus. Living matter slowly oxidizes everywhere it exists,
# returning carbon to the air (CO₂) and shedding litter (detritus) that the fungus-decompose record then rots
# into CO₂ + soil fertility. Proportional to biomass → self-limiting (as biomass rises, respiration rises to
# match fixation), which BOUNDS the loop, and it closes the carbon cycle entirely on the GPU.
const RESP_RATE: float = 0.01            # per-step k on x = RESP_RATE * biomass * o2
# RESP_O2_COST MUST EQUAL RESP_CO2_YIELD — one O₂ consumed per CO₂ produced, the same identity R15 obeys
# above. It was 0.5 against 0.6, minting 0.1 O₂ per unit respired. Not tunable: any pair where these differ
# creates or destroys oxygen for free.
const RESP_CO2_YIELD: float = 0.6        # CO₂ returned to air per unit biomass respired
const RESP_O2_COST: float = RESP_CO2_YIELD   # aerobic: O₂ consumed == CO₂ produced (was 0.5)
# And the carbon side: RESP_CO2_YIELD + RESP_DET_YIELD must be 1.0, or respiration creates or destroys carbon.
# It already was, by coincidence — nothing stated it, nothing tested it, and there is no carbon_total, so
# anyone tuning RESP_CO2_YIELD for behaviour would have broken conservation silently. Deriving the partner
# makes the invariant structural: change the split and it still closes.
const RESP_DET_YIELD: float = 1.0 - RESP_CO2_YIELD   # detritus (litter) shed per unit biomass respired
# RESPIRATION WAS DESTROYING NITROGEN, and nothing noticed because there was no nitrogen accounting to notice
# with. Found 2026-08-03 by the new balance gate on its first run against the shipped table. One unit of
# biomass carries 1/LITTER_C_TO_N of nitrogen. Respiration sends 0.6 of the carbon to CO₂ — which carries no
# nitrogen — and 0.4 to detritus, which carries only 0.4/20 = 0.02. The other 0.03 units simply vanished, 60%
# of the nitrogen in every unit of biomass respired, forever.
# The physics: burning the carbon off a molecule does not destroy the nitrogen in it. Plants resorb some
# nitrogen before shedding a leaf and the rest is mineralised at the litter's own ratio, so the nitrogen the
# carbon leg leaves behind returns to the soil's plant-available pool. The coefficient is DERIVED from the
# same C:N ratio as the other two, so it cannot drift out of balance: whatever nitrogen the reactant carried
# and the detritus product does not, is what the soil receives.
const RESP_FERT_YIELD: float = (1.0 - RESP_DET_YIELD) / LITTER_C_TO_N   # 0.03 — the N the CO₂ leg leaves behind
# AND THE WATER. Oxidising CH₂O to CO₂ releases one H₂O per carbon: CH₂O + O₂ -> CO₂ + H₂O. Respiration
# sends RESP_CO2_YIELD of the carbon that way and keeps the rest as litter, so the water released is exactly
# the carbon that left, and the coefficient is DERIVED rather than chosen. Until 2026-08-03 no phase of the
# carbon cycle exchanged water at all, because the balance table declared an `h2o` substance instead of
# hydrogen and oxygen atoms and so could not see the omission. This is respiration humidifying the air, which
# is a real and measurable thing a forest does.
const RESP_WATER_YIELD: float = RESP_CO2_YIELD                          # 0.6 — one H₂O per carbon oxidised
# Decomposition oxidises its carbon ALL the way (1.0 CO₂ per unit of detritus), so it releases one water per
# unit, by the same identity.
const DECOMPOSE_WATER_YIELD: float = CO2_PER_DECOMPOSE                  # 1.0 — one H₂O per carbon oxidised


## The records this domain contributes to the live table (see LAMaterialReactions3D).
static func records() -> Array:
	return [
		# R15 — Fungus DECOMPOSE: detritus + O₂ → CO₂ (self) + fertility (scratch) (fungus_sphere3d:100-118).
		# BILINEAR: x = DECOMPOSE_RATE*fungus*detritus, capped by the detritus + O₂ reactants (the aerobic cap
		# falls out of listing O₂ as a reactant, coeff O2_PER_DECOMPOSE). Fert → SCRATCH (fungus_fert reduce).
		rec(BILINEAR, DECOMPOSE_RATE, FUNGUS,
			[[DETRITUS, 1.0], [O2, O2_PER_DECOMPOSE]],
			[[CO2, CO2_PER_DECOMPOSE, TGT_SELF], [MOISTURE, DECOMPOSE_WATER_YIELD, TGT_SELF],
				[FERT, FERT_PER_DECOMPOSE, TGT_SCRATCH]],
			0, 0.0, DETRITUS),

		# R19 — PHOTOSYNTHESIS: light + CO₂ + soil water + nutrient → biomass + O₂ + transpired vapour, on the
		# GROUND. OPTIMUM_BAND: x = PHOTO_RATE * LIGHT * band(TEMP; PHOTO_T_OPT, PHOTO_T_WIDTH). LIGHT is the
		# driver because light is what drives photosynthesis; temperature is a BAND because the reaction has an
		# optimum, not a slope (see the constants block above for what this replaced and why).
		#
		# THREE Liebig reactants cap the extent — x ≤ min(co2, root_water/PHOTO_WATER_COST, fert/FERT_UPTAKE_COST)
		# — so growth is limited by whichever input is actually scarce here, which is the whole point: carbon on a
		# drawn-down leaf, water on a plateau, nutrient on barren rock. No branch decides which; the min does.
		#
		# The water leg is a CONSERVING PHASE TRANSFER, not a consumption: SOIL_ROOT is debited by
		# PHOTO_WATER_COST·x and MOISTURE is credited by exactly the same PHOTO_WATER_COST·x. That is
		# transpiration — roots lift liquid groundwater, leaves release it as vapour — and it is the identical
		# debit-one-credit-the-other shape R21/R22 use for freeze/melt, so h2o_total (water+moisture+snow+soil)
		# is untouched by it. It also couples two systems that had never met: the aquifer now feels the forest,
		# and the forest humidifies its own air.
		rec(OPTIMUM_BAND, PHOTO_RATE, LIGHT,
			[[CO2, 1.0], [SOIL_ROOT, PHOTO_WATER_DRAW], [FERT, FERT_UPTAKE_COST]],
			[[O2, PHOTO_O2_YIELD, TGT_SELF], [BIOMASS, PHOTO_BIOMASS_YIELD, TGT_SELF],
				[MOISTURE, PHOTO_WATER_COST, TGT_SELF]],
			GATE_NEAR_GROUND | GATE_NOT_STATIC, PHOTO_T_OPT, TEMP, PHOTO_T_WIDTH),

		# R20 — RESPIRATION + DECAY: biomass + O₂ → CO₂ + detritus + mineral nitrogen, everywhere biomass
		# exists (ungated). BILINEAR: x = RESP_RATE*biomass*o2; the BIOMASS reactant caps the extent (can't
		# respire more than is present) and the O₂ reactant makes it aerobic. Products: CO₂ back to the air,
		# DETRITUS litter (which the fungus-decompose R15 then rots into CO₂ + fertility), and the NITROGEN
		# the carbon leg leaves behind — see RESP_FERT_YIELD. Without that third product this record destroyed
		# 60% of the nitrogen in every unit of biomass it touched.
		rec(BILINEAR, RESP_RATE, BIOMASS, [[BIOMASS, 1.0], [O2, RESP_O2_COST]],
			[[CO2, RESP_CO2_YIELD, TGT_SELF], [DETRITUS, RESP_DET_YIELD, TGT_SELF],
				[MOISTURE, RESP_WATER_YIELD, TGT_SELF], [FERT, RESP_FERT_YIELD, TGT_SELF]],
			0, 0.0, O2),
	]
