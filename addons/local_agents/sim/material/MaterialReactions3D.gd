class_name LAMaterialReactions3D
extends RefCounted

## DATA TABLE for the generic DEFS reaction engine (Phase B3 §2). Every hand-coded "clean same-cell"
## chemical/phase reaction on the sphere path (gas sky-exchange, CO₂ vent, fungus decompose, …) is expressed
## HERE as a fixed-size Reaction RECORD instead of a bespoke kernel. `reactions_sphere3d.glsl` loops these
## records per cell; ReactionsPass uploads them once as a read-only SSBO. Adding a future reaction is adding a
## record to `records()`, NOT writing a kernel. (dissolve-don't-patch: success = bespoke kernels deleted.)
##
## The kernel binds every reactable CHANNEL at a fixed binding and a record names a channel by a SLOT enum
## (below), resolved through the kernel's read_ch/add_ch switch-ladders. Only the channels the live records
## touch need be bound (o2/co2/detritus/fungus + the fungus-fert SCRATCH here); the ladder covers the rest so
## a later record can reference them by adding the one binding.

# --- Channel slot enum (MUST match the #defines in reactions_sphere3d.glsl) --------------------------------
const TEMP: int = 0
const WATER: int = 1
const MOISTURE: int = 2
const O2: int = 3
const CO2: int = 4
const FUEL: int = 5
const FIRE: int = 6
const DETRITUS: int = 7
const FUNGUS: int = 8
const FERT: int = 9
const LAVA: int = 10
const BIOMASS: int = 11
const SNOW: int = 12                  # frozen H₂O (snowpack/ice) — the same conserved substance as WATER + MOISTURE
# MINERAL phases (rock unification): ONE conserved mineral substance, phase = state. loose SEDIMENT, airborne
# DUST, waterborne SUSP are channels; loft/settle are same-cell mass TRANSFERS between them (records below).
const SEDIMENT: int = 13
const DUST: int = 14
const SUSP: int = 15
const WINDSPEED: int = 16             # DERIVED driver only (sqrt(vel_x²+vel_z²)); never a product/reactant
# BEDROCK (rock unification Stage B): fractional bedrock mineral mass. `solid` is DERIVED (rock_fill >= 0.5). Molten
# LAVA and bedrock ROCK_FILL are the SAME mineral substance — M5 solidify + M6 melt are conserving own-cell transfers.
const ROCK_FILL: int = 17
# DERIVED slots — computed in the kernel from geometry it already has, so they cost no buffer, no upload and no
# readback (WINDSPEED was the first of these; these two are the same idea).
# LIGHT is REAL per-cell insolation, max(0, dot(cell_radial, sun_dir)) — the exact term
# heat3d_solar_sphere3d.glsl uses for the terminator, with sun_dir's MAGNITUDE carrying intensity (orbit
# distance² × atmospheric transmission). One sun drives the temperature field and the chemistry.
const LIGHT: int = 18                 # DERIVED driver only; never a product/reactant target
# SOIL_ROOT is the plant-available water of the ROOTING COLUMN: the `soil` channel summed over the permeable
# regolith cells directly beneath an open cell. It has to be a column, not the cell itself, because
# soil_sphere3d.glsl writes soil = 0 for every OPEN cell — subsurface water only ever exists in regolith rock,
# so reading `soil` at the reacting cell reads a structural zero, not a dry world. Writable (transpiration
# draws from it, proportionally to what each cell holds); see the kernel's root_soil/root_soil_draw.
const SOIL_ROOT: int = 19

# --- Rate models (extent x per cell) ---------------------------------------------------------------------
const CONST_FRAC: int = 0             # x = k * driver
const BILINEAR: int = 1               # x = k * driver * driver2
const EXCESS_OVER_THRESHOLD: int = 2  # x = max(0, driver - threshold) * k   (fires when driver is ABOVE threshold)
const RELAX_TARGET: int = 3           # x = k * (threshold - driver)  (signed; no reactant; product = driver)
# DEFICIT_BELOW_THRESHOLD is the mirror of EXCESS_OVER_THRESHOLD: it fires when the driver is BELOW the
# threshold instead of above it, so a single scalar driver (temperature) can drive a reaction in BOTH
# directions. EXCESS handles "when hot/wet/high" (melt at T>MELT_TEMP); DEFICIT handles "when cold/dry/low"
# (freeze at T<FREEZE_TEMP). Both still cap the extent by their reactants, so they stay mass-conserving
# transfers — the ONLY difference is the sign of (driver − threshold). Any future "when cold/dry/low"
# reaction (frost, dew, condensation onto a cold surface) reuses this without a new kernel.
const DEFICIT_BELOW_THRESHOLD: int = 4  # x = max(0, threshold - driver) * k  (fires when driver is BELOW threshold)
# OPTIMUM_BAND is the shape none of the four above can express: a rate that PEAKS in the middle and falls off in
# BOTH directions. All four threshold models are monotone — "more is more" (EXCESS) or "less is more" (DEFICIT) —
# so anything with a best value in the middle had no way to be written as a record. That gap is exactly why
# TEMPERATURE ended up as a linear driver on photosynthesis: a linear driver was the only way to make warmth
# matter, and it says a hotter cell always fixes more carbon, right through boiling.
#   x = k * driver * max(0, 1 - ((driver2 - threshold) / param2)^2)
# `driver` is the thing being scaled (light, a concentration, a flow); `driver2` is the variable with an
# optimum; `threshold` is the optimum; `param2` is the half-width, i.e. the distance from the optimum at which
# the rate reaches zero. Deliberately a general substrate capability, not a plant rule — enzyme kinetics, a
# creature's comfort range, a melt/refreeze band and a habitability window are all this same shape.
const OPTIMUM_BAND: int = 5

# --- Gate bitflags (0 = ungated) -------------------------------------------------------------------------
const GATE_OPEN_ABOVE: int = 1
const GATE_SURFACE: int = 2           # OUTERMOST open cell (outward nbr is space/rock). On a shell that is the
                                      # TOP OF THE ATMOSPHERE — correct for sky gas exchange, wrong for ground.
const GATE_NEAR_GROUND: int = 4       # GROUND-HUGGING open cell (INWARD nbr is rock) — where a plant, a snowpack
                                      # and the altitude lapse all actually are. Distinct set from GATE_SURFACE.
const GATE_DAYLIGHT: int = 8          # insolation above DAYLIGHT_MIN (the lit hemisphere). NO RECORD USES THIS,
                                      # and that is deliberate rather than an oversight: R19 drives on LIGHT
                                      # directly, so a dark cell already yields x = 0 with no gate needed, and a
                                      # hard daylight cutoff would replace that smooth falloff with a seam at the
                                      # terminator. The bit and its kernel branch are kept because they are a
                                      # correct, tested implementation that a future THRESHOLD record (something
                                      # that must not fire at all below an insolation floor) can use — but if you
                                      # are reaching for it to gate a rate, drive on LIGHT instead.
const GATE_DRY: int = 16              # cell water <= WET_MAX_LOFT (dry surface) — sand only lofts when not wet
const GATE_NOT_RAINING: int = 32      # global precipitation off — rain pins all dust down (loft parity)
const GATE_NOT_STATIC: int = 64       # NOT an infinite static reservoir cell. The sea/lake is seeded as water=1
                                      # `static` cells that are deliberately never simulated (MaterialField3D
                                      # ._seed_sphere_sea), so per-cell chemistry there is meaningless.

# --- Product targets -------------------------------------------------------------------------------------
const TGT_SELF: int = 0               # add into the live/back cell channel
const TGT_SCRATCH: int = 3            # add into the per-cell scratch buffer (fungus-fert pattern)

const RECORD_BYTES: int = 128         # std430 size of one Reaction (see layout in serialize())

# Constants copied VERBATIM from the kernels being dissolved (MaterialGas3D.gd / MaterialFungus3D.gd).
const SKY_EXCHANGE: float = 0.5
const O2_AMBIENT: float = 1.0
const CO2_SKY_VENT: float = 0.25
const DECOMPOSE_RATE: float = 0.05
const CO2_PER_DECOMPOSE: float = 1.0
const O2_PER_DECOMPOSE: float = 0.8
const FERT_PER_DECOMPOSE: float = 1.5

# --- Biomass / plant carbon exchange (Phase B3 §1 R19) ----------------------------------------------------
# Trace atmospheric CO₂ the sky maintains at every exposed surface cell (the ~400ppm baseline). Photosynthesis
# draws it DOWN locally, respiration/combustion push it UP — the sky exchange relaxes it back to this trace.
# Without it the carbon loop can't start: biomass, detritus, fungus and the combustion CO₂ all begin at ~0, so
# there is no carbon anywhere for a plant to fix (chicken-and-egg). This trace IS that ambient carbon source.
const CO2_AMBIENT_TRACE: float = 0.05
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
const FERT_UPTAKE_COST: float = 0.02     # fertility consumed per unit of photosynthesis extent (2nd reactant)
# Respiration + decay: biomass + O₂ → CO₂ + detritus. Living matter slowly oxidizes everywhere it exists,
# returning carbon to the air (CO₂) and shedding litter (detritus) that the fungus-decompose record then rots
# into CO₂ + soil fertility. Proportional to biomass → self-limiting (as biomass rises, respiration rises to
# match fixation), which BOUNDS the loop, and it closes the carbon cycle entirely on the GPU.
const RESP_RATE: float = 0.01            # per-step k on x = RESP_RATE * biomass * o2
const RESP_O2_COST: float = 0.5          # O₂ consumed per unit biomass respired (aerobic)
const RESP_CO2_YIELD: float = 0.6        # CO₂ returned to air per unit biomass respired
const RESP_DET_YIELD: float = 0.4        # detritus (litter) shed per unit biomass respired

# --- H₂O PHASE CHANGE (freeze / melt) — one conserved substance, phase from temperature (Phase 2c) --------
# Liquid WATER, atmospheric MOISTURE and frozen SNOW are the SAME H₂O; only the PHASE differs, and the phase
# is emergent from a cell's TEMPERATURE. Freeze/melt are pure mass-conserving TRANSFERS: debit one phase by x,
# credit the other by x (coeff 1:1), so H₂O total = water + moisture + snow is conserved by every transition.
# FREEZE_TEMP / MELT_TEMP MUST match snowice_sphere3d.glsl (the sat(T)-aware snowfall/deposition kernel that
# freezes the CONDENSED atmospheric water directly — the primary snow source). Hysteresis (FREEZE_TEMP <
# MELT_TEMP) leaves a stable band where snow neither grows nor melts → a clean, non-flickering snow line.
# TUNED to the sim's ACTUAL open-cell temperature range (~11–21 °C: this world's static terminator never drops
# the night/pole floor near 0 °C), so freezing happens in the coldest ~1–2 °C cap instead of NEVER. A literal
# 0 °C freeze can never fire here — see the task temp-range note; raise these with the real climate range.
const FREEZE_TEMP: float = 12.5          # WATER (and, in the kernel, condensed MOISTURE) at T below this freezes → SNOW
const MELT_TEMP: float = 14.0            # SNOW at T above this melts → liquid WATER
const FREEZE_RATE: float = 0.05          # per-step k on the below-threshold liquid-freeze extent
const MELT_RATE: float = 0.05            # per-step k on the above-threshold snow-melt extent

# --- MINERAL phase transfers (rock unification Stage A) — same-cell, conserving, own-cell writes only -------
# LOFT (M4, replaces dust_loft_sphere3d.glsl): wind over LOFT_WIND scours dry loose SEDIMENT into the SAME
# cell's airborne DUST (the box/sphere loft kernel scattered into the cell ABOVE — a cross-cell write that
# forbade a DEFS record; re-aiming to own-cell makes it a clean record and dust_transport lofts it up next
# step, design-blessed as near-identical). Constants copied from dust_loft_sphere3d.glsl. The reactant cap on
# SEDIMENT enforces "can't loft more than present"; the LOFT_MAX per-step cap is dropped (perf-over-parity —
# it only bit at hspeed>~22, and sediment-capped extent stays bounded regardless).
const LOFT_WIND: float = 6.0             # horizontal wind speed a dry surface must exceed to loft sand
const LOFT_RATE: float = 0.003           # sediment lofted per step per unit wind OVER the threshold
# SETTLE (M3, susp→sediment): turbid water drops its load when calm. CONST_FRAC.
# (Corrected 2026-07-29: this said "susp is a DEAD phase today (no erosion source on the sphere populates it),
# so this record is a NO-OP". It is LIVE. ErosionPickupPass is registered at MaterialSphereGPU3D.gd:51,
# immediately before ReactionsPass so this record reads the freshly-scoured susp in the same step. The same
# false claim, that the erosion pickup kernel did not exist, sat in HANDOFF.md for weeks and sent work at a
# problem that was already solved.)
const SUSP_SETTLE_RATE: float = 0.05     # per-step fraction of suspended sediment that settles out when calm

# --- WEATHERING (Stage D, rock_fill→sediment): frost/thermal breakdown of exposed bedrock into the transportable
# loose pool. Runs in OPEN surface cells (GATE_SURFACE), where rock_fill is the partial boundary bedrock. Colder
# exposed rock breaks faster (freeze–thaw shattering), so it is DEFICIT_BELOW_THRESHOLD on TEMP: x = max(0,
# WEATHER_TEMP - temp) * WEATHER_RATE, capped by the ROCK_FILL present → a conserving rock_fill→sediment transfer.
# This gives slopes a water-INDEPENDENT talus source (weathered rock → slump → downhill) that composes with the
# river-scour pickup. WEATHER_TEMP sits at the top of this world's open-cell range (~11–21 °C) so all exposed rock
# weathers, fastest at the cold poles/night — the emergent latitudinal weathering gradient, no per-case code.
const WEATHER_TEMP: float = 20.0
const WEATHER_RATE: float = 0.004        # per-step k on x = max(0, WEATHER_TEMP - temp) * k (capped by rock_fill)
# --- LITHIFICATION (Stage D, sediment→rock_fill): deep/old sediment compacts back into bedrock. EXCESS_OVER_
# THRESHOLD on SEDIMENT: x = max(0, sediment - LITH_DEPTH) * LITH_RATE, capped by the SEDIMENT present → a
# conserving sediment→rock_fill transfer. Only the EXCESS above a deep threshold lithifies, so thin dustings stay
# loose and only genuine basins/deltas turn to stone — rock_fill crossing 0.5 there makes MineralStamp3D grow NEW
# land (a delta prograding into rock, a sediment plain becoming a coastal shelf). Closes the cycle: rock→susp→
# sediment→rock, so mineral_total is conserved end-to-end and the planet gains a real depositional history.
const LITH_DEPTH: float = 0.5            # sediment mass above which the EXCESS compacts to bedrock (deep deposits only)
const LITH_RATE: float = 0.02            # per-step k on x = max(0, sediment - LITH_DEPTH) * k (capped by sediment)

# --- BEDROCK phase transfers (rock unification Stage B) — molten LAVA <-> fractional bedrock ROCK_FILL ------------
# ONE conserved mineral: solidify and melt are own-cell, mass-conserving transfers between the molten and bedrock
# phases (reactant-capped debit + equal credit → conserving by construction). `solid` is DERIVED (rock_fill>=0.5),
# so as lava solidifies the accreted rock_fill crosses 0.5 and the cell becomes bedrock (terrain grows); as rock
# melts it crosses back and the cell opens. The 0.5 crossing is what Stage C will stamp into the SDF mesh.
# M5 SOLIDIFY (molten -> bedrock): lava colder than SOLIDIFY_TEMP freezes to rock. REPLACES the direct
# `solid=1; lava=0` write dissolved out of lava_phase_sphere3d.glsl (which fabricated an invisible GPU-only solid
# cell and LOST the lava mass — non-conserving); now it is a conserving lava->rock_fill transfer. lava_phase keeps
# only its SUSTAIN leg and no longer re-heats a sub-solidus cell, so this record sees the genuine post-thermal cold.
const SOLIDIFY_TEMP: float = 800.0       # lava below this (°C) has cooled through the solidus → freezes to bedrock
const SOLIDIFY_RATE: float = 0.02        # per-step k on x = max(0, SOLIDIFY_TEMP - temp) * k (capped by lava)
# M6 MELT (bedrock -> molten): rock hotter than ROCK_MELT_TEMP melts to lava. Reactions run in OPEN cells only
# (the engine skips solid cells for race-freedom), so this record melts the BOUNDARY rock — a hot open cell that
# still carries partial rock_fill (0 < rock_fill < 0.5), e.g. at a lava/bedrock interface. FULL bedrock melt of a
# deep magma-core cell (which is solid, hence skipped) stays a special case: it is driven instead by the real
# add_lava injection (converting bedrock->lava at the vent) and, later, the Stage-C hot-bore. Conserving either way.
const ROCK_MELT_TEMP: float = 1200.0     # open-cell rock hotter than this (°C, above the lava emplace temp) melts
const ROCK_MELT_RATE: float = 0.02       # per-step k on x = max(0, temp - ROCK_MELT_TEMP) * k (capped by rock_fill)


## Author one record as a Dictionary (unspecified fields default to the ungated/no-op values). Reactant and
## product entries are Arrays of [slot, coeff] (products carry an optional 3rd element = target, default SELF).
static func _rec(rate_model: int, rate_k: float, driver_slot: int, reactants: Array, products: Array,
		gate_mask: int = 0, threshold: float = 0.0, driver2_slot: int = -1, param2: float = 0.0) -> Dictionary:
	return {
		"rate_model": rate_model, "rate_k": rate_k, "threshold": threshold, "gate_mask": gate_mask,
		"driver_slot": driver_slot, "driver2_slot": driver2_slot, "param2": param2,
		"reactants": reactants, "products": products,
	}


## The live reaction table (Phase B3 §1 "clean same-cell" set that folds now). Order is irrelevant — every
## record writes only its own cell, so the per-cell loop is order-independent.
static func records() -> Array:
	return [
		# R11 — Gas O₂ SKY-REFILL: relax O₂ toward ambient at sky-exposed surface cells (gas_sky_sphere3d:55).
		# RELAX_TARGET: x = SKY_EXCHANGE*(O2_AMBIENT - o2); product = O2 itself, no reactant.
		_rec(RELAX_TARGET, SKY_EXCHANGE, O2, [], [[O2, 1.0, TGT_SELF]], GATE_SURFACE, O2_AMBIENT),

		# R12 — Gas CO₂ SKY-EXCHANGE: relax CO₂ toward a small ambient TRACE at sky-exposed surface cells
		# (mirrors the O₂ sky refill R11 exactly). RELAX_TARGET: x = CO2_SKY_VENT*(CO2_AMBIENT_TRACE - co2);
		# product = CO₂ itself, no reactant. Excess combustion CO₂ still vents DOWN toward the trace (x<0), and
		# clean surface air refills UP to it (x>0) — the trace is the atmosphere's baseline carbon that seeds
		# the whole loop (photosynthesis draws it below the trace locally; see R19).
		_rec(RELAX_TARGET, CO2_SKY_VENT, CO2, [], [[CO2, 1.0, TGT_SELF]], GATE_SURFACE, CO2_AMBIENT_TRACE),

		# R15 — Fungus DECOMPOSE: detritus + O₂ → CO₂ (self) + fertility (scratch) (fungus_sphere3d:100-118).
		# BILINEAR: x = DECOMPOSE_RATE*fungus*detritus, capped by the detritus + O₂ reactants (the aerobic cap
		# falls out of listing O₂ as a reactant, coeff O2_PER_DECOMPOSE). Fert → SCRATCH (fungus_fert reduce).
		_rec(BILINEAR, DECOMPOSE_RATE, FUNGUS,
			[[DETRITUS, 1.0], [O2, O2_PER_DECOMPOSE]],
			[[CO2, CO2_PER_DECOMPOSE, TGT_SELF], [FERT, FERT_PER_DECOMPOSE, TGT_SCRATCH]],
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
		_rec(OPTIMUM_BAND, PHOTO_RATE, LIGHT,
			[[CO2, 1.0], [SOIL_ROOT, PHOTO_WATER_COST], [FERT, FERT_UPTAKE_COST]],
			[[O2, PHOTO_O2_YIELD, TGT_SELF], [BIOMASS, PHOTO_BIOMASS_YIELD, TGT_SELF],
				[MOISTURE, PHOTO_WATER_COST, TGT_SELF]],
			GATE_NEAR_GROUND | GATE_NOT_STATIC, PHOTO_T_OPT, TEMP, PHOTO_T_WIDTH),

		# R20 — RESPIRATION + DECAY: biomass + O₂ → CO₂ + detritus, everywhere biomass exists (ungated).
		# BILINEAR: x = RESP_RATE*biomass*o2; BIOMASS reactant caps the extent (can't respire more than present),
		# O₂ reactant makes it aerobic. Products: CO₂ back to air + DETRITUS litter (which the fungus-decompose
		# R15 then rots into CO₂ + fertility) → the full carbon loop closes on the GPU, no CPU carcass bridge.
		_rec(BILINEAR, RESP_RATE, BIOMASS, [[BIOMASS, 1.0], [O2, RESP_O2_COST]],
			[[CO2, RESP_CO2_YIELD, TGT_SELF], [DETRITUS, RESP_DET_YIELD, TGT_SELF]],
			0, 0.0, O2),

		# R21 — FREEZE (liquid → snow): standing/melt WATER at a cell colder than FREEZE_TEMP crystallizes to
		# SNOW. DEFICIT_BELOW_THRESHOLD: x = max(0, FREEZE_TEMP - temp) * FREEZE_RATE, capped by the WATER present
		# → a pure conserving transfer (water -= x; snow += x). The PRIMARY snowfall path (freezing the CONDENSED
		# atmospheric water at cold ground, which needs sat(T)) is the snowice deposition kernel; this record is
		# the liquid leg — it refreezes meltwater/puddles/rivers so the H₂O phase tracks temperature everywhere,
		# not only in the air. It is also the exemplar of the new below-threshold rate model.
		_rec(DEFICIT_BELOW_THRESHOLD, FREEZE_RATE, TEMP, [[WATER, 1.0]], [[SNOW, 1.0, TGT_SELF]], 0, FREEZE_TEMP),

		# R22 — MELT (snow → water): SNOW at a cell warmer than MELT_TEMP thaws to liquid WATER (meltwater the
		# water CA then routes downhill on the next step). EXCESS_OVER_THRESHOLD: x = max(0, temp - MELT_TEMP) *
		# MELT_RATE, capped by the SNOW present → conserving transfer (snow -= x; water += x). REPLACES the melt
		# branch of snowice_sphere3d.glsl (which is now deposition-only).
		_rec(EXCESS_OVER_THRESHOLD, MELT_RATE, TEMP, [[SNOW, 1.0]], [[WATER, 1.0, TGT_SELF]], 0, MELT_TEMP),

		# M4 — DUST LOFT (loose → airborne): wind over LOFT_WIND scours dry loose SEDIMENT into the OWN cell's
		# airborne DUST. EXCESS_OVER_THRESHOLD on WINDSPEED (sqrt(vel_x²+vel_z²), the derived driver), gated
		# GATE_DRY (water<=WET_MAX_LOFT) + GATE_NOT_RAINING. Reactant cap on SEDIMENT. REPLACES + DELETES
		# dust_loft_sphere3d.glsl (the cross-cell scatter into the cell above → re-aimed own-cell; transport
		# lofts it up next step). A conserving sediment→dust transfer of the ONE mineral substance.
		_rec(EXCESS_OVER_THRESHOLD, LOFT_RATE, WINDSPEED, [[SEDIMENT, 1.0]], [[DUST, 1.0, TGT_SELF]],
			GATE_DRY | GATE_NOT_RAINING, LOFT_WIND),

		# M3 — SUSP SETTLE (suspended → loose): calm turbid water drops its load. CONST_FRAC on SUSP →
		# SEDIMENT (own-cell, conserving). This record is LIVE: ErosionPickupPass (MaterialSphereGPU3D.gd:51)
		# scours rock_fill into susp immediately before ReactionsPass, so the settle reads the same step's
		# suspension and closes rock→susp→sediment→rock.
		# (Corrected 2026-07-29: said "susp is a DEAD phase until Stage D erosion populates it, so this is an
		# inert forward-looking record today". Stage D landed; the comment did not.)
		_rec(CONST_FRAC, SUSP_SETTLE_RATE, SUSP, [[SUSP, 1.0]], [[SEDIMENT, 1.0, TGT_SELF]], 0),

		# M5 — LAVA SOLIDIFY (molten → bedrock): lava colder than SOLIDIFY_TEMP freezes to rock. Runs in the open
		# cells lava occupies. DEFICIT_BELOW_THRESHOLD on the post-thermal TEMP: x = max(0, SOLIDIFY_TEMP - temp) *
		# SOLIDIFY_RATE, capped by the LAVA present → a conserving lava→rock_fill transfer. DISSOLVES the direct
		# `solid=1; lava=0` write formerly in lava_phase_sphere3d.glsl (which lost the lava mass); the accreted
		# rock_fill crossing 0.5 is what turns the cell to derived bedrock (and, in Stage C, stamps the SDF).
		_rec(DEFICIT_BELOW_THRESHOLD, SOLIDIFY_RATE, TEMP, [[LAVA, 1.0]], [[ROCK_FILL, 1.0, TGT_SELF]],
			0, SOLIDIFY_TEMP),

		# M6 — ROCK MELT (bedrock → molten): open-cell rock hotter than ROCK_MELT_TEMP melts to lava.
		# EXCESS_OVER_THRESHOLD on TEMP: x = max(0, temp - ROCK_MELT_TEMP) * ROCK_MELT_RATE, capped by ROCK_FILL →
		# conserving rock_fill→lava transfer. Only fires in OPEN cells (engine skips solid), so it melts partial
		# boundary rock; deep full-bedrock melt is driven by add_lava / the Stage-C bore (see the const note).
		_rec(EXCESS_OVER_THRESHOLD, ROCK_MELT_RATE, TEMP, [[ROCK_FILL, 1.0]], [[LAVA, 1.0, TGT_SELF]],
			0, ROCK_MELT_TEMP),

		# D1 — WEATHERING (bedrock → loose): exposed surface rock_fill breaks down into transportable SEDIMENT,
		# fastest where cold (freeze–thaw). DEFICIT_BELOW_THRESHOLD on TEMP: x = max(0, WEATHER_TEMP - temp) *
		# WEATHER_RATE, capped by ROCK_FILL → conserving rock_fill→sediment transfer. GATE_SURFACE = sky-exposed
		# bedrock only. Feeds the loose pool the slump CA then spreads downhill — a water-independent talus source.
		_rec(DEFICIT_BELOW_THRESHOLD, WEATHER_RATE, TEMP, [[ROCK_FILL, 1.0]], [[SEDIMENT, 1.0, TGT_SELF]],
			GATE_SURFACE, WEATHER_TEMP),

		# D2 — LITHIFICATION (loose → bedrock): deep/old SEDIMENT compacts back into ROCK_FILL under its own
		# accumulated weight. EXCESS_OVER_THRESHOLD on SEDIMENT: x = max(0, sediment - LITH_DEPTH) * LITH_RATE,
		# capped by SEDIMENT → conserving sediment→rock_fill transfer. Only deep deposits (deltas/basins) turn to
		# stone; the accreted rock_fill crossing 0.5 makes MineralStamp3D grow NEW land. Closes rock→susp→
		# sediment→rock, so mineral_total conserves and deposition builds a real geological history.
		_rec(EXCESS_OVER_THRESHOLD, LITH_RATE, SEDIMENT, [[SEDIMENT, 1.0]], [[ROCK_FILL, 1.0, TGT_SELF]],
			0, LITH_DEPTH),
	]


## Serialize the records into a std430 SSBO byte buffer. Layout per Reaction (128 bytes, 16-aligned):
##   0 rate_model(i) 4 rate_k(f) 8 threshold(f) 12 gate_mask(i) | 16 driver_slot(i) 20 driver2_slot(i)
##   24 cap_slot(i) 28 cap_coeff(f) | 32 n_react(i) 36 n_prod(i) 40 param2(f) 44 pad |
##   48 react_slot[4](i) | 64 react_coeff[4](f) | 80 prod_slot[4](i) | 96 prod_coeff[4](f) | 112 prod_target[4](i)
## Offset 40 was one of two spare pads; OPTIMUM_BAND claims it as `param2` (its band half-width), so the record
## stays exactly 128 bytes and every existing offset is untouched. One pad remains at 44 for the next model.
static func serialize(recs: Array) -> PackedByteArray:
	var buf: PackedByteArray = PackedByteArray()
	buf.resize(recs.size() * RECORD_BYTES)
	for r in range(recs.size()):
		var rec: Dictionary = recs[r]
		var base: int = r * RECORD_BYTES
		var reactants: Array = rec.get("reactants", [])
		var products: Array = rec.get("products", [])
		buf.encode_s32(base + 0, int(rec.get("rate_model", CONST_FRAC)))
		buf.encode_float(base + 4, float(rec.get("rate_k", 0.0)))
		buf.encode_float(base + 8, float(rec.get("threshold", 0.0)))
		buf.encode_s32(base + 12, int(rec.get("gate_mask", 0)))
		buf.encode_s32(base + 16, int(rec.get("driver_slot", 0)))
		buf.encode_s32(base + 20, int(rec.get("driver2_slot", -1)))
		buf.encode_s32(base + 24, int(rec.get("cap_slot", -1)))
		buf.encode_float(base + 28, float(rec.get("cap_coeff", 0.0)))
		buf.encode_s32(base + 32, reactants.size())
		buf.encode_s32(base + 36, products.size())
		buf.encode_float(base + 40, float(rec.get("param2", 0.0)))
		buf.encode_s32(base + 44, 0)
		for k in range(4):
			var rs: int = int(reactants[k][0]) if k < reactants.size() else -1
			var rc: float = float(reactants[k][1]) if k < reactants.size() else 0.0
			buf.encode_s32(base + 48 + k * 4, rs)
			buf.encode_float(base + 64 + k * 4, rc)
		for k in range(4):
			var ps: int = -1
			var pc: float = 0.0
			var pt: int = TGT_SELF
			if k < products.size():
				ps = int(products[k][0])
				pc = float(products[k][1])
				pt = int(products[k][2]) if products[k].size() > 2 else TGT_SELF
			buf.encode_s32(base + 80 + k * 4, ps)
			buf.encode_float(base + 96 + k * 4, pc)
			buf.encode_s32(base + 112 + k * 4, pt)
	return buf
