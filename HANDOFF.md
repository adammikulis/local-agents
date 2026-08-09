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

### State (2026-08-08, end of session)

`0.4-dev` is the integration branch, at `48111ae`.

**A CHANNEL UNIT IS NOT A MOLE, AND THE CONSERVATION GATE DID NOT KNOW.** This is the finding that
matters most, because it means the gate could not have been telling the truth. `LAReactionBalance` says
each slot declares "the ELEMENTS one unit of it contains" and held molecular FORMULAS, which are per MOLE.
One unit of `o2` is the O₂ in a cell of ambient air, **8.535 mol/m³**; one unit of `water` is a cell FULL
of liquid water, **55343 mol/m³**. A factor of **6484**, and `check_records` compared them as equal.
Teaching it `mol_per_unit()` failed nine checks instantly — every biological record, every gas↔water leg.
The same defect was in the element inventory and in `fire_sphere3d`. Fixed at `3887890` and in the merge
above. **Anything measured on `element_*` before 2026-08-07 is not comparable to anything after it.**

**THE ROCK HAS A CHEMISTRY NOW, AND THE PLANET HAS A CARBON SINK.** The lumped `M` species is gone:
silicate CaSiO₃, silica SiO₂, carbonate CaCO₃, with Ca and Si joining C/N/H/O. D1b became the real Urey
reaction, CO₂ a REACTANT rather than the catalyst it was. Measured: 91.5 units of carbon moved from air
into rock in 600 frames with a conservation drift of 7.6e-5 of the pool. This closes HANDOFF item 9's
first half and is what Stage 4 was asking for.

**ENERGY HAS A STOCK AND A DRIFT GAUGE FOR THE FIRST TIME** (`LAMaterialFieldEnergyLedger3D`).
`energy_stock` 1.432e17, `energy_run_drift_per_step` −1.53e13 — **1.07e-4 per step, 6.3% of the planet's
whole thermal stock over 590 steps.** That is the number the whole effort exists to drive to zero, and
nothing in this repository could see it before. Four leaks closed on the way: lava relaxing to a
prescribed 40 °C with no receiver, lava radiating out through the planet's own core, spring heat with no
donor, and combustion destroying H, O and N.

**IN FLIGHT, NOT MERGED:**
- **T2 latent heat, on `worktree-wf_c468d92c-702-2`. REJECTED, and the defect is in a constant set added
  this session at `c479b36`.** The enthalpies violate Hess's law: `L_vap` is quoted at 100 °C while
  `L_fus` and `L_sub` are at 0 °C, so `2.257e6 + 3.337e5 = 2.591e6` falls short of `L_sub = 2.834e6` by
  2.433e5 J/kg, and the loop water → vapour → snow → water releases that much from nothing every
  traverse. **The fix is one line: state all three at 0 °C.** `2.501e6 + 3.337e5 = 2.8347e6` against the
  measured 2.834e6 closes to 0.02%, inside the constants' own uncertainty. Its verifier also measured a
  moist-greenhouse runaway on that branch; re-measure after the Hess fix before believing it, because the
  base has moved three commits since.
- `6ad2417` on `feature/conservation` — the pre-biotic atmosphere seed. Applies cleanly. Its own commit
  message says not to merge it inside a conservation measurement window.
- `integrate/conservation` is fully absorbed and prunable. `55cda84` **cannot be cherry-picked** — it
  edits `atmos_evap_sphere3d.glsl`, which `40c69f1` deleted.

**THE BASELINE, at `48111ae`,** three runs, `--sandbox --planet-only --run-frames=600 --fast=8
--seed=4242`, all at `field_step` 590 / `field_sim_s` 79.8:
`temp_ground_p50` 26.21 · `temp_mean` 31.89 · `energy_absorbed_cool_mean` 123.5 ·
`energy_emitted_cool_mean` 251.4 · `energy_imbalance_cool` −1.036 · `energy_stock` 1.432e17 ·
`energy_run_drift_per_step` −1.53e13 · `nitrogen_run_drift_per_step` −0.0009 · `h2o_total` 4278 ·
`snow_cells` 963 · `hotspring_boiling` 51 · `element_C` 5698 · `phenomenon/impact` 17 · `/eruption` 2.

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
3. ~~BURNING CELLS ARE PINNED TO 640 °C~~ — **FALSE for the pin and the carbon** since `fire_sphere3d.glsl:190`
   (`temp += burned * HEAT_PER_UNIT_BURN / cap`, and 1 C : 1 O₂ : 1 CO₂). Combustion **also** destroyed H, O
   and N until 2026-08-08, which this entry never noticed.
4. ~~SPRING HEAT HAS NO DONOR~~ — **CLOSED.** Cold recharge now cools the rock it soaks into, and the mix is
   capacity-weighted. `hotspring_boiling` 107 → 51. **What is still unpaid is the regolith→regolith DARCY
   leg**, disclosed in `soil_sphere3d.glsl:51`.
5. ~~THE SOIL KERNEL INVENTS WATER~~ — the regolith clamp is instrumented (`DBG_CLAMP_GAIN`) and
   `kernel_residual` reads 0.0. **A second clamp at `soil_sphere3d.glsl:499` on the `water[g]` leg is still
   uninstrumented.**

### Missing physics — a real mechanism simply is not there

6. **NO LATENT HEAT — still true, and the branch that adds it is REJECTED on a Hess's-law violation.**
   *(Corrected 2026-08-08. This entry blamed `55cda84` for showing the cycle runs "~4500× too fast" at
   −131 °C. That branch **cannot even be applied** — it edits `atmos_evap_sphere3d.glsl`, which `40c69f1`
   deleted; evaporation is now records R23/R24/R25 at a derived bulk-aerodynamic rate with no free
   parameter, so the 4500× figure was measured against a rate that no longer exists.)* The live attempt is
   `worktree-wf_c468d92c-702-2`; see the state block for the one-line fix.
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
session; the kernel violations 1/3/4/5 are closed. **What is left is one number:**
`energy_run_drift_per_step` reads **−1.53e13 against an `energy_stock` of 1.432e17 — 1.07e-4 per step, 6.3%
of the planet's thermal stock over 590 steps.** Drive it toward zero. The ledger names its own unbooked
terms in its header; work that list. Then latent heat (item 6), which is the largest single missing term
and needs the Hess fix first.

**Verified by one question, and it is now askable:** does the planet still create energy, yes or no.
Before this session nothing in the repository could answer it — every climate claim was argued from
temperature, which is a state variable and tells you where the planet HAS got to, never why.

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
