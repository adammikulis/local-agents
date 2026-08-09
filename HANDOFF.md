# TODO / Roadmap — Local Agents (voxel-planet caretaker sim)

**This file is the map of what is LEFT. It is not a history.** A finished item is deleted the moment it is
committed; git is the record of what was done. When an entry is FALSE, fix it in place and say what it
claimed, so nobody re-derives the same wrong conclusion.

**MAINTAINER'S RULE: this file and `CLAUDE.md` may not be changed without his approval.**

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

### State (2026-08-03, end of session)

`0.4-dev` is the integration branch. Merged today: the LOD deletion (−505 lines), the aquifer's capillary
retention, sediment transport, the seeded geotherm, one phase rule for all water, and metabolism dissolved
into the substrate's own respiration reaction.

**IN FLIGHT, NOT MERGED — do not start work that touches these:**
- `feature/conservation` (19 commits) — the balance gate, the element inventory, `RELAX_TARGET` deleted.
  **Resolved against `0.4-dev` on `integrate/conservation` but NOT landed**, because it carries a metabolism
  model the maintainer decided against. Its tip `6ad2417` is pre-biotic seeding, deliberately separate.
- A re-anchoring of the creature conservation fixes onto the emergent mass model (the maintainer's decision:
  keep emergent Rubner scaling, feed it conservation's measured `mass_kg`).
- A kernel pass on combustion, spring heat, the soil kernel's invented water, and the magma stubs.
- `55cda84` — latent heat, committed and deliberately unmerged. Charging honest enthalpies shows this
  planet's water cycle runs **~4500× too fast** and the surface reaches −131 °C. That is a decision about the
  iteration loop, not a bug fix.

**THE BASELINE IS VOID.** Crust now moves, water obeys a real saturation curve, and metabolism is a
substrate reaction. Nothing measured before today is comparable to anything measured after. Re-establish it.

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

**In a fresh worktree, in this order, or your measurements are fiction:** symlink `bin/`, then
`godot --headless --path . --import`, then `scripts/editor_scan.sh` — always, because a fresh worktree has no
class cache. Never a bare `godot --headless --editor`; two concurrent scans segfault.

**Gates:** `scripts/agent_harness.sh lint` is what CI runs, and includes `check_physical_constants.sh` and
`check_reaction_balance.sh`. **Instruments:** `LA_SOIL_BUDGET=1`, `LA_H2O_BUDGET=1`, `LA_MINERAL_BUDGET=1`,
`LA_MINERAL_PROFILE=1` (the only one that answers "did it move DOWNHILL", which no total can).

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

1. **THE OCEAN IS A THERMOSTAT.** `kernels3d/heat3d_cool_sphere3d.glsl:47-50` holds the sea near a fixed
   temperature. It does not participate in the energy balance at all, so **the global energy books cannot
   close while it exists**, and "where does the planet settle" is unanswerable. This is the single largest
   remaining fiction.
2. **THE SEA HAS ~0.93 m OF THERMAL INERTIA** where a real ocean has 20–100 m. Rock lands at 0.248 m against
   a derived diurnal skin depth of 0.168 m, which is fine; water is wrong by one to two orders. It is why the
   planet has no thermal memory between day and night.
3. **BURNING CELLS ARE PINNED TO 640 °C** and combustion destroys half its carbon. A fire's temperature
   should be a result of combustion enthalpy against heat capacity and losses. *(In flight.)*
4. **SPRING HEAT HAS NO DONOR** — geothermally warmed groundwater arrives hot and the rock never cools by
   what it gave up. *(In flight.)*
5. **THE SOIL KERNEL INVENTS WATER** on a `max(0.0, raw)` clamp — flooring a negative silently creates the
   difference. *(In flight.)*

### Missing physics — a real mechanism simply is not there

6. **NO LATENT HEAT.** Evaporation does not cool and condensation does not warm, anywhere. This is the
   biggest single omission in the water cycle, and the branch that adds it (`55cda84`) shows why it was
   never noticed: with honest enthalpies the cycle runs **~4500× too fast** and the surface hits −131 °C. The
   current water cycle is fast *because* it is free.
7. **NO MANTLE CONVECTION.** The geotherm is a seeded initial condition maintained by a reservoir. A real
   planet's interior circulates, and that circulation is what drives plate motion, so the plates below are
   kinematic rather than driven.
8. **NO ENTHALPY ON MASS TRANSFER.** Every inter-cell transfer moves temperature without moving heat
   capacity, so mixing two cells does not conserve energy.
9. **ROCK HAS THREE COMPOSITIONS AND NO STRATIGRAPHY.** *(Narrowed 2026-08-08. It read "ROCK HAS ONE
   COMPOSITION ... a single undifferentiated `rock_fill`", which was true and is the defect the Urey
   reaction had to fix first.)* There are now three species — silicate CaSiO₃, silica SiO₂, carbonate CaCO₃ —
   and weathering converts between them. What is still missing: no ore, no strata, no differentiation, no
   granite/basalt distinction, and **no sedimentary rock**. Carbonate and silica are loose own-cell stocks
   that neither travel nor lithify, so there is no limestone and no sandstone; adding them means splitting
   `rock_fill`, and `solid` derives from `rock_fill`, so that reaches solidity, overburden, plate advection
   and the mineral stamp. Per-species SUSP/DUST would then follow, and with them per-species erosion, slump
   and dust transport. That is the next increment and it is a large one.
10. **THE FOOD WEB HAS NEVER WORKED.** `death/eaten` is 0 and `biota_node_intake` 0.00 in **every** arm
    including the untouched baseline — predation appears never to have functioned. The free `ambient_graze`
    food source hid it for as long as it existed.

### Prescribed where it should emerge

11. **PLATE TECTONICS IS KINEMATIC VORONOI.** Plate boundaries are prescribed and rotate; the crust now
    genuinely advects with them, but the plates themselves are not a consequence of convection dragging a
    brittle shell until it cracks. *(Maintainer has explicitly OK'd faking this one — true geodynamics is
    research-grade. `GEOLOGIC_TIME_ACCELERATION = 3.0e5` is the knob, set by measurement, in
    `PlateTectonics.gd:67`.)*
12. **BREEDING IS A POPULATION TICK WITH A `pop_cap`**, at least for aquatic species — a global ceiling
    rather than population regulated by food, energy and space. `EcologyBreeding.gd:23,29`.
13. **THE DAY IS A GAME NUMBER.** `SimClock.DAY_LENGTH = 200.0` against a field step of 43.2 real seconds and
    a separate `PLANET_SPIN_RATE`. Earth's day is 86400 s. Three clocks that do not derive from one rotation.
14. **THE PLANET IS PINNED AT THE WORLD ORIGIN** and the sun moves around it (`SystemOrbits.gd:228`). A
    deliberate moving-frame choice; making it literal is the 0.6 headline.
15. **VEGETATION DOES NOT AFFECT ALBEDO.** A forest is far darker than sand, so the biological half of the
    ice-albedo feedback cannot exist. Work on this was started and halted.

### Instruments that lie

16. **`magma_cell_count()` / `magma_erupting()` are hardcoded** `0`/`false` and published every report.
    *(In flight.)* A gauge that always reads zero cannot distinguish "none" from "broken", and this project
    has already lost a round of measurements to exactly that.
17. **The element inventory has no per-pass attribution.** It reports that carbon moved, not which reaction
    moved it. The mineral probe already does this and found a leak in one run by naming `fire_dust`.

---

## DO THIS NEXT — the staged plan

Each stage has its own verification. Do not merge stages.

**STAGE 1 — stop the sim creating matter and energy.** *(in flight)* Land the balance gate, the element
composition table, the renamed inventory, and the creature-layer fixes re-anchored onto the emergent mass
model. Verified by one question: does the planet still create matter, yes or no. Then close the kernel
violations (1, 3, 4, 5 above).

**STAGE 2 — seed a primordial planet.** Post-magma-ocean Hadean, ~4.4 Ga: hot surface, thick CO₂/N₂
atmosphere, water still largely steam, **no free O₂** (it is a product of life), no biosphere. **Oceans must
CONDENSE, not be placed.** Delete `INITIAL_TEMP = 15.0` and every "partway" seed. Source and cite the
composition, and name the era. **Uninhabitable for a whole run is an acceptable result.** `6ad2417` is a
start on this.

**STAGE 3 — does it cool, and where does it settle?** Kill the ocean thermostat first, or the books cannot
close. Run 4000–6000 frames; watch `temp_ground_p50` for an asymptote and `snow_cells` for an ice-albedo
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

**STAGE 5 — the geological bake (`--geotime`).** Run the planet forward through geological time and freeze
the result as the start state. This is what makes habitability an output. Needs a real stopping condition
(temperature asymptote, oceans condensed, atmosphere stable). The snapshot path exists; `--geotime` does not.

Life is not a stage. It is what stage 5 hands to 0.5.

---

## LIVE ENGINE CONSTRAINTS (measured here — do not re-derive)

- **`buffer_get_data_async` returns STALE data** for compute-written buffers on Godot 4.4+ (engine bug
  [#105256](https://github.com/godotengine/godot/issues/105256)). Forking was considered and rejected.
- **Reading the device from the REPORT path CORRUPTS THE SIM.** With a `step()` submit in flight,
  `buffer_get_data` flushes outside the driver's one-submit-per-sync discipline: `h2o_total` 5062 → 9803,
  `temp_mean` 39.8 → 44.6. Defer the sample into `_drain_pending()`, after `_rd.sync()`.
- **`request_channel()` is NOT read-only.** It decides which channels get mirrored, and the field's *write*
  paths read those mirrors. This is how impact winter was found to be alive only because a diagnostic
  happened to request `dust`.
- **CPU writes to `_f._o2` / `_f._co2` / `_f._detritus` are silently discarded** —
  `MaterialFieldSphereStep3D.gd:282-306` overwrites them wholesale from the GPU readback every drain. Park
  transactions on the device injection queue instead. Every breath an animal took once debited nothing.
- **No GPU-side execution timer in this build.** `gpu_dispatch_ms` reads 0.00 on Metal.
- **Where the field's time goes:** readback **77%**, core pin 13%, dispatch **4%**. Optimise readback. A
  camera-relevance LOD was deleted for optimising the 4% while costing 4.5 °C of climate error.
- **The neighbour table and the tangent frame are SEPARATE tables** — the discrete hairy-ball theorem, proved
  in `GODOT_BEST_PRACTICES.md`. Anything reading a vector across a seam uses the per-link rotation.
- **A wrapper run reads the tree AT LAUNCH** — editing a worktree mid-batch silently mixes code versions.
- **`FOO="${FOO:-}"` arms any probe gating on `OS.has_environment`** — true for an empty value.

---

## WHAT IS SOUND — do not rebuild these

The H₂O ledger's inclusion rule; the DEFS record engine's std430 layout; the neighbour/tangent tables;
`REPOSE_TAN = 0.70`; the soil budget's per-leg identity (`kernel_residual` exactly 0.0); the erosion
transport law (no fitted constant — load moves in the same proportions as the water carrying it); the
geotherm as a seeded initial condition with a derived vertical scale; the aquifer's `k_rel`/`RESIDUAL`
capillary retention; the saturation curve from August-Roche-Magnus; Kozeny-Carman conductivity from porosity;
weathering as ice expansion and Arrhenius dissolution; lithification on real lithostatic pressure; and
metabolism as the substrate's own respiration reaction with mass-scaling emergent rather than typed.

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
- **Actors:** `actors/*`, `creatures/**`; disasters are seeds/visuals only. **Cognition:** `cognition/*`.
- **Reusable addon:** `agents/` (LocalAgent + Agent3D) · `runtime/` · `examples/`.

## North-star

**Realism is the first goal.** Ask whether a model corresponds to how the world actually works before asking
whether it runs or whether the number looks reasonable. **Dissolve, don't patch:** named phenomena have zero
dedicated code; success is special-case code DELETED. **Nothing is created from nothing** — a shortage is
never fixed by adding a source. **Emergent-everything · 3D always · GPU-first · perf-first · Big-O
first-class · config over `if species == X`.**

**Dual-purpose:** a reusable Godot dev tool (the `LocalAgent` LLM node) AND the game that is its flagship
demo. Local LLMs drive creature cognition and the streamer, fully offline.
