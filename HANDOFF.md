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

### State (2026-08-08, end of session)

`0.4-dev` is at `1f1bd92`.

**THE SHAPE OF THE DATA WAS THE DEFECT, AND IT IS BEING FIXED.** A material's properties lived in five
places joined by naming convention — a dozen flat constants prefixed `WATER_`, a slot enum, a composition
dict, a mol_per_unit dict, and hand-copied literals in six kernels bound by comment. Four separate defects
came out of that one shape and each was patched alone before anyone saw they were the same thing: ignition
was a global because a fuel had nowhere to carry its own behaviour; minerals needed the lumped fiction `M`
so silicate weathering could not be written; a channel unit was not a mole and the gate did not know; and
latent heat was set at two reference temperatures at once.

**`material/Substances.gd` (`LASubstances`) IS THE SSOT NOW.** Every material declares its own measured
properties in ONE entry. `LAReactionBalance.composition()` and `.mol_per_unit()` are VIEWS of it through a
single `SLOT_SUBSTANCE` map. `PhysicalConstants.gd` keeps only what is not a property of a substance.
**Do not add a flat constant for something a material owns, and check the fact is not already there under
another name** — a duplicate molar mass was committed and reverted the same day.

**PHASE AND TEMPERATURE ARE DERIVED, NOT STORED — that is the direction, and only the table exists so far.**
`enthalpy_to_state()` returns both from energy and mass. Verified headless: ice at 0 °C and water at 0 °C
differ by exactly the latent heat of fusion, half-melted ice sits at exactly 0.0 °C, quarter-boiled water at
exactly 100.0 °C, round trip exact from −40 to 400 °C. **Latent heat becomes impossible to forget** because
the flat sections of the enthalpy curve are where the energy goes, and Hess's law becomes unviolatable
because sublimation is derived as fusion + vaporisation instead of declared.

**THE ROCK HAS A CHEMISTRY AND THE PLANET HAS A CARBON SINK.** Silicate CaSiO₃, silica SiO₂, carbonate
CaCO₃; Ca and Si join C/N/H/O. D1b is the real Urey reaction with CO₂ a REACTANT. Measured: 91.5 units of
carbon moved from air into rock in 600 frames, conservation drift 7.6e-5 of the pool. **D1c decarbonation
never fires** (threshold 280.7 °C derived from ΔH/ΔS; the hottest cell reaches 256 °C), so the sink is
one-way and a long `--geotime` run would strip the atmosphere.

**ENERGY HAS A STOCK AND A DRIFT GAUGE** (`LAMaterialFieldEnergyLedger3D`) and that number is Stage 1's
target: `energy_run_drift` **−1.163e16 J against `energy_stock_first` 1.548e17 — 7.5% of the planet's whole
thermal stock in 600 frames.** Read the TOTAL; `energy_run_steps` is 760, not `field_step` 590.

**ORGANIC MATTER GAINED A REAL DENSITY, so `element_*` changed scale by ~1951x.** Nothing measured before
`557a34b` is comparable on those keys. Decomposition and respiration are now hard oxygen-limited, which is
correct — a cell of air holds 0.27 kg of O₂ and a cell of wood is 500 kg, so a cell cannot oxidise its own
litter. **The bio RATE constants were fitted against the old stoichiometry and still need re-deriving.**

**COMBUSTION IS CHEMISTRY NOW.** `fire_sphere3d.glsl` is deleted (−298 lines) and with it `IGNITE_TEMP`,
`FIRE_START`, `FIRE_MIN`, `FIRE_GROW` and a private radiant-spread path. R26 is ARRHENIUS on cellulose's
measured pyrolysis activation energy, running the same oxidation R15 runs for decomposition, so ignition is
a thermal runaway rather than a branch. **It is under the conservation gate for the first time** — it was a
standalone kernel no record described, which is why it destroyed H, O and N for as long as it did.
Vegetation darkens the land (item 15, closed).

**HELD BACK, NOT MERGED: the bio-rate constants.** They were fitted against the old (wrong) stoichiometry
and still need re-deriving, but the attempt takes `biomass_total` from 5.175 to **0.002171** in isolation
and its own verifier found its single end-to-end check was a units error wrong by 2.8×. A 2400× collapse
may be the honest answer; it is not established as one. Branch `worktree-wf_094c4b16-05a-2`.

**THE SCAN FORCE-LOADS EVERY SCRIPT NOW.** It printed "OK (0 errors)" on a tree where
`WaterSlumpLavaPass.gd` failed to parse, and the sim then emitted a full `SIM_REPORT` at `field_step` 590
with a whole transport CA silently not running. It reports **"318 scripts force-loaded, 0 parse errors"** —
a marker whose PRESENCE means something, rather than the absence of a pattern.

**THE BASELINE, at `1f1bd92`,** `--sandbox --planet-only --run-frames=600 --fast=8 --seed=4242`,
`field_step` 590 / `field_sim_s` 79.8: `temp_ground_p50` 26.52 · `temp_mean` 35.32 · `snow_cells` 1162 ·
`biomass_total` 5.217 · `soil_total` 2797 · `element_C` 1.095e7 · `magma_cells` 6 ·
`energy_run_drift_per_step` −1.559e13.

**AND THE PLANET IS STILL RUNNING AWAY, WHICH 600 FRAMES HIDES.** Measured on the pre-session tree:
`temp_ground_p50` 30 °C at 600 frames, **61.8 °C at 1200**. Thirty degrees was never an equilibrium, it
was an early point on a ramp. Any claim about where this planet settles needs 4000+ frames, and Stage 3
cannot be answered at 600.

---

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

**In a fresh worktree, in this order, or your measurements are fiction:** symlink the GDExtension binaries —
`ln -s <primary>/addons/local_agents/gdextensions/localagents/bin <worktree>/addons/local_agents/gdextensions/localagents/bin`,
NOT a `bin/` at the repo root, which does not exist — then
`godot --headless --path . --import`, then `scripts/editor_scan.sh` — always, because a fresh worktree has no
class cache. Never a bare `godot --headless --editor`; two concurrent scans segfault.

**Gates:** `scripts/agent_harness.sh lint` is what CI runs, and includes `check_physical_constants.sh` and
`check_reaction_balance.sh`. **Instruments:** `LA_SOIL_BUDGET=1`, `LA_H2O_BUDGET=1`, `LA_MINERAL_BUDGET=1`,
`LA_MINERAL_PROFILE=1` (the only one that answers "did it move DOWNHILL", which no total can).
**`LA_H2O_BUDGET` and `LA_MINERAL_BUDGET` are MUTUALLY EXCLUSIVE** — they share the driver's one
`set_step_probe` slot, and `MaterialFieldSphereStep3D.gd:100-103` push-warns and silently keeps the mineral
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

*(Items 1–5 were all corrected or closed on 2026-08-07/08. What they SAID is kept, briefly, because two of
them sent work at problems that no longer existed and one of them was the file's headline claim.)*

1. ~~THE OCEAN IS A THERMOSTAT~~ — **FALSE, and it was already false when it was written.** It said
   `heat3d_cool_sphere3d.glsl:47-50` "holds the sea near a fixed temperature … the single largest remaining
   fiction". That kernel was rewritten on 2026-08-03, the same day this entry was; `sea_water_target()`,
   `SST_SURFACE` and `WATER_TEMP_DEEP` are all gone and its own header documents each deletion. **Stage 3's
   "kill the ocean thermostat first" was already done.**
2. ~~THE SEA HAS ~0.93 m OF THERMAL INERTIA~~ — **FALSE.** The four areal `CAP_*` literals are deleted;
   capacity is `ρc × cell_size` = **16 m** of water. The honest remaining gap is that a real mixed layer is
   20–100 m, and the fix is MORE CELLS, not a bigger literal — `heat3d_solar_sphere3d.glsl:154-158` says so.
3. ~~BURNING CELLS ARE PINNED TO 640 °C~~ — **FALSE for the pin and the carbon**, and the kernel it used to
   cite is gone. *(Re-cited 2026-08-09; it read "since `fire_sphere3d.glsl:190`".)* Combustion is a REACTION
   RECORD now — `reactions/CombustionRecords.gd` R26, ARRHENIUS on cellulose's measured pyrolysis activation
   energy — so `fire_sphere3d.glsl` is deleted with its `IGNITE_TEMP`, `FIRE_START`, `FIRE_MIN`, `FIRE_GROW`,
   the stored `fire` intensity and its radiant-spread gather. It also brings combustion under
   `check_reaction_balance.sh`, which is why it destroyed H, O and N for as long as it did: no record
   described it, so no gate could see it.
4. ~~SPRING HEAT HAS NO DONOR~~ — **CLOSED.** Cold recharge now cools the rock it soaks into, and the mix is
   capacity-weighted. `hotspring_boiling` 107 → 51. **What is still unpaid is the regolith→regolith DARCY
   leg**, disclosed in `soil_sphere3d.glsl:51`.
5. ~~THE SOIL KERNEL INVENTS WATER~~ — the regolith clamp is instrumented (`DBG_CLAMP_GAIN`) and
   `kernel_residual` reads 0.0. **A second clamp at `soil_sphere3d.glsl:499` on the `water[g]` leg is still
   uninstrumented.**

### Missing physics — a real mechanism simply is not there

6. **NO LATENT HEAT — and the fix is now structural rather than a charge.** *(Rewritten 2026-08-08.)* The
   record-enthalpy branch (`worktree-wf_c468d92c-702-2`) is SUPERSEDED and should not be merged: it
   attached a latent heat to each of six phase-change records, which is a number six places can get wrong
   and which one of them did — L_vap at 100 °C paired with L_fus at 0 °C, releasing 2.433e5 J/kg from
   nothing per traverse. `LASubstances.enthalpy_to_state()` makes it unforgettable instead: phase is a
   function of energy, so the latent heat is WHERE THE ENERGY SITS on the curve and no kernel can skip it.
   **What is left is the migration** — store energy per cell, derive temperature, and collapse
   `water`/`moisture`/`snow` into one conserved `h2o`. That deletes R21, R22, R23, R24, R25, the snowice
   deposition kernel and the rain condensation leg.
7. **NO MANTLE CONVECTION.** The geotherm is a seeded initial condition maintained by a reservoir. A real
   planet's interior circulates, and that circulation is what drives plate motion, so the plates below are
   kinematic rather than driven.
8. **TWO MASS TRANSFERS STILL MOVE TEMPERATURE WITHOUT MOVING HEAT.** *(Corrected 2026-08-08. This said
   "EVERY inter-cell transfer", which is false and expensive: three kernels already carry enthalpy with the
   mass and two say so in their own headers — `lava_flow_sphere3d.glsl:140-151` gathers `inflow_heat` as a
   mass-weighted donor sum, `magma_buoy_sphere3d.glsl:39` mixes arriving enthalpy into the destination, and
   `soil_sphere3d.glsl:35-37` is a capacity-weighted mix. A session acting on the old wording re-plumbs
   three kernels that are already right and misses the two that are not.)* The real cases:
   **the regolith→regolith Darcy leg**, disclosed at `soil_sphere3d.glsl:51`, and **sediment slump**, which
   `slump_sphere3d.glsl:6` marks "NO carry-heat".
9. **ROCK HAS THREE COMPOSITIONS AND NO STRATIGRAPHY, AND ORGANIC MATTER HAS ONE.** Minerals are
   speciated (silicate / silica / carbonate) and the Urey reaction balances, but carbonate and silica do
   not travel and do not lithify, so there is no limestone and no sandstone; `solid` derives from
   `rock_fill`, so splitting it reaches solidity, overburden, plate advection and the mineral stamp, and
   per-species SUSP/DUST/erosion/slump follow. **Organic matter is still ONE lumped CH₂O** — which is why
   ignition is one number, and why this planet cannot have peat even though it demonstrably BURIES
   organics (`carbon_buried` ~290 units per run).
10. **WHETHER THE FOOD WEB WORKS IS UNMEASURED — and the two gauges this entry cited cannot answer it.**
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

11. **PLATE TECTONICS IS KINEMATIC VORONOI.** Plate boundaries are prescribed and rotate; the crust now
    genuinely advects with them, but the plates themselves are not a consequence of convection dragging a
    brittle shell until it cracks. *(Maintainer has explicitly OK'd faking this one — true geodynamics is
    research-grade. `GEOLOGIC_TIME_ACCELERATION = 3.0e5` is the knob, set by measurement, in
    `PlateTectonics.gd:67`.)*
12. **BREEDING HAS A GLOBAL `pop_cap` CEILING, AND SPACE DOES NOT REGULATE IT.** *(Narrowed 2026-08-08. It
    said "rather than population regulated by food, energy and space", and food and energy DO regulate it
    now: `EcologyBreeding.gd:188-191` refuses to spawn below `SPAWN_ENERGY_FLOOR` and charges
    `SPAWN_ENERGY_FRAC` of the parent's maximum, and `:171-175` multiplies the birth count by a biomass food
    gate. The cap at `:160-163` sits on top of those as a hard ceiling.)* Space is the unregulated one.
    Cited as `:23,29` before, which are prose lines inside a comment block.
13. **THE DAY IS A GAME NUMBER.** `SimClock.DAY_LENGTH = 200.0` against a field step of 43.2 real seconds and
    a separate `PLANET_SPIN_RATE`. Earth's day is 86400 s. Three clocks that do not derive from one rotation.
14. **THE PLANET IS PINNED AT THE WORLD ORIGIN** and the sun moves around it (`SystemOrbits.gd:228`). A
    deliberate moving-frame choice; making it literal is the 0.6 headline.
15. ~~VEGETATION DOES NOT AFFECT ALBEDO~~ — **CLOSED 2026-08-09.** A forest is darker than the sand it
    grows on, and the solar kernel now folds vegetation cover into surface albedo beside `wet` and `icy`,
    so the biological half of the ice-albedo feedback exists. `LAPhysical.ALBEDO_VEGETATION` = 0.12.
### Instruments that lie

16. ~~`magma_cell_count()` / `magma_erupting()` are hardcoded~~ — **FALSE, they are live**
    (`MaterialFieldQueries3D.gd:539-570`, one cached walk). The real remaining defect is different and
    narrower: `molten_counts()` reads the `_f._lava` **CPU mirror**, and `lava` is demand-gated
    (`SITUATIONAL_CHANNELS`), so between eruptions the gauge can read a stale mirror and report 0 with no
    provenance flag — exactly what `mass_live` exists to prevent for the element inventory.
17. **The element inventory has no per-pass attribution.** It reports that carbon moved, not which reaction
    moved it. The mineral probe already does this and found a leak in one run by naming `fire_dust`.
18. **A GAUGE THAT SUMS OPEN CELLS ONLY IS NOT A CONSERVATION GAUGE**, and at least one still is:
    `MaterialFieldQueries3D.gd:624-631` (`fuel_total`). This is what made nitrogen look like it was being
    destroyed at 32% per run when it was being buried. Any total used to answer "was matter created or
    destroyed" needs its mask-free twin.

---

## DO THIS NEXT — the staged plan

Each stage has its own verification. Do not merge stages.

**STAGE 1 — stop the sim creating matter and energy.** *(most of the way; the instrument now exists, which
is what changed.)* The balance gate, the element inventory and the composition table all landed before this
session; the kernel violations 1/3/4/5 are closed. **What is left is one number:** the planet lost
`energy_run_drift` = **−1.163e16 J against an `energy_stock_first` of 1.548e17 — 7.5% of its whole thermal
stock in 600 frames.** Drive it toward zero. The ledger names its own unbooked terms in its header; work
that list. Then latent heat (item 6), the largest single missing term.

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

## 0.5 — THE LIVING CREATURES — PARKED

Does not begin until the planet is locked down. Plans: `docs/0.5_CREATURE_FEATURES.md`,
`docs/0.5_PARALLELIZATION_GUIDE.md`. Note the food web (item 10) has never worked and is the first thing to
establish, not the last.

## 0.6 — THE FULL SOLAR SYSTEM

Make the moving frame literal: migrate the GPU field to a body-local representation so the planet can
translate; planets, moons and sun as first-class bodies on real orbits; land on the moon; render the real
orbits; persist the orbital state.

---

## Where everything lives

- **Substrate:** `material/MaterialField3D.gd` (thin facade, **extract-only**) + `MaterialSphereGPU3D` ·
  `sphere_passes/*` · `kernels3d/*_sphere3d.glsl` (authoritative) · `MaterialReactions3D` (registry) +
  `reactions/{ReactionDefs,Bio,Phase,Geo}Records.gd` + `ReactionBalance.gd` (the gate) ·
  `PhysicalConstants.gd` (`LAPhysical`) · the budget/probe/inventory modules.
- **Composition root:** `game/VoxelWorld.gd` (**extract-only**) + `game/world/*`.
- **Actors:** `sim/actors/*`, `creatures/**`; disasters are seeds/visuals only. **Cognition:** `creatures/cognition/*`.
- **Reusable addon:** `agents/` (LocalAgent + Agent3D) · `runtime/` · `examples/`.

## North-star

Not restated here. `CLAUDE.md` holds it, and a second copy is a second thing to drift.
