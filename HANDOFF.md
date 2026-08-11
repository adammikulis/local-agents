# TODO / Roadmap — Local Agents (voxel-planet caretaker sim)

**This file is the map of what is LEFT. It is not a history.** A finished item is deleted the moment it is
committed; git is the record of what was done. When an entry is FALSE, fix it in place and say what it
claimed, so nobody re-derives the same wrong conclusion.

**KEEP THIS FILE AND `CLAUDE.md` CORRECT — THAT IS THE JOB, NOT A PERMISSION TO ASK FOR.** *(Changed
2026-08-08 by the maintainer: it used to read "this file and `CLAUDE.md` may not be changed without his
approval", which flatly contradicted `CLAUDE.md`'s own standing order to update this file unprompted at
every landing, and worse, turned every false claim into something to REPORT rather than repair. He cannot
police every line of two 800-line documents; an agent that finds a wrong entry and asks permission has
handed the work back. Fix it, say what it claimed, and move on.)*

**Distrust the FRAMINGS here, not just the facts.** A previous version led with "every subsystem with a
conservation ledger conserves; every subsystem without one mints", and a full session of work was planned
against that sentence. Every factual claim in it was checkable. The framing was the problem — "minting" made
**creating matter from nothing** sound like an accounting discrepancy, so the plan it produced was to measure
the discrepancy better and to fix a shortage by adding another source. If a phrase here lets you think about a
physics violation without picturing the physics, replace the phrase.

---

## ▶ START HERE

**THE GOAL IS THE ACTUAL EARTH, to a chosen granularity.** Not a planet tuned to be pleasant. Every constant
is a measured property of real matter, every initial condition describes what the planet was made of, and
**temperature, atmosphere, ocean and habitability are OUTPUTS, never inputs.** Almost every defect found on
2026-08-03 was a violation of that one sentence.

**0.4 is the PLANET. Creature work is 0.5** — not lower priority, premature. But **a defect you find is
FIXED, wherever it lives.** Nothing here licenses recording a broken thing instead of repairing it.

**Work in manageable chunks. Do not speedrun toward life.** The staged plan below exists because mixing a
correctness fix with a behavioural rewrite makes both unmeasurable.

`sorting.py` at repo root is the maintainer's, untracked — leave it.

### State (2026-08-11) — `feature/physics-substrate`, 56 commits past `54f6e58`

**READ `CLAUDE.md`'s FIRST TWO RULES BEFORE TOUCHING ANYTHING.** They are new, they are at the very top, and
they were written because an agent spent a session violating both: **delete what is wrong, never preserve it
behind a flag**, and **any departure from real physics needs the maintainer's explicit permission, asked
first**. The second is gate-backed by `scripts/check_model_parameters.sh` where it can be.

## `--run-frames` COUNTS RENDER FRAMES, SO EVERY HORIZON IN THIS FILE IS MACHINE-DEPENDENT

**Found 2026-08-11 by the framerate track, not fixed, and it undermines every number quoted anywhere.**
`VoxelWorld.tscn` never sets `count_physics_frames`, so `LocalAgentDemoHarness` defaults to counting
`_process` frames (`runtime/DemoHarness.gd:98`). `--run-frames=N` therefore ends the run after N RENDER
frames — a machine-dependent amount of simulation. `CLAUDE.md`'s own inspector rule says the opposite in so
many words: "Measure a simulation on the physics clock."

The fix is one line, `count_physics_frames = true` in the `.tscn`, and it is NOT a one-line change: it
redefines every `--bench` frame number, and `_input.update(_frame, spawned)` (`VoxelWorld.gd:664` ->
`VoxelInputController.gd:528`) **seeds meteors, volcanoes and hot-spring heat at absolute frame numbers**,
so that counter has to move to `_physics_process` in the same commit or the disasters desync from the run
length. One owner, both halves.

## THE ORDER OF WORK CHANGED ON 2026-08-11. READ THIS BEFORE PICKING ANYTHING UP.

**The plan was ordered by subsystem. It is ordered by what makes measurement possible now.** A whole day
was spent measuring a substrate whose numbers could not mean anything yet, because the things that make a
number trustworthy were sitting in the queue behind the things being measured.

**THE MEASUREMENT FLOOR — nothing below it can be evaluated until these are zero:**
1. **DETERMINISM.** Two runs at one seed differ by 0.41%. No A/B, no drift figure and no attribution means
   anything until this is 0.
2. **OBSERVER INDEPENDENCE.** `scripts/check_observer_independence.sh` reads **87.13% on `energy_stock`**
   and 2-6% on every element total. Every figure taken before this was measured through it.
3. **THE HORIZON.** `--run-frames` counts RENDER frames, so how much simulation a run contains depends on
   the machine.

**THEN, live physics violations** — matter from nothing is addressed or exempted, and there is no third
outcome: the **mineral** source (crust grows 5x, no sampled pass makes it) and **volume-weighted
transport** (every advection between differently-sized cells creates or destroys matter).

**THEN the energy channel**, and it MUST come after volume weighting or every kernel written for it
re-encodes the flat-cell assumption.

**DEMOTED, and this is the reordering that matters most: the HADEAN SEED (Stage 4) waits.** It was the
headline goal. Seeding a molten body onto a substrate that cannot conserve matter or reproduce a run is
fitting behaviour to a fiction — the scope rule's own warning, one level up. Stage 1's `cell_size`->ctx and
per-world clock serve parallel universes, which is blocked anyway; Stage 3's rotation and air composition
are not measurement-blocking.

**BLOCKED OUTRIGHT, not merely later: PARALLEL UNIVERSES.** A difference between two seed vectors is
unreadable when one vector disagrees with itself by 0.41%. That is a dependency, not a preference.

## THE ENERGY GAUGE IS OBSERVER-DEPENDENT BY CONSTRUCTION — the top item on the floor

`energy_stock` is `Σ rc·T·V`, and `rc` comes from `LAHeatCapacity.field()` over a dictionary of channel
MIRRORS. Demand-gated channels are only refreshed when something called `request_channel`, so with fewer
consumers alive fewer mirrors are fresh, an absent leg contributes ZERO capacity, and the stock moves. The
ledger's own `energy_stock_live` map exists to report which legs arrived, and it already publishes
`porosity: false` on a full run.

**Deciding it costs one comparison:** diff `energy_stock_live` between the two arms of
`check_observer_independence.sh`. If more legs read false under `--bare`, that is the mechanism.
**The fix is the one CLAUDE.md already states:** a consumer requests its own channels (as `avg_atmos_dust`
does), or reads them from `request_probe`/`take_probe`, which is the pure-instrument path that does not
change residency. A gauge may not decide which mirrors are fresh.

## THE SIM IS NOT REPRODUCIBLE, AND LOOKING AT IT STILL CHANGES IT — measured 2026-08-11

`scripts/agent_harness.sh score` now computes all ten rubric criteria, and two of the four new ones found
things nothing was watching:

- **DETERMINISM: two runs at the SAME seed and the same length differ by 0.41%** in a conserved total.
  Every A/B this project has ever quoted was taken against a substrate that does not repeat itself, and
  **parallel universes cannot compare seed vectors until it does** — a difference between two vectors is
  unreadable when one vector disagrees with itself. This is the first thing to fix in Stage 1; the
  per-universe RNG work landed today is a prerequisite, not the whole of it.
- **OBSERVER INDEPENDENCE: `--bare` still differs by 3.83%.** The whole-mirror `set_field` upload was ONE
  mechanism and closing it did not close the property. The standing rule holds: no conservation number may
  be quoted from a `--bare` run.
- **MOMENTUM: there is no ledger at all.** Matter has ledgers, energy has one, and the third conserved
  quantity of mechanics is unmeasured. Wind and flow carry it, pressure gradients and gravity create it,
  drag destroys it, nothing sums it.

**DO NOT HAND-ENTER A RUBRIC ROW.** All ten criteria are computed — 1, 2 and 5 from `SIM_REPORT`, 3 and 4
from `docs/MODEL_PARAMETERS.md`, 6 from probe coverage, 7 from the ledger's absence, 8 from a count of
named-phenomenon actor scripts, 9 and 10 from comparison runs the script takes itself.

## THE GROUND UNDER EVERYTHING ELSE — READ THIS BEFORE PLANNING ANY CONSERVATION WORK

**Cells are not the same size, and until 2026-08-10 nothing in the substrate knew it.** A column near the
centre of a cube face subtends far more solid angle than one at a corner (~4.9x), and a cell high in the
shell is wider than one at the floor because lateral spacing is an arc growing with radius (~1.8x). Measured
by `scripts/check_sphere_grid.sh`: **largest cell / smallest cell = 6.30x (res 8), 7.91x (res 16), 8.76x
(res 32)** — and the ratio grows as the grid is refined.

So, in plain language: **a "total" in this project is a count-weighted sum, not an amount of anything**, and
**a transport that moves a fraction of one cell into a differently sized cell debits more matter than it
delivers**. That is matter created and destroyed on every advection step, in every channel, by construction.

`LASphereGrid` now carries `solid_angle`, `cell_volume`, `face_area_inward` / `face_area_outward`, derived
exactly (the gnomonic solid-angle closed form; summed cell volumes match the analytic shell to 0.002-0.01
ppm). **NO KERNEL AND NO LEDGER CONSUMES THEM YET.** That conversion is the next structural job and it must
land BEFORE energy becomes a channel, or every new kernel re-encodes the flat-cell assumption.

**A PREDICTION, so this is falsifiable rather than a caveat.** If the flat sum is a large part of the
measured drift, then the substances that "conserve" should be the ones concentrated in a NARROW BAND OF
RADII, and the ones that "drift" should be the ones spread across the shell — because the error is
identically zero on a uniform field and 13.2% on a field occupying the outer half. The sealed debts are:

| substance | recorded debt | where it lives |
|---|---|---|
| `mineral_total` | 0.00002 | bedrock — one narrow radial band |
| `nitrogen_all` | 0.0062 | soil + air |
| `oxidant_all` | 0.045 | air |
| `o2_total` | 0.055 | air, outer shells |
| `h2o_closed_total` | 0.20 | ocean, snow, soil AND moisture aloft — the whole radial range |
| `element_C_total` | 0.28 | air + biomass + carbonate — the whole range |

That ordering is exactly what a volume-weighting bug predicts, and it is four orders of magnitude from
end to end. It does NOT prove the drifts are all artefact — real leaks certainly exist — but it does mean
**no drift figure can be interpreted until the totals are volume-weighted**, and when they are, mineral
should barely move while carbon and h2o should move a lot. If they do not move that way, the hypothesis
is wrong and the leaks are real; either answer is worth having, and it costs one run to get.

**Consequence for this file: every drift percentage below predates this and has it baked in** — including
the figures `PHYSICS_RUBRIC.md` criterion 1 is scored on, and the observation that mineral is the one
substance that conserves (minerals sit in a narrow band of radii, so they suffer least from it).

**Also fixed 2026-08-10, deleting their entries rather than ticking them:** snowfall's destroyed latent heat
(deposition is a record now, was a kernel that could not charge heat because its Temp binding was readonly);
`magma_buoy`'s enthalpy mix weighting the destination by a constant instead of its retained mass, which
created heat on every buoyant transfer; `sea_level`, declared and never assigned, so the aquifer's grain-size
gradient collapsed to one permeability planet-wide and cloud base sat inside the mantle; and the five-plane
`scent` channel, two of whose planes had no emitter anywhere in the tree.

## THE CONSERVATION GATE WAS BLIND, AND THE VIOLATION IT NOW REPORTS IS PROBABLY THE INSTRUMENT

**Measured 2026-08-10, first windowed runs since the substrate work.**

`LAMaterialFieldConservation3D.check()` guarded its violation test with `if elapsed < REFERENCE_STEPS or
_audited: continue`. `_audited` latches at the first sample past the 600-step horizon, so **the gate
evaluated exactly once and then went blind for the rest of the run.** A 600-frame run at `--fast=8`
reaches field_step 37712 — sixty times the horizon — and reported `conservation_failed: false` while the
current sample read `element_C_total` 11.09 against a debt of 0.28. The `or _audited` was redundant:
`not _violations.has(key)` on the next line already gives one report per substance. It is deleted.

**With the gate seeing, h2o breaches on BOTH trees, so it predates this session:**

| tree | breach | baseline -> now |
|---|---|---|
| `54f6e58` (pre-session, gate fix only) | +69.8% at step 1244 | 3711.52 -> 6303.99 |
| this branch | +157.5% at step 908 | 4049.55 -> 10427.83 |

**BUT THE PER-PASS PROBE FLATLY DISAGREES, and it is the better instrument.** `LA_H2O_BUDGET=1` reads
the device at the drain, per pass, and says `residual_all` is ~0.0001 EVERY step — every pass conserves
water to one part in ten thousand — while the total FALLS: 5335 -> 4989 -> 4246 -> 4104 -> 4030 -> 3978.
Water drains from `water` (3458 -> 1447) into `soil` (1876 -> 2530); `plate_advect` and `solid_derive`
cancel to the digit (-1.9999 / +1.9999).

Both cannot be true. The difference is the SUMMING RULE: the probe sums the device, while
`h2o_closed_total` adds four legs through four different masks — `soil_total` mask-free,
`water_total`/`snow_total` open-cells-only, `moisture_total` on `solid != 0` (moisture INSIDE ROCK).
`solid_cells` moves all run (31978 -> 31636), so every cell crossing the solidity threshold shifts mass
between differently-masked legs and the total moves with no water going anywhere.

**MEASURED AFTER THE MERGE — the mask helped and did not close it, and EVERY substance breaches:**

| substance | drift | allowed | at step |
|---|---|---|---|
| `h2o_closed_total` | +57.3% (was +157% pre-mask-fix) | 0.20 | 723 |
| `element_C_total` | +163% | 0.28 | 6978 |
| `oxidant_all` | +15.6% | 0.045 | 6978 |
| `nitrogen_all` | +4.3% | 0.0062 | 6978 |
| `mineral_total` | **+475%** | 0.00002 | 6978 |
| `o2_total` | +22.6% | 0.055 | 7770 |

**THE RADIAL-SPREAD PREDICTION IS REFUTED.** It said mineral would barely move once volume-weighted,
because it sits in the narrowest band of radii. Volume-weighted, mineral moved MOST of all — 475%
against a 0.002% debt. Whatever orders those debts, it is not only geometry. Do not reason from that
hypothesis again.

**CORRECTED — THE TABLE ABOVE IS AN ARTIFACT, AND FIVE OF THOSE SIX ARE FINE.** The debts were reshaped
to per-STEP rates the same day, and re-measured:

| substance | rate/step | allowed/step | verdict |
|---|---|---|---|
| `element_C_total` | 2.23e-4 | 4.67e-4 | under |
| `h2o_closed_total` | 8.90e-5 | 3.33e-4 | under, and SETTLING (trend 0.186) |
| `o2_total` | 8.02e-5 | 9.17e-5 | under |
| `oxidant_all` | 1.61e-5 | 7.50e-5 | under |
| `nitrogen_all` | 4.62e-6 | 1.03e-5 | under |
| `mineral_total` | 5.05e-4 | 3.33e-8 | **15,000x over** |

h2o breaches early (4.78e-4 at step 652) and its rate then falls to 18.6% of that — a startup transient,
not a leak. **MINERAL is the one real outstanding question**, and not because it leaks worst: its rate is
the same ORDER as carbon's. What singles it out is a ceiling four orders of magnitude tighter than
everything else's, set when it measured -0.000006. Either it regressed enormously, or volume-weighting
`mineral_total` changed what it measures — rock_fill growing in the LARGE outer cells now counts far more
than the flat sum allowed. Settle it with the per-pass mineral probe (LA_MINERAL_BUDGET), which attributes
by pass.

**MINERAL, ATTRIBUTED (LA_MINERAL_BUDGET, field_step 8519-8570). The rock is real and the passes did not
make it.**

- `mineral_total` (mask-free, volume-weighted) grows from 1.64e15 at the seal to 7.87e15 — about 5x.
- **`solid_cells` grows 31978 -> 53935.** The crust really is getting bigger; this is not a gauge reading
  the same rock differently.
- **But every sampled pass sums to a small net LOSS**, about -5.8e10 per step: `plate_advect` -6.9e10,
  `water_slump_lava` +1.0e10 to +2.0e10, `erosion_pickup`, `fire_dust`, `reactions` and `solid_derive` all
  four to six orders smaller. Over 8500 steps that is roughly -5e14, against an observed +6.2e15.
- `solid_derive` is ~0 in the mask-free view and swings +/-1e14 in the OPEN-cell view, which is just cells
  crossing the solidity threshold — mass moving between open and buried, not appearing.

**So the source is NOT in the sampled pass loop.** Two candidates, and they are cheap to separate:
1. CPU-side injection — `LAMineralStamp3D`, meteor and volcano stamps — which reaches the device through
   the inject queue and is booked in `mineral_inject_minted` rather than in a pass leg.
2. Bursty events BETWEEN samples: the probe samples 2 of every 50 steps (`SAMPLE_EVERY`), so an impact or
   an eruption landing in the other 48 is invisible to it.

Next: read `mineral_inject_minted` and `mineral_src_total` over a long run (they are already in
SIM_REPORT), and if those are ~0, drop `SAMPLE_EVERY` to 1 for one short run so nothing can hide between
pairs.

**WHY THE ORIGINAL TABLE WAS WRONG, kept because it is the lesson:** They
are ceilings on a RELATIVE TOTAL, calibrated at the 600-step reference horizon, and the gate now checks
every sample past it — these breaches are at step 6978-7770, thirteen times further. **A substance with
any steady drift breaches a fixed relative ceiling eventually, so run length alone decides the verdict.**
That is a measurement whose answer depends on how long you looked, which is the same class of defect as
the blind audit it replaced.

The right quantity is a PER-STEP RATE, which is run-length independent. Changing that re-defines what
all six numbers mean and needs its own calibration run: measure each substance's drift per step over a
few horizons, confirm it is linear (a leak) rather than saturating (a transient), and set the ceilings
from that. Until then, treat the table above as "six substances drift" and NOT as "six substances leak
at these magnitudes".

**WHAT IS BROKEN RIGHT NOW, AT THE TOP OF THE QUEUE:**
1. **`--bare` CHANGES THE PHYSICS.** Same seed, same frames: `o2_total` 37125.09 with the presentation layer,
   **36641.69 without** — 1.3% apart, while h2o and carbon match to the digit. Introduced by `a1919d0`.
   ~~Something in the skipped set is feeding the field.~~ **CORRECTED 2026-08-10 — one structural mechanism
   is now closed, and the remaining gap is unmeasured rather than unexplained.** `set_field` uploaded a whole
   CPU mirror over the device every step. Past step 0 that destroys whatever the GPU produced since that
   mirror was last read back, and how much that is depends on channel residency, which depends on who called
   `request_channel`, which depends on which consumers are alive — so the number moved with the presentation
   layer. Four of the seven channels it wrote (`lava`, `rock_fill`, `shock`, `fuel`) are in
   `SITUATIONAL_CHANNELS`. It is `seed_field` now and `push_error`s past step 0; step-time edits are queued
   sparse ops against the live buffer. **Whether the 1.3% is gone is UNMEASURED** — no windowed run has been
   taken since, so the rule below still stands until one is.
   **NO conservation number may be quoted from `--bare` until a run says the two agree.**
2. ~~**`moisture` IS DEAD.**~~ **FALSE — struck 2026-08-10.** It is read back unconditionally on every drain
   (`MaterialSphereGPU3D.gd:381`), produced on device by the three evaporation records
   (`reactions_sphere3d.glsl:449`) and scattered back at `MaterialFieldSphereStep3D.gd:230`. Starting the
   atmosphere dry and letting evaporation load it is CORRECT, and is the template the other seeds should
   copy. If `cloud_cells` reads 0 the mechanism is that condensate never exceeds `CONDENSE_COVER_MIN =
   5.0e-8`, which is a runtime question about the saturation curve, not a wiring break. This entry sent work
   at a problem that did not exist.
3. **`dust_total` reads 0** on short runs since the tracer collapse. Unconfirmed whether that is real
   (settling velocity is now Stokes-derived at 0.314 m/s, which may simply drain the sky) or a wiring break.
4. **CELLS ARE NOT THE SAME SIZE AND NOTHING WEIGHTS BY IT.** Measured 2026-08-10 by
   `scripts/check_sphere_grid.sh`: the largest cell is **6.3x / 7.9x / 8.8x** the smallest at res 8 / 16 / 32,
   and the ratio GROWS with resolution. So every conserved total is a raw sum over unequal volumes rather
   than an amount, and every transport moving a fraction of one cell into a differently sized one creates or
   destroys matter. `LASphereGrid` carries `cell_volume` / `face_area_outward` now; NO consumer uses them
   yet. **Every drift figure in this file predates that and has it baked in**, including the numbers
   `PHYSICS_RUBRIC.md` criterion 1 is scored on.

**TODAY'S WORK, all merged and pushed.** Kernels **32 → 25**. Comment prose **11,364 → 2,516 lines
(42% → 14%)**. Net about −10,000 lines.
- **One transport kernel for every airborne tracer** — `tracer_transport_sphere3d.glsl`. o2, co2, dust,
  moisture and (then) five scent channels are rows, not kernels. The scent CHANNEL is since deleted: Deleted: `o2_transport`, `co2_transport`,
  `dust_transport`, `dust_outscale`, `atmos_transport`, `scent_transport`, `scent_wind`.
- **One gravity-flow kernel** — `gravity_flow_sphere3d.glsl` replaces `water`, `lava_flow` and `slump`, which
  were the same kernel three times. Moving mass always carries its enthalpy now; there is no flag for it.
- **The static sea is gone**, from 17 files. It was an infinite sink — a static cell ran `mass_out = mass_in`
  and discarded every inflow, so water reaching the ocean was destroyed. `_static` was also allocated and
  never written, and one leftover upload threw **1,244,189 SCRIPT ERROR lines in a 20-frame run**.
- **Pressure is in pascals**, `G_ACC = 33.5` deleted; the wind runs on `real_seconds_per_step()` instead of a
  clock 432× short; Coriolis is `2Ω sin(lat)` from Earth's sidereal rate instead of an invented `0.6`;
  buoyancy is Boussinesq `g·ΔT/T`; the prescribed global "prevailing wind" that every cell was relaxed toward
  is deleted; `MAX_WIND` is deleted because wind speed is an output.
- **The physical-constants gate had two real bugs** — it silently dropped line-continued constants (hiding
  `DRY_AIR_GAS_CONSTANT_J_KGK`) and its resolver had **no operator precedence**, so `x1*M1 + x2*M2 + …`
  produced a wrong number rather than failing. Both fixed; the authority map went 129 → 135 constants.
- Latent heat, the pressure-dependent boiling point and the world's first derived length scale merged from
  `feature/enthalpy`; the biological rates are derived from cited measurements instead of fitted to biomass.

**HOW TO RUN, ONE COMMAND:** `scripts/agent_harness.sh sim [--frames N] [--raw] [--report k1,k2]`. It
re-imports only when a kernel changed, and **counts engine errors FIRST and REFUSES to print numbers if there
are any (exit 4)** — because for a whole session `sim_run` printed a clean-looking report over a million
error lines. A gauge that cannot report its own failure case is the defect this repo keeps producing.

**RUN COST, measured not guessed** (20 frames): engine+project boot 0.26 s · node construction 0.17 s ·
**terrain generation 3.3 s, which happens on its own timeline whether or not anything queries it** ·
solid-mask sample 0.36 s (now cached, keyed on a hash of the generator options + grid + generator source,
and spot-checked at 256 cells before it is trusted) · frames ~2.3 s. Gauge cadence is 64 (`LA_GAUGE_EVERY`
overrides) with a forced fresh recompute on the closing frame: the O(cells) GDScript gauges cost **158 ms
against a 6.5 ms field step**. Total 8.1 s, or 6.8 s with `--bare` — see defect 1 before trusting that.

*(Superseded state: `feature/heat-capacity-ssot` merged at `7353b1d` as nine commits — `b5f8e04` per-pass
energy probe · `347495f` heat capacity counts every carrier · `db22352` the SSOT gate · `27b2795` the soil
clamp gauge · `92ae453` rock_fill is a saturation · `b436129` the world seal · `5e1303f` the mole-based
carbon gauge · `a9817e8` the conservation gate.)*

**A RUN THAT CREATES OR DESTROYS ATOMS NOW EXITS 126.** `LAMaterialFieldConservation3D` audits every element
total against its sealed baseline, once, at a fixed 600 steps past the seal, and prints
`CONSERVATION_VIOLATION` naming the substance; `run_sim_offscreen.sh` greps for it and exits 126 (distinct
from 124 "never reported" and 125 "hung after reporting"). **It is a RATCHET, not a clean bill of health** —
every substance is in violation today, the module's `DEBT` table records the current figure, and lowering one
means editing that table down in the same commit that earns it. Raising one is not a thing that happens. A
run shorter than the horizon publishes `conservation_audited: false` and gates nothing. *(The module header
and `a9817e8`'s commit message both said such a run "reports `too_short`". No such string is emitted
anywhere; the header is corrected, the commit message cannot be.)*

**THE WORLD HAS TWO PHASES, AND EVERY DRIFT NUMBER FROM BEFORE THE SEAL IS SUSPECT.**
`LAMaterialFieldSeal3D` — SEEDING until the bootstrap has run and every matter/energy channel has actually
been delivered, then SEALED. All eleven conservation baselines latch AT the seal (field_step 9) instead of at
"the third heavy sample", which was a sampling artifact landing in the middle of seeding. Two things that
artifact was doing, both measured: it counted the planet being BUILT as drift, and it let a baseline be
latched through a channel that had not arrived — `energy_stock_first` came out bit-identical on two arms
whose regolith heat capacity differs by 29%.

**`world_seed` IS THE SCOREBOARD, AND IT HAS SIX ENTRIES, NOT SEVEN.** Everything in it is something the
substrate was TOLD rather than worked out. Measured at `7353b1d`:
`carbon 1354.82 · h2o 5300.53 · o2 36524.80 · mineral 31977.996 · energy_j 1.6728e17 · element_C_mol 1.5587e7`.
**The bar is a post-Theia seed** — a molten body and a bulk composition, with ocean, atmosphere and crust all
OUTPUTS — so progress is these entries being DELETED, each with the acceptance test that the thing it
asserted now emerges. Shrinking `h2o` means the sea, the lakes and the water table each have to arrive on
their own, in that order.
- ***(Corrected 2026-08-09. This listed a seventh entry, `temp_ground_p50 15.0`, and said "that last is
  exactly `INITIAL_TEMP`". The manifest carries no temperature at all. Every `note_seed` caller is a matter
  or energy ledger: `MaterialFieldLedger3D.gd` seeds h2o, carbon, o2, mineral and energy_j through
  `LAFieldLedgerBooks3D.run()`, and `MaterialFieldReport3D.gd` seeds element_C_mol. `INITIAL_TEMP = 15.0` is still asserted, at
  `MaterialField3D.gd:55`, filled at `:464` — it is simply NOT ON THE SCOREBOARD, so the one seed the file
  called out by name is the one nothing is scoring. Either note it into the manifest or stop calling the
  manifest the whole scoreboard.)*

**A RAW CHANNEL SUM IS A CONSERVATION GAUGE ONLY IF EVERY CHANNEL IN IT HOLDS ONE SUBSTANCE IN ONE UNIT.**
`carbon_total` summed co2 + biomass + detritus units and read **+1261%**; `element_C_total` in MOLES reads
**-26.7%** at 600 frames. The sign is different. Carbon is being destroyed, not created, and every previous
statement to the contrary — including the plan CLAUDE.md records, to fix a shortage by adding a source — was
reading a number that is not a quantity. `h2o_total` and `mineral_total` are legitimate raw sums; anything
spanning substances must go through `mol_per_unit`.

### Conservation — the gate's own debt table IS the work queue

`LAMaterialFieldConservation3D.DEBT_PER_STEP` is the single source; do not keep a second copy of these
numbers anywhere.

**THE DEBTS ARE PER-STEP RATES AS OF 2026-08-11, AND EVERY FIGURE BELOW THIS LINE PREDATES THAT.** They were
ceilings on a relative TOTAL, so a substance with any steady drift breached eventually and the verdict was
decided by how long the run happened to be. Anything quoted as "-28.27%" or "12% allowance" is in the old
unit and is not comparable to a rate. `scripts/physics_score.sh` reads the current figures; do not
transcribe them here, because a second copy is a second thing to go stale.

**THE OLD TABLE IS DELETED RATHER THAN STRUCK.** Unlike the false claims elsewhere in this file, those
numbers were true when measured and merely obsolete — git holds them, and leaving a table of
non-comparable percentages under a heading that says "work queue" is how the wrong unit gets quoted back.

**FOUR SUBSTANCES IMPROVED BY 3–5×** because the biological rates stopped being fitted, and **their
allowances came DOWN in the same commit**, which is what the ratchet requires.

**THESE LEAKS ARE STRUCTURAL, NOT DISASTER NOISE — confirmed on a second seed, and it overturns a standing
assumption.** Seed 9091 (17 impacts / 2 eruptions) against seed 4242 (19 impacts / 1 flood / 1 eruption):
`element_C` -28.581% vs **-28.553%**, `o2` -24.788% vs **-24.639%**, `oxidant` -10.402% vs **-10.240%**,
`nitrogen` -0.620% vs **-0.620%**, `mineral` -0.0061% vs **-0.0060%**. Five of six agree to within 0.16pp
across a completely different disaster draw. **`h2o` is the exception at -19.18% vs -17.56%, 1.6pp apart.**
So the standing "quote `phenomena_kinds`, the spread is discrete and disaster-driven" caution is right about
WATER and wrong about everything else — the other five can be measured on one run, and their allowances can
go to ~5% headroom whenever someone wants. Water is the one that genuinely needs three runs per arm.

- **CARBON GOT WORSE, −26.75% → −28.58%, AND ITS ALLOWANCE WAS NOT RAISED.** 0.42pp of headroom is left, so
  the next change touching the carbon path very likely trips 126. The maintainer took the change anyway on
  2026-08-10, explicitly: the rates it replaced were FITTED, and Rule Zero outranks this ratchet. **Nobody
  has measured why carbon got worse.** The plausible story is redistribution rather than new destruction —
  field `biomass_total` falls 6.27 → 0.0028 when photosynthesis stops running ~3000× too fast, so carbon
  that sat inert in a biomass pool now moves through CO₂ and detritus where the pre-existing leak reaches
  it. **That is a guess**, and it is exactly what per-pass matter attribution exists to settle.
- **WATER IS 1.8pp FROM TRIPPING ITS OWN GATE**, and its worst excursion this run, **25.82%**, is already
  ABOVE its 21% allowance. The audit is deliberately a single reading at a fixed horizon, so the excursion
  does not fire it — but the next change that touches water probably will, and that is the gate working.
- **Energy is NOT gated and must not be.** Sunlight enters and longwave leaves; what has to go to zero is
  `energy_residual`, not the change in stock. At the tip: `energy_run_drift` -1.2390e16 J against an
  `energy_stock_first` of 1.6728e17, and `energy_residual` -1.2376e16 against `energy_booked` -1.412e13.
  **Residual/booked is 877**, down from 1739 before latent heat and the derived rates — still three orders
  of magnitude from books that close.
- Every sanctioned mint counter is 0.0 (`h2o_inject_minted`, `mineral_inject_minted`,
  `biotic_inject_minted`, `heat_inject_unsourced_dc`, `energy_unsourced_dc`, `crater_mass`), so none of this
  arrives through an injection seam.

**MINERAL CONSERVES AND THE OTHERS DO NOT, AND THAT IS NOT A COINCIDENCE:** mineral is two to three orders
of magnitude tighter than everything else, and it is the only substance with a PER-PASS probe. Every other
one has a global total, which says a number moved and never where. That is the argument for step 2 of the
plan below.

---

## HOW GOOD IS IT? — `scripts/physics_score.sh`, and it is the whole score now

**Do not hand-enter a rubric row.** All six criteria are computed: 1, 2 and 5 from `SIM_REPORT`, and 3, 4 and
6 from `docs/MODEL_PARAMETERS.md` and the probe coverage. The script prints the row ready to paste, and
`PHYSICS_RUBRIC.md` holds the dated history. Criteria 3 and 4 used to be audit counts somebody had to
remember to redo, which meant the person scoring the work was scoring their own half of it. The ordering
of work below follows from it rather than from judgement: **energy must be booked before the seed can
shrink**, because an ocean condensing out of a steam atmosphere IS a latent-heat process.

## HOW TO RUN AND MEASURE

Never launch godot windowed directly — it steals the maintainer's keyboard focus. `--fixed-fps 60` is an
ENGINE flag and goes BEFORE the `--`:

```
LA_RUN_TIMEOUT=900 LA_NO_STREAMER=1 scripts/run_sim_offscreen.sh --path . \
  addons/local_agents/game/VoxelWorld.tscn --fixed-fps 60 \
  -- --sandbox --planet-only --run-frames=600 --fast=8 --seed=4242
```

~90 s per run; it exits by printing `LA_RUN_COMPLETE`. `--no-fauna` keeps vegetation (carbon cycle intact);
`--planet-only` is pure geophysics.

**A LONG-LIVED CHECKOUT GOES STALE THE MOMENT SOMEONE ELSE'S KERNEL EDIT MERGES.** `.glsl` kernels are
imported resources; a pass loads the compiled `.res`, and nothing recompiles it outside the editor. The
wrapper now refuses to launch against a stale tree — `STALE_SHADERS={"count":N}`, exit 3. Fix with
`godot --headless --path <dir> --import`. Do not bypass it to "just get a number".

**In a fresh worktree, in this order, or your measurements are fiction:** symlink the GDExtension binaries —
`ln -s <primary>/addons/local_agents/gdextensions/localagents/bin <worktree>/addons/local_agents/gdextensions/localagents/bin`,
NOT a `bin/` at the repo root, which does not exist — then
`godot --headless --path . --import`, then `scripts/editor_scan.sh` — always, because a fresh worktree has no
class cache. Never a bare `godot --headless --editor`; two concurrent scans segfault.

**THE ONE RUN COMMAND IS `scripts/agent_harness.sh sim`** (wrapping `scripts/sim_run.sh`). It runs the
standard arm off-screen with the streamer off, imports only when a kernel actually changed, and **counts
engine errors first and refuses to print numbers when there are any, exiting 4**. Flags: `--frames N`,
`--seed N`, `--fast N`, `--path DIR`, `--fauna`, `--full`, `--raw`, `--report k1,k2`, `--keep`, and
`-- <extra scene args>`. Do not hand-write the wrapper invocation again.

**THE STREAMER IS OPT-IN** (`--streamer`). It used to default on, so every automated run had to remember
`LA_NO_STREAMER=1` or it would boot a local llama-server.

**Gates:** `scripts/agent_harness.sh lint` is what CI runs, and includes `check_physical_constants.sh`,
`check_reaction_balance.sh` and `check_heat_capacity_ssot.sh`. A run that breaks conservation exits **126**.

**Instruments:** `LA_SOIL_BUDGET=1`, `LA_MINERAL_PROFILE=1` (the only one that answers "did it move
DOWNHILL", which no total can) — both of these sample outside the contended slot and can be armed with
anything. **THREE probes share the driver's ONE `set_step_probe` slot and are mutually exclusive:**
`LA_MINERAL_BUDGET`, `LA_H2O_BUDGET`, `LA_ENERGY_BUDGET`, in that declared precedence
(`MaterialFieldSphereStep3D.gd:104-128`). Arming more than one push-warns, names every armed flag, and runs
the FIRST in that order. Do not read a run that armed two as if both reported. *(Corrected 2026-08-09: this
said there were two and that the shape was a nested `if` at `:100-106`. A third contender, the per-pass
energy probe, turned that into an explicit precedence list.)*

- **Three runs per arm**, quoting `phenomena_kinds` (a dict, e.g. `{"impact": 20, "eruption": 1}`) and
  `bolts` — residual spread is discrete and disaster-driven. *(Corrected 2026-08-09: this named
  `phenomenon`/`impact`/`eruption`, none of which are keys in `SIM_REPORT`. The dict is `phenomena_kinds`,
  with `phenomena_tracked` and `phenomena_recent` beside it.)* Compare at equal `field_sim_s`, never equal
  `--run-frames`.
- **Read the books out of `SIM_REPORT` rather than arguing from temperature:** `conservation` (the drift
  per substance), `conservation_worst`, `conservation_violations`, `conservation_steps`,
  `conservation_failed`, `world_seed`, `world_seal_step`, `energy_run_drift` / `energy_stock_first`,
  `energy_residual` / `energy_booked`.
- **A global mean cannot answer a local question.** `temp_mean` is inflated by magma; use `temp_ground_p50`.
- **CHECK THE SIM IS ALIVE FIRST.** A silent load failure once printed a normal-looking `SIM_REPORT` with
  zero reaction records. An aggregate that is exactly `0.00`, or an order of magnitude off, is a broken
  pipeline until proven otherwise.
- **A gate that passes with the feature disabled is not a gate.** Build the disabled arm. This caught an
  inert 175-line module that had passed every check written for it.
- **At 43.2 s per field step, a 600-frame run is ~7 hours of planet time** — during which Earth gets about
  1 mm of rain. "Do rivers run" needs 4000+ frames, not a bigger constant.

---

## WHAT IS STILL FAKE, HARDCODED, OR IMPOSSIBLE ON A REAL PLANET

Ranked by how much they distort the simulation. Everything here is a place the sim asserts an answer instead
of computing one.

### Held by fiat — a value is asserted, so the physics cannot close

*(Two entries here are STRUCK rather than deleted, which is this file's one exception to "a finished item is
deleted": both were FALSE, and both sent real work at problems that did not exist. The rest of the corrected
batch is gone, because git holds it and nobody was going to re-derive them.)*

1. ~~THE OCEAN IS A THERMOSTAT~~ — **FALSE, and it was already false when it was written.** It said
   `heat3d_cool_sphere3d.glsl:47-50` "holds the sea near a fixed temperature … the single largest remaining
   fiction". That kernel was rewritten on 2026-08-03, the same day this entry was; `sea_water_target()`,
   `SST_SURFACE` and `WATER_TEMP_DEEP` are all gone and its own header documents each deletion. **Stage 3's
   "kill the ocean thermostat first" was already done.**
2. ~~BURNING CELLS ARE PINNED TO 640 °C~~ — **FALSE for the pin and the carbon**, and the kernel it used to
   cite is gone. *(Re-cited 2026-08-09; it read "since `fire_sphere3d.glsl:190`".)* Combustion is a REACTION
   RECORD now — `reactions/CombustionRecords.gd` R26, ARRHENIUS on cellulose's measured pyrolysis activation
   energy — so `fire_sphere3d.glsl` is deleted with its `IGNITE_TEMP`, `FIRE_START`, `FIRE_GROW`,
   the stored `fire` intensity and its radiant-spread gather. It also brings combustion under
   `check_reaction_balance.sh`, which is why it destroyed H, O and N for as long as it did: no record
   described it, so no gate could see it.
3. ~~THE SOIL KERNEL'S SECOND CLAMP IS UNINSTRUMENTED~~ — **INSTRUMENTED, AND IT READS ZERO.** It said
   `soil_sphere3d.glsl:583`'s `water[g] = max(0.0, ...)` "can only ever create water, with nothing recording
   how much", which was true. `DBG_OPEN_CLAMP_GAIN` now mirrors the regolith twin
   (`soil_sphere3d.glsl:261` declares the slot, `:585` zeroes it, `:604-606` writes it); six samples over
   300 frames read `open_clamp_gain` 0.0000 throughout, with `clamp_gain` 0.0000 beside it. The clamp exists
   and never binds. **The gauge was mutation-tested before that zero was believed** — forcing it to bind
   reads 342.38 / 364.96 / 368.77 — because a gauge never seen to move is a gauge nobody has tested.

4. **NOTHING KEEPS SNOW ON THIS PLANET, AND TWO SEPARATE HEAT-CAPACITY BUGS WERE HIDING IT.**
   `snow_cells` fell **1170 → 76 → 17**, and the second step is not a regression either. *(Second figure
   added 2026-08-09; the entry stopped at 76.)*
   - **1170 → 76:** `heat3d_cool` — the kernel whose entire job is radiative cooling — had no snow term in
     `rc_of`, so a snowpack cell read as ~1186 J/m³K (air) instead of 6.27e5 (snow): a 500× under-estimate
     of what it takes to warm snow. Snow was trivially cold-able and therefore persisted.
   - **76 → 17:** `VOL_HEAT_CAP_SNOW` was 3.32× too small — a settled-snowpack density (300 kg/m³)
     multiplying a channel that is measured in WATER EQUIVALENT.
   This is the band-aid-removal test coming out the wrong way round: the clamp came out and the phenomenon
   it was propping up went with it. **Every snow, ice-albedo and treeline claim measured before 2026-08-09
   was measured against the 1170.** A fresh run at `7353b1d` reads `snow_cells` 20, `ice_cells` 0,
   `sea_ice_cells` 0, `clim_ground_frozen` 18, `clim_coldest_ever` -30.8 °C at 41° latitude and 556 m — so
   the planet does reach freezing locally, it just does not hold a pack. Deciding whether ~20 is right: this
   planet has no seasons deep enough and no orographic lift to speak of, so the question is whether snow
   should persist at all at `temp_ground_p50` 25.1 °C, which is Stage 3's asymptote question rather than a
   snow-kernel question. Do not "fix" it by moving a constant.

### Missing physics — a real mechanism simply is not there

5. **LATENT HEAT — LANDED ON `feature/enthalpy` (`f61d426`), NOT YET ON `0.4-dev`.** *(Rewritten
   2026-08-09; it read "NO LATENT HEAT" and specified the work.)* All seven phase records now carry an
   enthalpy DERIVED from `LASubstances` rather than written down, and sublimation is not declared at all —
   it is fusion + vaporisation, so Hess's law cannot be violated and the 2.433e5 J/kg that shipped code
   released from nothing per water→vapour→snow→water traverse is not expressible. **Evaporative cooling
   exists now**; it did not, and `PhaseRecords`' own header records a previous pass meeting "the planet
   could not get cold" by moving water's freezing point to 12.5 °C. The missing 2.49e9 J/m³ is why it could
   not get cold. The older record-enthalpy branch (`worktree-wf_c468d92c-702-2` / `feature/latent-heat`
   `ae1a497`) is SUPERSEDED and must not be merged — it is the version that pairs L_vap at 100 °C with
   L_fus at 0 °C.
   **What is left, in order:** ~~`heat3d_cool_sphere3d.glsl` still charges latent heat for a boil at a flat
   100 °C~~ — DELETED 2026-08-10. It was a duplicate AND a thermostat and should
   be deleted (audit A3); condensation (`atmos_precip`) and deposition (`snowice`) still release nothing
   (audit A4); a record carries ONE enthalpy where L(T) is a curve (Watson), so evaporation is charged at
   its 0 °C figure everywhere — ~11% wrong at 100 °C and completely wrong near 374 °C. **The structural
   migration is still owed on top of all that** — store energy per cell, derive temperature via
   `LASubstances.enthalpy_to_state()`, and collapse `water`/`moisture`/`snow` into one conserved `h2o`.
   That deletes the phase records, the snowice deposition kernel and the rain condensation leg.
   *(Corrected 2026-08-10: this named "R21, R22, R23, R24, R25". **R23, R24 and R25 DO NOT EXIST.**
   `LAPhaseRecords.records()` returns EIGHT records as of the deposition fix, and R21/R22 are comment labels
   on two of them, not identifiers anything resolves. Several entries in this file reason about R23 as
   though it were a thing; none of them can be acted on as written.)*
   **DONE since:** the snowice deposition kernel is deleted and IS a record now, paying
   +latent_sublimation (fusion + vaporisation, derived, so Hess's law holds). It previously moved vapour
   straight to ice with NO energy term at all — its `Temp` binding was `readonly`, so it was structurally
   incapable of charging the heat — and called that "conserving", meaning mass only.
6. **NO MANTLE CONVECTION.** The geotherm is a seeded initial condition maintained by a reservoir
   (`MaterialFieldGeotherm3D.gd:4-5`). A real planet's interior circulates, and that circulation is what
   drives plate motion, so the plates below are kinematic rather than driven.
7. **TWO MASS TRANSFERS STILL MOVE TEMPERATURE WITHOUT MOVING HEAT.** *(Corrected 2026-08-08. This said
   "EVERY inter-cell transfer", which is false and expensive: three kernels already carry enthalpy with the
   mass and two say so in their own headers — `lava_flow_sphere3d.glsl` gathers `inflow_heat` as a
   mass-weighted donor sum (`:165-176`, mixed at `:197`, claimed in its header at `:6`),
   `magma_buoy_sphere3d.glsl` mixes arriving enthalpy into the destination (`:114`, header `:56`), and
   `soil_sphere3d.glsl:35-37` is a capacity-weighted mix. A session acting on the old wording re-plumbs
   three kernels that are already right and misses the two that are not. The two lava/magma citations were
   themselves wrong — `:140-151` is an overflow block with no heat in it and `:39` is `const float
   MAX_MASS`; re-cited 2026-08-09.)* The real cases:
   **the regolith→regolith Darcy leg**, disclosed at `soil_sphere3d.glsl:51`, and **sediment slump**, which
   `slump_sphere3d.glsl:6` marks "NO carry-heat". Spring heat's donor was the third and is paid.
8. **ROCK HAS THREE COMPOSITIONS AND NO STRATIGRAPHY, AND ORGANIC MATTER HAS ONE.** Minerals are
   speciated (silicate / silica / carbonate) and the Urey reaction balances, but carbonate and silica do
   not travel and do not lithify, so there is no limestone and no sandstone; `solid` derives from
   `rock_fill`, so splitting it reaches solidity, overburden, plate advection and the mineral stamp, and
   per-species SUSP/DUST/erosion/slump follow. **Organic matter is still ONE lumped CH₂O** — which is why
   ignition is one number, and why this planet cannot have peat even though it demonstrably BURIES
   organics (`carbon_buried` ~290 units per run).
9. **WHETHER THE FOOD WEB WORKS IS UNMEASURED — and the two gauges this entry cited cannot answer it.**
    *(Corrected 2026-08-08.)* It read "`death/eaten` is 0 and `biota_node_intake` 0.00 in every arm …
    predation appears never to have functioned", and both halves are artefacts:
    - **`biota_node_intake` reads 0.00 when predation WORKS.** It is credited only on the fallback branch
      for prey with no body ledger (`CreatureThink.gd:167-174`), and every creature in the library has
      `draw_body_mass`, so a functioning predator takes the other branch and credits it nothing.
    - **`death/eaten` 0 is guaranteed by the flag**, not by the food web: the quoted baseline is
      `--planet-only`, which spawns no animals at all (`SimAblate.gd:37`).
    The predation path is present and reachable (`CreatureThink.gd:178,194`, `Fish.gd:849` all call
    `prey.die("eaten")`). **It needs a fauna-enabled run to settle, which nobody has done.**
    The claim that "the free `ambient_graze` food source hid it for as long as it existed" is also wrong:
    `CreatureDigestion.gd:95` still exists and runs every frame. What was removed is the FREE part — it now
    debits the field through `graze_biomass` (`:107`) and draws forage water through the same debit as a
    drink (`:118-121`).

### Prescribed where it should emerge

10. **PLATE TECTONICS IS KINEMATIC VORONOI.** Plate boundaries are prescribed and rotate; the crust now
    genuinely advects with them, but the plates themselves are not a consequence of convection dragging a
    brittle shell until it cracks. *(Maintainer has explicitly OK'd faking this one — true geodynamics is
    research-grade. `GEOLOGIC_TIME_ACCELERATION = 3.0e5` is the knob, set by measurement, in
    `PlateTectonics.gd:67`.)*
11. **BREEDING HAS A GLOBAL `pop_cap` CEILING, AND SPACE DOES NOT REGULATE IT.** *(Narrowed 2026-08-08. It
    said "rather than population regulated by food, energy and space", and food and energy DO regulate it
    now: `EcologyBreeding.gd:184-192` (`_spawn_cost`) refuses to spawn below `SPAWN_ENERGY_FLOOR` and
    charges `SPAWN_ENERGY_FRAC` of the parent's maximum, and `:170-175` multiplies the birth count by a
    biomass food gate. The caps — `:80` for land, `:160` for aquatic — sit on top of those as hard
    ceilings.)* Space is the unregulated one. Cited as `:23,29` before, which are prose lines inside a
    comment block.
12. **THE DAY IS A GAME NUMBER.** `SimClock.gd:29` `DAY_LENGTH = 200.0`, against a field step whose 43.2
    real seconds are DERIVED from it (`MaterialFieldSphereStep3D.real_seconds_per_step()`, `:40-44`) and a
    `PLANET_SPIN_RATE = 0.10` that is not (`game/VoxelWorld.gd:88`, applied `:602`; a third reader flags the
    mismatch at `MaterialFieldClimateSwing3D.gd:32`). Earth's day is 86400 s. Three clocks, one rotation.
13. **THE PLANET IS PINNED AT THE WORLD ORIGIN** and the sun moves around it — `SystemOrbits.gd:25-26`
    ("The planet does not move; the star does") and the code that does it at `:207`. A deliberate
    moving-frame choice; making it literal is the 0.6 headline. *(Cited as `:228` before, which is a doc
    comment inside `_integrate_orbit` — true, but not the mechanism.)*

14. **O₂ AND CO₂ ARE TWO GASES IN ONE ATMOSPHERE AND ONLY ONE OF THEM RIDES THE WIND.**
    `co2_transport_sphere3d.glsl` is diffusion + wind advection + a density-driven downward settle + a CFL
    cap. `o2_transport_sphere3d.glsl` is the SAME lattice with only the diffusion term, and its header says
    so outright: *"NON-MECHANICAL: the wind ADVECTION term is DROPPED here."* So in one parcel of air the
    CO₂ blows downwind and the O₂ does not. `scent_transport_sphere3d.glsl` has the same hole — *"DROPPED
    (as in o2_transport_sphere3d)"* — **against a stated design goal**: `CLAUDE.md`'s one-substrate rule
    uses *"scent that rides the real wind and washes in the rain"* as its canonical example, and only the
    rain half is built (`scent_transport_sphere3d.glsl:45`, `RAIN_WASH = 0.30`). `CO2_SETTLE = 0.05`
    (`co2_transport_sphere3d.glsl:71`) is also a hardcoded buoyancy share when `LASubstances` already
    carries the molar masses it should derive from (CO₂ 44.01 vs air 28.96); the kernel's own comment at
    `:63-66` says so. *(Named `GAS_SETTLE` here until 2026-08-09; no such identifier exists in the tree.)*
    **The fix is one parameterised solver** — `{diffuse, advect, settle, out_max, decay, rain_wash,
    channels}` — replacing all three (~356 lines → ~200), which also absorbs `dust_outscale_sphere3d.glsl`
    (96 lines computing the CFL scale `co2_transport` computes inline in `out_scale()`). Sequence it:
    unify AT PARITY first (advect 0 for O₂/scent) so the refactor A/Bs as a no-op, then turn the wind on as
    its own measured commit. NOT candidates: `atmos_transport` (condensation-coupled H₂O),
    `erosion_transport` (on the settled list), `dust_transport`'s leeward deposition.

### Instruments that lie

15. **`molten_counts()` CAN REPORT ZERO FROM A STALE MIRROR WITH NO PROVENANCE FLAG.** It reads `_f._lava`
    and `_f._solid` (`MaterialFieldQueries3D.gd:551-567`), and `lava` is demand-gated
    (`MaterialSphereGPU3D.SITUATIONAL_CHANNELS`, `:208-209`), so between eruptions the gauge cannot tell "no
    lava" from "the channel never arrived" — exactly what `mass_live` exists to prevent for the element
    inventory (`MaterialFieldLedger3D.gd`, `_publish_element`). `magma_cell_count()` and `magma_erupting()`
    delegate to it, so all three inherit it. *(This entry used to claim those two were HARDCODED. They are
    live, and have been: one cached walk behind a `_molten_step` guard.)* The `7353b1d` baseline reads
    `magma_cells` 5, `lava_cells` 0, `magma_erupting` false on a run that logged one eruption, which is
    exactly the ambiguity — a lava flow that has solidified and a channel that never arrived look identical.
    Deciding it: give `molten_counts()` the same provenance flag and read it on a run with no eruption.
16. **The element inventory has no per-pass attribution.** It reports that carbon moved, not which reaction
    moved it (`MaterialFieldLedger3D.gd`, `_publish_element`). The mineral probe already does this and found a
    leak in one run by naming `fire_dust` (`MaterialFieldMineralProbe3D.gd:50`).
17. **`fuel_total()` IS THE LAST MASKED CONSERVATION TOTAL.** *(Narrowed 2026-08-09. It read "A GAUGE THAT
    SUMS OPEN CELLS ONLY IS NOT A CONSERVATION GAUGE, and at least one still is … Any total used to answer
    'was matter created or destroyed' needs its mask-free twin" — and the twins landed on 2026-08-08.
    `MaterialFieldLedger3D.gd` publishes `fuel_open_total` beside `fuel_all`, and every
    element-inventory leg now carries an `_all`. What is left is one gauge, not a class of them.)*
    `MaterialFieldQueries3D.gd:645-652` still gates on `_f._solid[c] == 0`, and it is what `SIM_REPORT`
    publishes as `fuel_total` (`MaterialFieldReport3D.gd:328`) — so the number a reader sees is the masked
    one while the mask-free twin sits in another module under another name. *(Cited as `:624-631` before,
    which is `mineral_total()`'s doc comment.)* The other `solid[c] == 0` gates in that file (`:222`,
    `:429`, `:742`) are shell-mean, flow and fertility diagnostics — not conservation gauges, and correctly
    masked. Deciding it: publish the twin beside it, or make `fuel_total` the unmasked one and rename the
    masked reader. **This is not cosmetic — see item 18, where the masked reader produced a false finding
    the very next entry down.**
18. **`fire_peak` READS 0.0 AND NOBODY KNOWS WHICH ZERO IT IS — BUT THE FUEL HALF OF THIS ENTRY WAS WRONG,
    AND ITEM 17 IS WHY.** *(Corrected 2026-08-09.)* `fire` is in `MaterialSphereGPU3D.SITUATIONAL_CHANNELS`
    (`:208-209`), so its CPU mirror is only fetched on demand, and `fire_peak`
    (`MaterialFieldQueries3D.gd:655-662`) has no provenance flag — the same defect as item 15, on a
    different channel. That half stands: **a gauge that cannot distinguish "nothing burned" from "the
    channel never arrived" cannot verify any change to combustion**, which is precisely what it was asked
    to do.
    - **What was wrong:** the entry read "`fuel_total` fell from a seeded 216 to ~152, which is fuel being
      consumed by something", and treated that as evidence something was burning unseen. It is not. At
      `7353b1d`: `fuel_total` 155.29, `fuel_open_total` 155.70 — and `fuel_all` **216.19**, which is the
      seeded quantity, unchanged. **The fuel is all still there; ~61 units of it went under the solid
      mask.** Burial is not loss, the mask-free twin says so, and the entry was reading the masked gauge
      item 17 exists to warn about. This is the same mistake `nitrogen_total` produced before its `_all`
      twin landed: an unledgered total reading badly, not matter destroyed.
    Deciding the surviving half: give `fire_peak` the `mass_live` provenance treatment, then re-read it on a
    run with a known fire.

---

## DO THIS NEXT — the staged plan

Each stage has its own verification. Do not merge stages.

**DO THESE FIRST, in this order.**
1. **FIX THE THREE LIVE BREAKAGES** listed in the State section: `--bare` changing `o2_total` by 1.3%, the
   dead `moisture` channel, and `dust_total` reading 0. The first two are the ones that matter — a dead
   moisture channel means the water cycle's vapour half has not been running, so every cloud, rain and
   evaporation claim in this file predates evidence.
2. **FINISH THE KERNEL COLLAPSE. 25 left; the floor is about 18.** Remaining families, each one operator
   with per-row data: `magma_buoy` + `erosion_transport` (the rest of the gravity movers, though both have
   genuinely different laws — check before flattening) · `atmos_rain` + `atmos_precip` (`atmos_rain` is now
   just `water += rain`) · `scent_fert` + `fungus_fert` · `heat_sphere3d` + `heat3d_buoyancy` (same bond
   gather, different driver). Genuinely distinct and staying: `reactions`, `soil`, `heat3d_solar`,
   `lava_phase`, `plate_advect`, `wind_pressure`, `wind_step`, `fungus`, `erosion_pickup`, `snowice`,
   `charge_accum`, `shock`, `solid_derive`, `cell_list_lava`, `copy`, and the two collapsed kernels.
3. **THE CONSTANTS I CHOSE THIS SESSION ARE THE ONLY UNDERIVED ONES LEFT IN TRANSPORT** and each needs
   deriving or an explicit exemption: `SETTLE_CALM_REF = 6.0` m/s, `SETTLE_MIN_RATIO = 0.08`,
   `OUT_MAX = 0.9`, `EDDY_DIFFUSE = 0.02`, `SETTLE_V_PER_CONTRAST = 0.05`. Dust settling IS derived now
   (`LAPhysical.stokes_settling_velocity`, 0.314 m/s, Re = 1.2 so it sits at the edge of Stokes validity).
4. **P0's SECOND HALF IS DONE** — pressure is in pascals, the wind is on the real clock, `P_REF` and
   `K_P_REF` are `STANDARD_PRESSURE_PA`. What remains from that plan: wire `boil_c_at(id, p_pa)` into its
   two remaining scalar consumers (`MaterialFieldQueries3D`, `GeoRecords`) and **delete
   `heat3d_cool_sphere3d.glsl`** — ~~a duplicate of R23's energy leg and a 100 °C thermostat.~~ ALREADY DONE.
   Also still true: **`params.dt` is uploaded to `reactions_sphere3d.glsl` and never read**, so every
   reaction rate is per-STEP rather than per-second.
   *(Do NOT take `feature/latent-heat` (`ae1a497`) — the superseded version that pairs L_vap at 100 °C with
   L_fus at 0 °C. `feature/enthalpy` is merged.)*
2. **PER-PASS ATTRIBUTION FOR MATTER, AND IT NOW HAS A SPECIFIC QUESTION TO ANSWER: WHAT DESTROYED THE
   EXTRA 1.9% OF CARBON?** Build it the way `LAMaterialFieldEnergyProbe3D` does for heat and
   `LAMaterialFieldMineralProbe3D` already did for rock. Mineral is three orders of magnitude tighter than
   everything else and is the only substance with a per-pass probe; that is the whole lesson. Point the same
   shape at the element inventory and carbon / oxygen / water each name their pass in one run instead of
   being argued about. **Nothing blocks this one.** It turns the debt table from a scoreboard into a set of
   addresses, and carbon is now 0.42pp from failing the build, so it is no longer an abstract improvement.
3. **THEN DELETE SEED ENTRIES**, one at a time, each with the acceptance test that the thing it asserted now
   emerges. Watch the line vanish from `world_seed`. `INITIAL_TEMP` is the one to start on, because it is not
   in the manifest at all and so is not being scored — see the State section.

**STAGE 1 — stop the sim creating matter and energy.** The balance gate, the element inventory, the
composition table, the seal and now the **conservation gate** all landed; the kernel violations that used to
head this list are closed. **What is left is two numbers, and neither is at zero:**
- **MATTER:** the debt table in the State section. Six substances, all in violation, `mineral_total` at
  -0.027% and `o2_total` at -90%. The gate holds the line; step 2 above is what will move it.
- **ENERGY:** `energy_run_drift` **-1.3404e16 J against an `energy_stock_first` of 1.6728e17 — 8.0% of the
  planet's whole thermal stock in 600 frames** (one run at `7353b1d`; the merge measured -7.76% over three
  runs per arm, so read 8% as the arm, not as a regression). *(The pair quoted here before, "-1.163e16
  against 1.548e17", divided by the run's CLOSING stock. `energy_stock` and `energy_stock_first` are
  different fields, and the seal moved the second one.)*

**THE ELEVEN-TERM WORK QUEUE IS GONE AND HAS TO BE REBUILT FROM THE CODE.** *(Corrected 2026-08-11. This
said "the work queue is the eleven unbooked terms the ledger names in its own header
(`MaterialFieldEnergyLedger3D.gd:79-137`) — read it there rather than copying it here". A line-level comment
scrub deleted most of that header before the ledgers were collapsed; what survived at HEAD was seven
disconnected sentence fragments, and the file itself is now deleted. Nobody can read the queue there. The
terms below are what this file still records about it, and they are all that is left.)* **Items 8, 9, 10 and 11 are CLOSED** — that is every term the gauge itself found,
and between them the drift went 12.77% -> 7.76%. **Terms 1 through 7 remain, and 1, 2 and 3 are all latent
heat**, which is why step 1 above is deciding `feature/enthalpy` rather than re-implementing it. Do not
expect what is left to be cheap: item 11 was `rc_of` not being a function of the matter present, and
unifying five copies into `kernels3d/rc_shared.glsli` moved the drift 2.5% while changing the planet a lot
(see item 4).

> **READ THE TOTAL, NOT THE RATE TIMES A STEP COUNT.** *(Corrected 2026-08-08. This said "1.07e-4 per step,
> 6.3% over 590 steps", which multiplied `energy_run_drift_per_step` by `field_step`. Those are different
> clocks: the ledger divides by `energy_run_steps` — 775 in the run above, because it starts counting at
> `energy_first_step` 14 and its own sampling cadence is not the field's. The instrument publishes
> `energy_run_drift` as an absolute; use it.)*

**Verified by one question, and it is now askable:** does the planet still create energy, yes or no.
Before the ledger existed, nothing in the repository could answer it — every climate claim was argued from
temperature, which is a state variable and tells you where the planet HAS got to, never why.

**STAGE 2 — seed a primordial planet.** Post-magma-ocean Hadean, ~4.4 Ga: hot surface, thick CO₂/N₂
atmosphere, water still largely steam, **no free O₂** (it is a product of life), no biosphere. **Oceans must
CONDENSE, not be placed.** Delete `INITIAL_TEMP = 15.0` and every "partway" seed. Source and cite the
composition, and name the era. **Uninhabitable for a whole run is an acceptable result.** `6ad2417` (on
`feature/conservation`, one commit off `0.4-dev`, tagged WIP and explicitly droppable) is a start on this.
`feature/enthalpy`'s pressure-dependent `boil_c_at` is the other half: at 100 bar water boils at 306 °C, and
a magma-ocean planet condenses its ocean when the surface passes ~300 °C, so a model with a flat 100 °C
boiling point cannot reach this stage at all.

**STAGE 3 — does it cool, and where does it settle?** *(Its first sentence used to read "Kill the ocean
thermostat first, or the books cannot close." THE THERMOSTAT WAS ALREADY DEAD when that was written — see
item 1 — and following it costs a session on a non-problem. What actually has to come first is Stage 1's
energy drift, because a planet losing 8% of its thermal stock per 600 frames has no settling point to
find.)* Run 4000–6000 frames; watch `temp_ground_p50` for an asymptote and `snow_cells` for an ice-albedo
runaway. Today's starting point is `temp_ground_p50` 25.1 °C, `temp_mean` 41.0 °C, `snow_cells` 20 and no
sea ice at all. **Do not tune the solar constant** — 1361 W/m² is a measured fact.
**And note the conservation gate audits at 600 steps and reports `too_short` below that** — a 4000-frame run
gets exactly one audit, early, and then runs 3400 more frames ungated. If Stage 3 is where a leak shows up,
that is the horizon to revisit.

**STAGE 4 — oceans condense.** Verify the sequence *happens*: cooling past the condensation point rains the
atmosphere out. Success is the event occurring, not a number looking right.

*(The CO₂ half of this stage LANDED 2026-08-08 and is deleted from the ask. Silicate weathering is the Urey
reaction now — `GeoRecords.gd` D1b, CaSiO₃ + CO₂ → CaCO₃ + SiO₂ — and it draws `carbon_co2` from 81.5 to 26.7
over a 600-frame run while total carbon holds at 845.9 mask-free. Two things it left open, and both are live
work rather than history: the **return leg D1c never fires** — metamorphic decarbonation needs 280.7 °C and
the hottest cell in the field reaches 256 °C, so the sink is one-way and CO₂ declines monotonically, which
means a long `--geotime` run will strip the atmosphere; and the drawdown is ~8× Earth's rate for the same
elapsed geological time because **this planet's atmosphere is only a few cells deep over every weathering
cell**, so its CO₂ reservoir is thin relative to the reacting surface. Neither is fixed by moving a rate
constant — the weathering rate measures 0.30× real basaltic denudation on this project's own declared
geological clock. What would decide the first: run long enough, or hot enough, for a lava flow to cover
weathered ground, and watch `carbonate_total` fall while `carbon_co2` rises.)*

**STAGE 5 — the geological bake (`--geotime`).** *(Two things it will trip over, both verified 2026-08-08:
in-memory snapshots DROP the GPU field unless `LA_SNAPSHOT_FIELD` is set — `WorldSaveController.gd:277` —
so a bake wants the disk path; and a restored field is pinned to `grid_res_per_face` x `grid_depth`, i.e.
to the quality preset, because `MaterialFieldSnapshot3D.restore()` refuses a cell-count mismatch outright.)* Run the planet forward through geological time and freeze
the result as the start state. This is what makes habitability an output. Needs a real stopping condition
(temperature asymptote, oceans condensed, atmosphere stable). The snapshot path exists; `--geotime` does not.

Life is not a stage. It is what stage 5 hands to 0.5.

---

## WHAT IS SETTLED — do not rebuild these

*(The most dangerous list in this file, because work AVOIDS what is on it — so an entry that stops being
true has to come OFF. `REPOSE_TAN` did, on 2026-08-08: the value was right and the application was not. It
belongs in a map of what is LEFT only because "nothing is left here" is itself a claim about remaining
work.)*

~~`REPOSE_TAN = 0.70`~~ — **it was on this list and it was not sound.** The value is right (tan 35°, the
repose angle of dry granular material, sourced as `LAPhysical.REPOSE_TAN_DRY_GRANULAR`,
`PhysicalConstants.gd:268`, with the GLSL copy at `slump_sphere3d.glsl:82` gate-bound to it) but it was
APPLIED as a mass difference against a tangent, which asserts cells are cubes. On the cubed sphere the
aspect runs 1.07–4.08, so sediment stood at 33° at the shell floor and 9.8° at the top. Fixed via
`LASphereGrid.link_arc`.

Still settled, and each is one grep from being falsified if you doubt it:

- the H₂O ledger's inclusion rule (`MaterialFieldLedger3D.gd:14`);
- the DEFS record engine's std430 layout (`ReactionDefs.gd:219`, `RECORD_BYTES = 144`; the layout itself is
  documented at `:296-303`) *(cited as `:211` before, which is `GATE_NOT_STATIC`)*;
- the neighbour / tangent tables (`SphereGrid.gd:115-116`);
- the soil budget's per-leg identity (`kernel_residual` exactly 0.0, `MaterialFieldSoilBudget3D.gd:192`)
  *(cited as `:186` before)*;
- the erosion transport law — no fitted constant, load moves in the same proportions as the water carrying
  it (`erosion_transport_sphere3d.glsl:18-23`);
- the geotherm as a seeded initial condition with a derived vertical scale
  (`MaterialFieldGeotherm3D.gd:23-30` states the one conceit — depth is vertically exaggerated, and both
  literal readings of this planet's scale fail; `_derive_gradient()` at `:314,:367` derives °C per model
  metre from Earth's measured near-surface gradient) *(cited as `:25-41` before)*;
- ONE definition of a cell's volumetric heat capacity per side of the GPU boundary —
  `kernels3d/rc_shared.glsli` and `material/HeatCapacity.gd`, held equal by
  `scripts/check_heat_capacity_ssot.sh`, which gates the FORMULA rather than the values because the values
  were never what drifted. *(Added 2026-08-09. This one is settled BY A GATE, which is the strongest form
  an entry on this list can take: nine copies in five incompatible formulas is how it got here.)*
- the aquifer's `k_rel` / `RESIDUAL` capillary retention (`soil_sphere3d.glsl:176-185`);
- the saturation curve from August-Roche-Magnus; Kozeny-Carman conductivity from porosity;
- weathering as ice expansion and Arrhenius dissolution (`GeoRecords.gd:115,125` / `:287-293`);
- lithification on real lithostatic pressure (`GeoRecords.gd:310-316` against
  `LITHIFICATION_PRESSURE_PA = 5.688e7`);
- metabolism as the substrate's own respiration reaction, mass-scaling emergent rather than typed.

---

## OPEN DECISIONS

- **Memory/Graph lane: keep the SQLite-only graph architecture, or introduce a specialised graph backend?**
  (`controllers/ConversationStore.gd` → `docs/NETWORK_GRAPH.md`.) *(Restored 2026-08-09: this entry arrived
  from the deleted `ARCHITECTURE_PLAN.md` in `138166e` TRUNCATED — it ended at "or introduce a", so the
  alternative it names and the pointer to the design doc were both lost.)* Nobody has picked a side and the
  status quo ships: `gdextensions/localagents/src/NetworkGraph.cpp` is the raw `sqlite3` C API, vector
  search is a hand-rolled VP-tree over the `embeddings` table, and four consumers share one
  `user://local_agents/network.sqlite3` (`ConversationStore.gd:6`, `graph/ProjectGraphService.gd:6`,
  `graph/BackstoryGraphService.gd:18`, `sim/ecology/BandChronicle.gd:57`). **What should decide it:**
  FTS5 is not compiled into this build, so full-text search over node data is unavailable today
  (`docs/NETWORK_GRAPH.md`, corrected 2026-07-29) — establish whether that is a blocker before weighing a
  new backend, because enabling FTS5 is a build flag and a backend swap is not.

---

## 0.5 — THE LIVING CREATURES — PARKED

Does not begin until the planet is locked down. Plans: `docs/0.5_CREATURE_FEATURES.md`,
`docs/0.5_PARALLELIZATION_GUIDE.md`. Note the food web (item 9) has never been MEASURED and is the first thing to
establish, not the last.

## 0.6 — THE FULL SOLAR SYSTEM

Make the moving frame literal: migrate the GPU field to a body-local representation so the planet can
translate; planets, moons and sun as first-class bodies on real orbits; land on the moon; render the real
orbits; persist the orbital state.

---

## Where everything lives

- **Substrate:** `material/MaterialField3D.gd` (thin facade, **extract-only**) + `MaterialSphereGPU3D` ·
  `sphere_passes/*` · `kernels3d/*_sphere3d.glsl` (authoritative) · `MaterialReactions3D` (registry) +
  `material/reactions/` — six files: `ReactionDefs.gd` (the slot enum + record layout; note it has NO
  `Records` suffix, so the old `{ReactionDefs,Bio,Phase,Geo}Records.gd` glob named a file that does not
  exist), `BioRecords.gd`, `PhaseRecords.gd`, `GeoRecords.gd`, `CombustionRecords.gd` (R26) and
  `ReactionBalance.gd` (the gate, which lives in this directory rather than beside
  `PhysicalConstants.gd`) · `material/Substances.gd` (`LASubstances`, the SSOT for matter) ·
  `material/PhysicalConstants.gd` (`LAPhysical`) · the budget/probe/inventory modules.
- **The books:** `material/MaterialFieldSeal3D.gd` (SEEDING → SEALED, and the `world_seed` manifest) ·
  `MaterialFieldConservation3D.gd` (the gate, and its `DEBT` table — the SSOT for how far off each substance
  is) · `MaterialFieldLedger3D.gd` + `FieldLedgerFold3D.gd` / `FieldLedgerRecords3D.gd` / `FieldLedgerBooks3D.gd`
  (THE conservation ledger: H2O, mineral, moles and the thermal stock, from one probe read and one
  volume-weighted walk) · `MaterialFieldEnergyProbe3D.gd` / `MaterialFieldMineralProbe3D.gd` (per-pass
  attribution, heat and rock — a different question, and they stay separate).
- **Heat capacity, one definition per side of the GPU boundary:** `kernels3d/rc_shared.glsli` (GLSL) and
  `material/HeatCapacity.gd` (`LAHeatCapacity`, GDScript), held equal by `scripts/check_heat_capacity_ssot.sh`.
- **Composition root:** `game/VoxelWorld.gd` (**extract-only**) + `game/world/*`.
- **Actors:** `sim/actors/*`, `creatures/**`; disasters are seeds/visuals only. **Cognition:** `creatures/cognition/*`.
- **Reusable addon:** `agents/` (LocalAgent + Agent3D) · `runtime/` · `examples/`.

## North-star

Not restated here. `CLAUDE.md` holds it, and a second copy is a second thing to drift.
