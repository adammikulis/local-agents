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

### State (2026-08-09, late)

`feature/heat-capacity-ssot` is seven commits off `0.4-dev` at `541897d`, **not merged**. In order:
`b5f8e04` per-pass energy probe · `347495f` heat capacity counts every carrier · `db22352` the SSOT gate ·
`27b2795` the soil clamp gauge · `92ae453` rock_fill is a saturation · `b436129` the world seal ·
`5e1303f` the mole-based carbon gauge.

**THE WORLD HAS TWO PHASES NOW, AND EVERY DRIFT NUMBER BEFORE THIS IS SUSPECT.**
`LAMaterialFieldSeal3D` — SEEDING until the bootstrap has run and every matter/energy channel has actually
been delivered, then SEALED. All eleven conservation baselines latch AT the seal (field_step 9) instead of at
"the third heavy sample", which was a sampling artifact landing in the middle of seeding. Two things that
artifact was doing, both measured: it counted the planet being BUILT as drift, and it let a baseline be
latched through a channel that had not arrived — `energy_stock_first` came out bit-identical on two arms
whose regolith heat capacity differs by 29%.

**`world_seed` IS THE SCOREBOARD.** Everything in it is something the substrate was TOLD rather than worked
out: `carbon 1354.8 · h2o 5300.5 · o2 36524.8 · mineral 31978.0 · energy 1.673e17 · temp_ground_p50 15.0`.
That last is exactly `INITIAL_TEMP`. **The bar is a post-Theia seed** — a molten body and a bulk composition,
with ocean, atmosphere and crust all OUTPUTS — so progress is these entries being DELETED, each with the
acceptance test that the thing it asserted now emerges. Order: sea, lakes, water table, `INITIAL_TEMP`.

**ENERGY DRIFT 12.77% -> 7.76% of stock**, three runs per arm. `rc_of` counted seven carriers out of the
fifteen that hold matter; `soil`, `sediment`, `susp`, `dust`, `moisture`, `fungus`, `carbonate` and `silica`
were thermally invisible, so every gram crossing into one deleted its own heat capacity. Measured by the new
probe: the CAPACITY leg was -6.64e14 J against a heat leg of -3.14e14, and `erosion_pickup` read -9.79e14
**while writing no temperature at all** — scoured bedrock ceasing to exist thermally on entering the river.

**A RAW CHANNEL SUM IS A CONSERVATION GAUGE ONLY IF EVERY CHANNEL IN IT HOLDS ONE SUBSTANCE IN ONE UNIT.**
`carbon_total` summed co2 + biomass + detritus units and read **+1261%**; `element_C_total` in MOLES reads
**-10.7%**. The sign is different. Carbon is being destroyed, not created, and every previous statement to
the contrary — including the plan CLAUDE.md records, to fix a shortage by adding a source — was reading a
number that is not a quantity. `h2o_total` and `mineral_total` are legitimate raw sums; anything spanning
substances must go through `mol_per_unit`.

### Conservation, measured from the seal (seed 4242, --planet-only --no-fauna, field_step 290)

| substance | change | note |
|---|---|---|
| mineral | **-0.02%** | the only one with per-pass attribution, and the only one that conserves |
| nitrogen | -1.75% | |
| **element_C (moles)** | **-10.74%** | the honest carbon gauge |
| h2o | -17.79% | |
| oxidant | -29.01% | |
| o2 | -76.65% | |
| energy | -7.76% | booked terms ~0, so essentially all of it is unbooked |

Every sanctioned mint counter is 0.0 (`h2o_inject_minted`, `mineral_inject_minted`, `biotic_inject_minted`,
`heat_inject_unsourced_dc`, `crater_mass`), so none of this arrives through an injection seam.

**MINERAL CONSERVES AND THE OTHERS DO NOT, AND THAT IS NOT A COINCIDENCE:** mineral is the only substance
with a PER-PASS probe. Every other one has a global total, which says a number moved and never where.

---

## HOW GOOD IS IT? — `PHYSICS_RUBRIC.md`, scored 7/24 on 2026-08-09

Six criteria with a dated score history; `scripts/physics_score.sh` computes the measurable half. Three
audits (constants, reaction engine, kernels) produced the counts behind criteria 3, 4 and 6. The ordering
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

**Gates:** `scripts/agent_harness.sh lint` is what CI runs, and includes `check_physical_constants.sh` and
`check_reaction_balance.sh`. **Instruments:** `LA_SOIL_BUDGET=1`, `LA_H2O_BUDGET=1`, `LA_MINERAL_BUDGET=1`,
`LA_MINERAL_PROFILE=1` (the only one that answers "did it move DOWNHILL", which no total can).
**`LA_H2O_BUDGET` and `LA_MINERAL_BUDGET` are MUTUALLY EXCLUSIVE** — they share the driver's one
`set_step_probe` slot, and `MaterialFieldSphereStep3D.gd:100-106` push-warns and silently keeps the mineral
one. Do not read a run that armed both as if both reported.

- **Three runs per arm**, quoting `phenomenon`/`impact`/`eruption`/`bolts` — residual spread is discrete and
  disaster-driven. Compare at equal `field_sim_s`, never equal `--run-frames`.
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
   how much", which was true. `DBG_OPEN_CLAMP_GAIN` now mirrors the regolith twin; six samples over 300
   frames read `open_clamp_gain` 0.0000 throughout, with `clamp_gain` 0.0000 beside it. The clamp exists and
   never binds. **The gauge was mutation-tested before that zero was believed** — forcing it to bind reads
   342.38 / 364.96 / 368.77 — because a gauge never seen to move is a gauge nobody has tested.

4. **NOTHING KEEPS SNOW ON THIS PLANET, AND THAT WAS INVISIBLE UNTIL THE HEAT CAPACITY WAS FIXED.**
   `snow_cells` fell **1170 → 76** the moment `heat3d_cool` started counting snow in its heat capacity.
   That kernel — the one whose entire job is radiative cooling — had no snow term, so a snowpack cell read
   as ~1186 J/m³K (air) instead of 6.27e5 (snow): **a 500× under-estimate of what it takes to warm snow.**
   Snow was trivially cold-able and therefore persisted. This is the band-aid-removal test coming out the
   wrong way round — the clamp came out and the phenomenon it was propping up went with it. 76 cells is what
   this planet's climate actually supports at 600 frames; 1170 was an artefact, and **every snow, ice-albedo
   and treeline claim measured before 2026-08-09 was measured against it.** Deciding whether 76 is right:
   this planet has no seasons deep enough and no orographic lift to speak of, so the question is whether
   snow should persist at all at `temp_ground_p50` 25 °C — which is Stage 3's asymptote question, not a
   snow-kernel question. Do not "fix" it by moving a constant.

### Missing physics — a real mechanism simply is not there

5. **NO LATENT HEAT — and the fix is now structural rather than a charge.** *(Rewritten 2026-08-08.)* The
   record-enthalpy branch (`worktree-wf_c468d92c-702-2`) is SUPERSEDED and should not be merged: it
   attached a latent heat to each of six phase-change records, which is a number six places can get wrong
   and which one of them did — L_vap at 100 °C paired with L_fus at 0 °C, releasing 2.433e5 J/kg from
   nothing per traverse. `LASubstances.enthalpy_to_state()` makes it unforgettable instead: phase is a
   function of energy, so the latent heat is WHERE THE ENERGY SITS on the curve and no kernel can skip it.
   **What is left is the migration** — store energy per cell, derive temperature, and collapse
   `water`/`moisture`/`snow` into one conserved `h2o`. That deletes R21, R22, R23, R24, R25, the snowice
   deposition kernel and the rain condensation leg.
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
    now: `EcologyBreeding.gd:188-191` refuses to spawn below `SPAWN_ENERGY_FLOOR` and charges
    `SPAWN_ENERGY_FRAC` of the parent's maximum, and `:171-175` multiplies the birth count by a biomass food
    gate. The cap at `:160-163` sits on top of those as a hard ceiling.)* Space is the unregulated one.
    Cited as `:23,29` before, which are prose lines inside a comment block.
12. **THE DAY IS A GAME NUMBER.** `SimClock.gd:29` `DAY_LENGTH = 200.0`, against a field step whose 43.2
    real seconds are DERIVED from it (`MaterialFieldSphereStep3D.real_seconds_per_step()`, `:39-44`) and a
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
    rain half is built (`RAIN_WASH = 0.30`). `GAS_SETTLE = 0.05` is also a hardcoded buoyancy share when
    `LASubstances` already carries the molar masses it should derive from (CO₂ 44.01 vs air 28.96).
    **The fix is one parameterised solver** — `{diffuse, advect, settle, out_max, decay, rain_wash,
    channels}` — replacing all three (~356 lines → ~200), which also absorbs `dust_outscale_sphere3d.glsl`
    (96 lines computing the CFL scale `co2_transport` computes inline in `out_scale()`). Sequence it:
    unify AT PARITY first (advect 0 for O₂/scent) so the refactor A/Bs as a no-op, then turn the wind on as
    its own measured commit. NOT candidates: `atmos_transport` (condensation-coupled H₂O),
    `erosion_transport` (on the settled list), `dust_transport`'s leeward deposition.

### Instruments that lie

15. **`molten_counts()` CAN REPORT ZERO FROM A STALE MIRROR WITH NO PROVENANCE FLAG.** It reads `_f._lava`
    and `_f._solid` (`MaterialFieldQueries3D.gd:552-560`), and `lava` is demand-gated
    (`MaterialSphereGPU3D.SITUATIONAL_CHANNELS:198-199`), so between eruptions the gauge cannot tell "no
    lava" from "the channel never arrived" — exactly what `mass_live` exists to prevent for the element
    inventory (`MaterialFieldElementInventory3D.gd:283`). `magma_cell_count()` and `magma_erupting()`
    delegate to it, so all three inherit it. *(This entry used to claim those two were HARDCODED. They are
    live, and have been: `MaterialFieldQueries3D.gd:531-576`, one cached walk behind a `_molten_step`
    guard.)* Deciding it: give `molten_counts()` the same provenance flag and read it on a run with no
    eruption.
16. **The element inventory has no per-pass attribution.** It reports that carbon moved, not which reaction
    moved it (`MaterialFieldElementInventory3D.gd:262-280`). The mineral probe already does this and found a
    leak in one run by naming `fire_dust` (`MaterialFieldMineralProbe3D.gd:50`).
17. **`fuel_total()` IS THE LAST MASKED CONSERVATION TOTAL.** *(Narrowed 2026-08-09. It read "A GAUGE THAT
    SUMS OPEN CELLS ONLY IS NOT A CONSERVATION GAUGE, and at least one still is … Any total used to answer
    'was matter created or destroyed' needs its mask-free twin" — and the twins landed on 2026-08-08.
    `MaterialFieldElementInventory3D.gd:278-279` publishes `fuel_open_total` beside `fuel_all`, and every
    element-inventory leg now carries an `_all`. What is left is one gauge, not a class of them.)*
    `MaterialFieldQueries3D.gd:639-646` still gates on `_f._solid[c] == 0`, and it is what `SIM_REPORT`
    publishes as `fuel_total` (`MaterialFieldReport3D.gd:306`) — so the number a reader sees is the masked
    one while the mask-free twin sits in another module under another name. *(Cited as `:624-631` before,
    which is `mineral_total()`'s doc comment.)* The other `solid[c] == 0` gates in that file (`:216`,
    `:423`, `:736`) are shell-mean, flow and fertility diagnostics — not conservation gauges, and correctly
    masked. Deciding it: publish the twin beside it, or make `fuel_total` the unmasked one and rename the
    masked reader.
18. **`fire_peak` READS 0.0 THROUGH RUNS WHERE COMBUSTION IS RUNNING, AND NOBODY KNOWS WHICH ZERO IT IS.**
    `fire` is in `MaterialSphereGPU3D.SITUATIONAL_CHANNELS`, so its CPU mirror is only fetched on demand —
    the same defect as item 13, on a different channel. Measured 2026-08-09 over six 600-frame `--no-fauna`
    runs: `fire_cells` 0 and `fire_peak` 0.0 in every one, while `fuel_total` fell from a seeded 216 to
    ~152, which is fuel being consumed by something. **A gauge that cannot distinguish "nothing burned"
    from "the channel never arrived" cannot verify any change to combustion**, and that is precisely what it
    was asked to do this session. Deciding it: give `fire_peak` the `mass_live` provenance treatment, then
    re-read it on a run with a known fire.

---

## DO THIS NEXT — the staged plan

Each stage has its own verification. Do not merge stages.

**DO THESE FIRST, in this order. They are what the seal made askable.**
1. **PER-PASS ATTRIBUTION FOR MATTER**, the way `LAMaterialFieldEnergyProbe3D` now does it for heat and
   `LAMaterialFieldMineralProbe3D` already did for rock. Mineral is the only substance that conserves and the
   only one with a per-pass probe; that is the whole lesson. Point the same shape at the element inventory and
   carbon / oxygen / water each name their pass in one run instead of being argued about.
2. **LATENT HEAT BECOMES STRUCTURAL** (`LASubstances.enthalpy_to_state`, energy stored per cell, phase
   derived). Nothing else unblocks a post-Theia seed: `atmos_precip_sphere3d.glsl` condenses vapour to rain
   for free and `snowice_sphere3d.glsl` freezes it for free, and an ocean condensing out of a steam
   atmosphere IS a latent-heat process. Do NOT take `feature/latent-heat` (`ae1a497`) — it attaches a latent
   heat to each of six records and pairs L_vap at 100 C with L_fus at 0 C, releasing 2.433e5 J/kg per traverse.
3. **THEN DELETE SEED ENTRIES**, one at a time, each with the acceptance test that the thing it asserted now
   emerges. Watch the line vanish from `world_seed`.

**STAGE 1 — stop the sim creating matter and energy.** *(most of the way; the instrument now exists, which
is what changed.)* The balance gate, the element inventory and the composition table all landed;
the kernel violations that used to head this list are closed. **What is left is one number:** the planet
lost `energy_run_drift` = **−1.163e16 J against an `energy_stock_first` of 1.548e17 — 7.5% of its whole
thermal stock in 600 frames.** Drive it toward zero.

**The work queue is the ELEVEN unbooked terms the ledger names in its own header**
(`MaterialFieldEnergyLedger3D.gd:76-130`) — read it there rather than copying it here, because it cites the
exact line of each leak. It is not ordered by size. **Item 11 is now CLOSED and it cost only 2.5% of the
drift**, so do not expect the rest to be cheap either: that was `rc_of` not being a function of the matter
present, and unifying five copies into `kernels3d/rc_shared.glsli` moved the number very little while
changing the planet a lot (see item 4). **ITEM 10 IS THE ONE TO TAKE NEXT:**

- ~~**#10 — GROUNDWATER HAS NO HEAT CAPACITY**~~ **— CLOSED, AND IT WAS THE LARGEST OF EIGHT, NOT THE ONLY
  ONE.** `soil` was invisible to `rc_of`, and so were `sediment`, `susp`, `dust`, `moisture`, `fungus`,
  `carbonate` and `silica`. All eight are counted now and the drift fell 12.77% -> 7.76%. #9 (the injection's
  private capacity model) went with it: there is ONE GDScript definition, `material/HeatCapacity.gd`, gated
  by `scripts/check_heat_capacity_ssot.sh`. The old text follows for the reasoning, which still reads well:
- **#10 (original text) — GROUNDWATER HAS NO HEAT CAPACITY, AND IT IS MOST OF THIS PLANET'S WATER.** `rc_of` counts the
  `water` channel and not `soil`, and `soil` is the aquifer: `soil_total` ~2830 against `water_total` ~1310.
  More than twice as much of this world's water is thermally invisible as is visible, and a unit of water
  that infiltrates from the surface deletes its own thermal mass from the planet. The ledger's own note:
  *"This gauge was built to find unbooked terms and this is the one it found."* **Now that there is exactly
  one `rc_of`, adding `soil` to it is a one-line change in one file** — which is the point of having
  unified it. The cost is that the aquifer's carriers must be bound into every kernel that includes it, the
  same way lava/fuel/biomass/detritus were.
- **#9 got WIDER, not narrower.** `MaterialFieldInject3D._cell_heat_capacity` mixes water and air only,
  against a shared `rc_of` that now also counts lava, snow and organic. It cannot call the shared definition
  because that is GLSL and this is GDScript — so it is a THIRD transcription waiting to drift. Either derive
  both from `LASubstances` or delete the injection's private model.

Then latent heat (item 5), the largest single missing term.

> **READ THE TOTAL, NOT THE RATE TIMES A STEP COUNT.** *(Corrected 2026-08-08. This said "1.07e-4 per step,
> 6.3% over 590 steps", which multiplied `energy_run_drift_per_step` by `field_step`. Those are different
> clocks: the ledger divides by `energy_run_steps` — 760 in the same run, because it starts counting at
> `energy_first_step` 29 and its own sampling cadence is not the field's. The instrument publishes
> `energy_run_drift` as an absolute; use it.)*

**Verified by one question, and it is now askable:** does the planet still create energy, yes or no.
Before this session nothing in the repository could answer it — every climate claim was argued from
temperature, which is a state variable and tells you where the planet HAS got to, never why.

**STAGE 2 — seed a primordial planet.** Post-magma-ocean Hadean, ~4.4 Ga: hot surface, thick CO₂/N₂
atmosphere, water still largely steam, **no free O₂** (it is a product of life), no biosphere. **Oceans must
CONDENSE, not be placed.** Delete `INITIAL_TEMP = 15.0` and every "partway" seed. Source and cite the
composition, and name the era. **Uninhabitable for a whole run is an acceptable result.** `6ad2417` is a
start on this.

**STAGE 3 — does it cool, and where does it settle?** *(Its first sentence used to read "Kill the ocean
thermostat first, or the books cannot close." THE THERMOSTAT WAS ALREADY DEAD when that was written — see
item 1 — and following it costs a session on a non-problem. What actually has to come first is Stage 1's
energy drift, because a planet losing 7.5% of its thermal stock per 600 frames has no settling point to
find.)* Run 4000–6000 frames; watch `temp_ground_p50` for an asymptote and `snow_cells` for an ice-albedo
runaway. **Do not tune the solar constant** — 1361 W/m² is a measured fact.

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
- the DEFS record engine's std430 layout (`ReactionDefs.gd:211`, 144 bytes);
- the neighbour / tangent tables (`SphereGrid.gd:115-116`);
- the soil budget's per-leg identity (`kernel_residual` exactly 0.0, `MaterialFieldSoilBudget3D.gd:186`);
- the erosion transport law — no fitted constant, load moves in the same proportions as the water carrying
  it (`erosion_transport_sphere3d.glsl:18-23`);
- the geotherm as a seeded initial condition with a derived vertical scale (`MaterialFieldGeotherm3D.gd:25-41`);
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
- **Composition root:** `game/VoxelWorld.gd` (**extract-only**) + `game/world/*`.
- **Actors:** `sim/actors/*`, `creatures/**`; disasters are seeds/visuals only. **Cognition:** `creatures/cognition/*`.
- **Reusable addon:** `agents/` (LocalAgent + Agent3D) · `runtime/` · `examples/`.

## North-star

Not restated here. `CLAUDE.md` holds it, and a second copy is a second thing to drift.
