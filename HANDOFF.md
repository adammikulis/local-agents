# TODO / Roadmap — Local Agents (voxel-planet caretaker sim)

**This file is the map of what is LEFT. It is not a history.** Anything finished is deleted the moment it is
committed — git is the record of what was done. Two rules follow:
- **When you finish something, delete its entry.** Do not tick it, strike it, or annotate it as done.
- **When you find an entry is FALSE, fix it in place** and say what it claimed, so nobody re-derives the same
  wrong conclusion. Durable lessons belong in `CLAUDE.md` (process) or `GODOT_BEST_PRACTICES.md` (Godot), not here.

**And distrust this file's FRAMINGS, not only its facts.** Rewritten 2026-08-03 because the previous version
led with "every subsystem with a conservation ledger conserves; every subsystem without one mints", and a
whole session of work was planned against that sentence before the maintainer stopped it. Every factual claim
in it was checkable and several were checked. The *framing* was the problem: "minting" made **creating matter
from nothing** sound like an accounting discrepancy, so the plan it produced was to measure the discrepancy
better and, worse, to fix a shortage by adding another source. If a phrase here lets you think about a physics
violation without picturing the physics, replace the phrase.

Main scene: the game boots to `addons/local_agents/game/menu/MainMenu.tscn`; the flagship sim is
`addons/local_agents/game/VoxelWorld.tscn`. Read `CLAUDE.md` and `addons/local_agents/sim/EMERGENCE.md` first.

---

## ▶ START HERE

**0.4 IS THE PLANET, AND NOTHING ELSE. Creature work is 0.5 and does not start yet** — not lower priority,
*premature*, because behaviour tuned against a broken substrate has to be redone. `CLAUDE.md` → SCOPE RULE
carries the measurable bar. **A defect you find is FIXED, wherever it lives. Nothing here licenses recording
a broken thing instead of repairing it** — that policy was invented by an agent, never approved, and it is how
this tracker filled up with known-and-unfixed physics.

**THE ONE THING TO UNDERSTAND BEFORE YOU TOUCH THE SUBSTRATE.** This simulation creates matter from nothing.
Not as a rounding error — by construction, because the reaction engine is a **rate table, not a chemistry**.
That is item 1 and everything else here is smaller. Be suspicious of any task description, including one
written in this file, that proposes to fix a shortage by adding a *source*.

`sorting.py` at repo root is the maintainer's, untracked — leave it.

### Branch state

`0.4-dev` is the integration branch and everything is merged into it; no outstanding worktrees. 0.3.1 shipped
on `main` (`v0.3.1`). Work in a worktree off `0.4-dev`.

---

## HOW TO RUN AND MEASURE

**Never launch godot windowed directly** — it steals the maintainer's keyboard focus. Always the wrapper.
`--fixed-fps 60` is an ENGINE flag and goes BEFORE the `--`:

```
LA_RUN_TIMEOUT=900 LA_NO_STREAMER=1 scripts/run_sim_offscreen.sh --path . \
  addons/local_agents/game/VoxelWorld.tscn --fixed-fps 60 \
  -- --sandbox --planet-only --run-frames=600 --fast=8 --seed=4242
```

A 600-frame run costs ~90 s and EXITS (it prints `LA_RUN_COMPLETE`). Looping runs is normal and expected.
- `--no-fauna` — animals off, **vegetation kept**, so the carbon cycle is intact. Use for climate/chemistry.
- `--planet-only` — vegetation off too: pure geophysics. Use for geology/hydrology/mineral.

**In a fresh worktree, in this order, or your measurements are fiction:** symlink `bin/`, then
`godot --headless --path . --import` (unimported `.glsl` gives a silently dead GPU field), then
`scripts/editor_scan.sh` (always — a new worktree has no class cache; never a bare `godot --headless --editor`,
two concurrent scans segfault).

**Gates:** `scripts/agent_harness.sh lint` is exactly what CI runs and includes
`scripts/check_physical_constants.sh` and the file-length limits. `scripts/smoke_check.sh` for a fast health
check; `scripts/sim_check.sh` for a one-line behavioural verify.

**Instruments:** `LA_SOIL_BUDGET=1` (per-leg groundwater), `LA_H2O_BUDGET=1` (per-pass water),
`LA_MINERAL_BUDGET=1` (per-pass mineral), `LA_MINERAL_PROFILE=1` (elevation profile of mobile mineral — the
one that answers "did it move DOWNHILL", which no total can). The two budgets share the driver's single step
probe and are mutually exclusive; the profile samples in `post_step()` and composes with either.

### Measurement discipline

- **Three runs per arm, minimum.** Quote `phenomenon`, `phenomenon/impact`, `phenomenon/eruption` and `bolts`
  beside every scalar — residual spread is DISCRETE, dominated by how many disasters a run drew.
- **Compare at equal `field_sim_s` / `field_step`, never at equal `--run-frames`.**
- **A global mean cannot answer a local question.** `temp_mean` is inflated by magma cells; `temp_ground_p50`
  is where things stand. Prefer `energy_net_cool` to `energy_net`.
- **CHECK THE SIM IS ALIVE FIRST.** A silent load failure once printed a completely normal-looking
  `SIM_REPORT` with zero reaction records. An aggregate that is exactly `0.00`, or an order of magnitude off
  baseline, is a broken pipeline until proven otherwise — not a result.
- **A gate that passes with the feature disabled is not a gate.** Build the disabled arm and show divergence.
  This caught an inert 175-line module that had passed every check written for it.

### Current baseline — `--planet-only`, 600 frames, `--fast=8 --seed=4242 --fixed-fps 60`

The planet changed a great deal on 2026-08-03; anything older than this table is superseded.

| | |
|---|---|
| `soil_total` 3357 | `h2o_total` 7034 |
| `sediment_total` 260 | `susp_total` 42.5 |
| `erosion_cells` 134 | `mineral_total` 32192 |
| `hotspring_cells` 281 | `rock_core_c` 292.8 |
| `temp_ground_p50` 17.6 | `energy_imbalance_cool` ≈ −0.27 |

Disaster load 8–9 phenomena / 5 impacts / 3–4 eruptions; `field_step` 590; `field_sim_s` 79.8.

---

## DO THIS NEXT (ranked)

### 1 — THE SUBSTRATE CREATES MATTER FROM NOTHING. THE ELEMENTS MUST BE PRESENT AT INITIALIZATION.

**This is the top item and it replaces what used to be items 1 and 2.** Those read "nitrogen has no source —
build the source" and "carbon is minted by a prescriber — replace with a finite atmosphere + outgassing as the
SOURCE". Both accepted that a substance needs a runtime source. **It does not.** A planet does not manufacture
nitrogen; it was assembled with 78% N₂ in its air and has been rearranging it ever since. The fix for a tap
with no tank is not a better tap.

**Why this is possible is STRUCTURAL.** The DEFS engine is a rate table, not a chemistry:
- `rec()` takes `reactants[]` and `products[]` as independent lists with hand-written coefficients and
  **nothing relates them.** R15 shipped consuming 0.8 O₂ per 1.0 CO₂ produced — 18% under-oxidised, creating
  oxygen every cycle — and was fixed by a person noticing and setting two constants equal by hand.
- **`RELAX_TARGET` has no reactant at all.** `reactions_sphere3d.glsl:372` skips the entire cap-and-debit
  block for it, so only the product credit runs. Every carbon atom that has ever existed here came from R12.
- **There is no load-time validation of any kind.** Conservation is asserted in comments and enforced nowhere.

**The work, in order:**
1. **Seed every conserved substance at world build, finite, at physically real proportions** (Earth: 78% N₂,
   21% O₂, 0.04% CO₂). `_co2` is currently `resize()`d with no `.fill()` while the line above fills `_o2`.
2. **Delete `RELAX_TARGET`,** or confine it to a genuine boundary with an explicit reservoir behind it. Once
   there is real air in the cell above, "relax toward ambient" is exchange with a neighbour that holds the
   gas — an ordinary conserving transfer — and R11/R12 stop being needed.
3. **Add a load-time BALANCE GATE** shaped like `check_physical_constants.sh`: refuse any record whose
   products do not balance its reactants. This is the part that matters most — it makes the violation
   *unwritable* rather than merely absent, and a rule that lives only in a comment has already been broken here.
4. **Nitrogen fixation is then an ordinary record**, not a source: atmospheric N₂ → fixed N, conserving,
   driven by biology and by lightning (which fixes real nitrogen on real planets). The biosphere collapse
   blamed on a missing source was really a missing ATMOSPHERE.

Measured: `carbon_drift_per_step` +1.94/+2.37/+2.09; `carbon_first` 720 against `carbon_total` ~5200, so
carbon has grown 7× from its seeded value. Fertility reads closed only because uptake and release were
matched by hand at the litter C:N ratio — nothing structural holds them there.

**On the ledgers, since they are this project's proudest instrument:** a drift gauge tells you the violation
*happened*. It cannot tell you the violation is *possible*. Keep the ledgers; they are not the fix.

**Free DEFS slot index is 20.** Slots 5 (`FUEL`) and 6 (`FIRE`) are declared in both the GDScript enum and the
kernel `#define`s but have **no `read_ch`/`add_ch` branch**, so they read 0 and their writes vanish silently —
the same two-hand-maintained-lists drift a balance gate should also catch.

### 2 — THE PLANET COOLS WITHOUT STOPPING, AND NOTHING SAYS WHERE IT SETTLES

`energy_imbalance_cool` is ≈ −0.27 and the surface has no demonstrated equilibrium. **What would decide it:**
4000–6000 frames, watching whether `temp_ground_p50` asymptotes or keeps falling, and `snow_cells` for an
ice-albedo runaway. Do not tune the solar constant — 1361 W/m² is a measured fact, and moving a physical
constant to stabilise a model is how this codebase ended up with water freezing at 12.5 °C.

**The geotherm does not fix this and never could.** The interior delivers ~9 W/m² at the base of the crust,
but rock's real diffusivity moves a thermal front 0.16 m in the 590 steps a run covers. The interior is a
boundary condition on the crust, not a term in the surface budget.

- **2b — the ocean is a thermostat, not a body of water.** Live at `kernels3d/heat3d_cool_sphere3d.glsl:47-50`:
  the sea is held near a fixed temperature by fiat and does not participate in the energy balance at all. The
  books cannot close while it exists.
- **2c — the sea has ~0.93 m of thermal inertia where it should have 20–100 m.** Checkable now that the
  capacities are stated in real units (rock lands at 0.248 m against a derived diurnal skin depth of 0.168 m,
  which is fine; water is wrong by one to two orders).

### 3 — GEOLOGY: WHAT IS LEFT NOW THAT IT IS MECHANISM

*(Rewritten 2026-08-03. The four items that were here — D1's backwards temperature law, D2's missing burial
term, plates that moved no crust, and the `VENT_CHANCE_DIVERGENT` roll — are done and are deleted per the
tracker rule. Git holds what was fixed. What follows is only what is still open.)*

- **CORRECTED 2026-08-03: "craters excavate nothing" was FALSE, and it was a gauge read in a run mode that
  fires no meteor.** `--sandbox --planet-only` spawns none, so `crater_mass` is 0.0 because nothing struck —
  and the `phenomenon/impact` events such a run reports are SHOCK-threshold crossings from earthquakes
  (`LAEventTracker.gd:79` increments on `shock_cells`), not strikes, which is what made the zero look like a
  broken excavation. Measured with `--auto-meteor` on the same build: one meteor gives `crater_cells` 3,
  `crater_mass` 3.0, `crater_open_now` 3/3 and `crater_rock_now` 0.72 — the device agrees the bedrock is gone
  — with `mineral_drift` 0.00. The path works. **Quote `crater_*` only from a run that actually fires one.**
- **`erupt_source` offers far more than the device accepts:** `mineral_inject_offered` 493.5 against
  `mineral_inject_moved` 19.9 on that same run. Either the finite magma chamber is doing its job (the vent
  column has no bedrock left to melt) or the `rock_fill` mirror the chamber walk reads is stale and aiming at
  an already-empty cell. The two are not distinguished yet. **What would decide it:** print the chamber cell's
  live rock_fill beside the offer for a handful of eruptions.
- **The plate acceleration is pinned at 3e5 by the SOLIDITY THRESHOLD, and that is the thing to fix if you
  want faster drift.** `solid` is derived as `rock_fill >= 0.5`, so a margin in continuous motion carries a
  band of partially-filled cells of which roughly half read as VOID. At `GEOLOGIC_TIME_ACCELERATION` 1e6 that
  band opened ~2000 cells of crust, which exposed the seeded geotherm (`hotspring_cells` 1000 against 309
  held-still) and flashed the ocean to steam (`water_total` 209 against 1358). At 3e5 the cascade does not
  start (`rock_cells` 32303, at or above both baseline 32038 and control 31787). A TVD flux limiter was tried
  first and made no difference (28863 either way), which is what identified the threshold rather than the
  advection scheme. **What would decide it:** whether a fractional-solidity read (the substrate already stores
  the fraction) can replace the binary test in the consumers that matter — SolidDerivePass, the geotherm's
  surface walk, and `LAMineralStamp3D`.
- **The residual cost of crust motion at 3e5, unresolved:** `water_total` 587 against a baseline 1416, and
  `temp_mean` +2.8 °C. `mineral_total` is exactly conserved and `rock_cells` is not thinning, so this is not
  the transport losing mass — it is a hotter, drier planet from the churn. Quantify it against
  `LA_NO_PLATE_ADVECT=1`, which is the in-build control for exactly this.
- **`VOLCANO_CHANCE_CONVERGENT = 0.3` is still a rarity roll** (`PlateTectonics.gd`). Its own comment names
  the acceptance test — raise it to 1.0 and compare `temp_mean`/`temp_ground_mean` at equal `field_step` over
  three runs per arm — and names the radiative sink as the precondition. The sink has since landed. The
  measurement has not been run.
- **Lithification is correct and does not fire in a short run, which is the honest result.** D2 now needs
  `LAPhysical.LITHIFICATION_PRESSURE_PA` (56.9 MPa) of SOLID overburden, which is four cells of bedrock — the
  same 2 km at which `GROUNDWATER_CIRCULATION_M` says porosity closes. Surface sediment therefore cannot
  lithify, which is what ended the D1/D2 futile cycle. Nothing on this planet accumulates 2 km of burial in 80
  simulated seconds, so the rock→sediment→rock loop closes only over geological time. **Do not "fix" this by
  lowering the threshold** — that is the move that produced `LITH_DEPTH = 0.5`.
- **Chemical weathering is real and nearly invisible, and that ratio is correct.** Real basaltic chemical
  denudation is ~17 µm/yr against a cell that stands for 500 model metres of depth, so 242 accelerated years
  lowers a surface by ~4 mm. On Earth plate motion and chemical denudation differ by about three orders of
  magnitude and they do here too. Anything that makes weathering visible within one run has broken that ratio.
  The one number in it that a measurement may move is `LAGeoRecords.DISSOLUTION_K`, the model's rate prefactor,
  and it is bounded at the HOT end (a boiling spring cell) rather than the temperate one.

### 4 — THE PLANET IS WET NOW, AND EVERY CONSTANT DOWNSTREAM OF RAIN WAS FITTED WHILE IT WAS DRY

The aquifer gained capillary retention, so groundwater is 3474 units of H₂O that used to be in the sky:
`moisture_total` 3742 → 2139, `cloud_cells` 4210 → 373, and with less rain `sediment_total` 967 → 282,
`susp_total` 70 → 17. **Decide it by measuring whether erosion now carves drainage to the sea over a long
horizon**, not by moving a constant back to where it made the old numbers look right.

- **The atmosphere holds ~30% of the planet's H₂O. Earth holds ~0.001%.** Still off by four orders. Compare
  `moisture_total` against `water_total + soil_total`: a planet whose air outweighs its ocean is wrong however
  the individual numbers look.
- **`CONDUCT = 0.35` is ONE hydraulic conductivity for all regolith.** Real K spans ~12 orders of magnitude by
  material. Same design smell as one thermal physiology per creature. Needs per-cell permeability, which the
  binary `regolith` mask cannot carry.
- **Soil water has no evaporative sink.** Root uptake is the only path out, ~0.03/step against a ~3400-unit
  reservoir. Real evapotranspiration is the dominant soil-water loss.
- **4b — arming the geotherm costs the water table.** The path is real (hot regolith → spring → >100 °C →
  steam) and H₂O stays conserved, but the *rate* is not defensible because **recharge is missing**.
- **4c — live airborne dust costs the water table a quarter of itself and nobody knows why.** A *forced* 14%
  constant dimming raises it instead. Those probes were one run each against a 3–6 unit spread; needs 3 per
  arm with `LA_SOIL_BUDGET` on both.

### 5 — EROSION TRANSPORTS, BUT NOBODY HAS SHOWN IT CARVES

The transport leg ships and sediment measurably travels downhill (the high-elevation tercile loses surface
mineral at every horizon). Untested is whether it carves **drainage to the sea** at this rate: `relief` moved
2.445 → 2.560 in *both* arms at 80 sim-seconds, so the landscape has not responded yet. Wants
`--run-frames=2000`+, not a constant.

**Two warts found in the transport work:** `susp` sealed inside rock is frozen forever (reactions skip solid
cells, so suspension in a cell that later crosses the solid threshold never returns — it is most of
`susp_total`); and `mineral_total` rides a **demand-gated mirror** — `rock_fill` is in `SITUATIONAL_CHANNELS`
and only refreshes while something arms it, so the ledger's 99% term can be stale.

### 6 — SMALLER, ALL MEASURED

- **`magma_cell_count()` and `magma_erupting()` are hardcoded `0`/`false`** in `MaterialField3D.gd` and
  published in every report. Four sibling stubs were fixed; these two remain.
- **`add_lava` rewinds the GPU with a whole-mirror `set_field`** — it needs a sparse move, and it touches the
  extract-only hub.
- **The H₂O ledger has a large unexplained excursion.** With the run-level gauge: water falls 29% early then
  partly recovers, and the per-step figure shrinks 6× with horizon. The aquifer fix improved it from −2.74 to
  −0.446 per step. Untested: settling transient, or `h2o_first` sampling before world-gen finishes seeding.
- **`--planet-only` is not fully deterministic** (eruptions 4/3/3 at one seed) despite its commit claiming it
  is the only mode that can be. Either close it or correct the claim.
- **A4: rebuild `VoxelWorld` → Anima. HELD for supervised handling** — it rebuilds the composition root, so it
  needs launched-window verification.

### 7 — THE GEOLOGICAL BAKE (`--geotime`)

**0.4 work, not a stretch goal** — it is what makes this "the emergent planet" rather than merely a correct
one. Run the planet forward through geological time (erosion, volcanism, climate) and freeze the result as a
livable start state. `--geotime` does not exist; the snapshot path does. It is the natural consumer of
everything above and cannot be built until erosion carves, springs run and the elements conserve — so it goes
last, and it is the proof that the rest worked.

---

## LIVE ENGINE CONSTRAINTS (measured here — do not re-derive)

- **`buffer_get_data_async` returns STALE data** for compute-written buffers on Godot 4.4+ (engine bug
  [#105256](https://github.com/godotengine/godot/issues/105256)). Forking the engine was considered and rejected.
- **Reading the device directly from the REPORT path CORRUPTS THE SIM.** On a local `RenderingDevice` with a
  `step()` submit in flight, `buffer_get_data` flushes outside the driver's one-submit-per-sync discipline:
  `h2o_total` 5062 → 9803, `temp_mean` 39.8 → 44.6. Defer the sample into `_drain_pending()`, after
  `_rd.sync()`. See `request_probe`/`take_probe`.
- **`request_channel()` is NOT read-only.** It decides which channels get mirrored, and the field's *write*
  paths read those mirrors. Changing what is mirrored changes the simulation — this is how impact winter was
  found to be alive only because a diagnostic happened to request `dust`.
- **There is NO GPU-side execution timer in this build.** `gpu_dispatch_ms` always reads 0.00 on Metal;
  `LA_RENDER_DRIVER=vulkan` exists for a one-off diagnostic. Read fps and `field_ms` as directional only.
- **Where the field's time actually goes** (`field_ms` 5.210 total): `field_readback_ms` 4.020 (**77%**),
  `field_pin_ms` 0.660 (13%), `field_dispatch_ms` 0.188 (**4%**), `field_post_ms` 0.097. Optimise readback.
  A camera-relevance LOD was deleted for optimising the 4% while costing 4.5 °C of climate error.
- **The neighbour table and the tangent frame are SEPARATE tables and must stay that way** — the discrete
  hairy-ball theorem, proved and recorded in `GODOT_BEST_PRACTICES.md`. Anything reading a vector across a
  seam must use the precomputed per-link rotation.
- **A wrapper run reads the tree AT LAUNCH**, so editing a worktree mid-batch silently mixes code versions.
- **A runner passing `FOO="${FOO:-}"` arms any probe gating on `OS.has_environment`** — true for an empty value.

---

## WHAT IS SOUND — do not rebuild these

The H₂O ledger's inclusion rule and the inject queue's transfer/add split; the DEFS record engine's std430
layout and every 1:1 conserving record; the neighbour/tangent tables; `REPOSE_TAN = 0.70`; the soil budget's
per-leg identity; the erosion transport law (no fitted constant — load moves in the same proportions as the
water that carries it); the geotherm as a seeded initial condition with a derived vertical scale; and the
aquifer's `k_rel`/`RESIDUAL` capillary retention.

---

## 0.5 — THE LIVING CREATURES — PARKED. DO NOT START THIS.

Everything here is 0.5 and does not begin until the planet is locked down (`CLAUDE.md` → SCOPE RULE). The
sequenced plan lives in `docs/0.5_CREATURE_FEATURES.md` and `docs/0.5_PARALLELIZATION_GUIDE.md`.

**Creature-layer physics defects — ALL OF THESE ARE BEING FIXED NOW, not recorded.** They are listed here
only until the work lands, and then this list goes away.
`CreatureDigestion.ambient_graze` creates food out of the temperature at the animal's feet, with no source and
nothing decremented ("never depletes, can't be crashed"), so starvation is unreachable and herbivore numbers
are set by a JSON `pop_cap`. **That is item 1 again, in the creature layer** — the same engine-level
permission to conjure matter, wearing different clothes. Nothing scales with body mass: a fox and a mouse burn
identical energy, and the `basal_metabolism`/`active_metabolism` genes are read by nothing. One thermal
physiology covers all 28 species. `Fish.gd` spends energy only `if not preys_on.is_empty()`, so shrimp,
jellyfish, crab and turtle cannot starve.

## 0.6 — THE FULL SOLAR SYSTEM

0.3 shipped the moving-frame system (real orbital state, seasons, insolation, a moon, momentum). 0.6 makes it
literal and navigable: migrate the GPU field to a moving-frame body-local representation so the planet node
can translate; planets, moons and sun as first-class bodies on real orbits; land on the moon; render the real
orbits; persist the orbital state.

---

## Where everything lives

- **THE substrate:** `material/MaterialField3D.gd` (thin facade, **extract-only**) + `MaterialSphereGPU3D`
  (GPU host) · `sphere_passes/*` · `kernels3d/*_sphere3d.glsl` (authoritative) · `MaterialReactions3D` (the
  registry) + `reactions/{ReactionDefs,Gas,Bio,Phase,Geo}Records.gd` · `PhysicalConstants.gd` (`LAPhysical`)
  · the budget/probe modules · `WaterParticles` · `mesh/VegetationRenderer`.
- **Composition root:** `game/VoxelWorld.gd` (**extract-only**) + `game/world/*` controllers.
- **Actors:** `actors/*` + `actors/creature/*`; disasters are seeds/visuals only. **Cognition:** `cognition/*`.
  **Ecology:** `ecology/*`. **Data:** `data/species/**/*.json`.
- **Reusable addon:** `agents/` (LocalAgent + Agent3D) · `runtime/` · `ui/ModelManager*` · `examples/`.

## North-star

**Realism is the first goal** (`CLAUDE.md` RULE ZERO). Ask whether a model corresponds to how the world
actually works before asking whether it runs, whether the test passes, or whether the number looks reasonable.
Those are all downstream.

**Dissolve, don't patch:** ONE physical substrate — matter with pressure, temperature, phase, gravity,
momentum and chemistry. Named phenomena (volcano, eruption, storm, delta) have **zero dedicated code**; they
emerge. Success is special-case code DELETED. · **Emergent-everything** · **3D always** · **GPU/native-first**
· **perf-first** · **Big-O first-class** · **config over `if species == X`**.

**Dual-purpose:** a reusable Godot dev tool (the `LocalAgent` LLM node) AND a full game that is its flagship
demo. Local LLMs drive creature cognition and the streamer, fully offline — headline this.
