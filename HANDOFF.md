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
carries the measurable bar. A Rule Zero violation found in creature code gets RECORDED under 0.5, not fixed.

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
| `soil_total` 3232 | `h2o_total` 5034 |
| `sediment_total` 317 | `susp_total` 45 |
| `moisture_total` 0.97 | `cloud_cover` 0.185 |
| `erosion_cells` 134 | `mineral_total` 32192 |
| `hotspring_cells` 281 | `rock_core_c` 292.8 |
| `temp_ground_p50` 15.7 | `energy_imbalance_cool` ≈ −0.27 |

*(Water figures corrected 2026-08-03 on `feature/real-hydrology`. They read `soil_total` 3357, `h2o_total`
7034, `moisture_total` ~2100-2400. **`h2o_total` is lower because the planet is seeded with less groundwater,
not because water was lost.** The old aquifer seed was `SOIL_CAPACITY 0.6 x 0.5`, and 0.6 is above the
porosity of every real granular material; capacity is now the cell's POROSITY under Athy compaction, mean
0.141. Measured seed 5331.17, held to two decimals across 257 sampled steps with `LA_H2O_BUDGET`. The
`moisture_total` collapse is the saturation curve going from a hand-written 0.06 to the real 1.95e-5.)*

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

### 3 — GEOLOGY IS PROBABILITY ROLLS, NOT MECHANISM

- **D1 WEATHERING's temperature law is backwards.** Rate ∝ `max(0, WEATHER_TEMP − T)` with `WEATHER_TEMP`
  20.0, justified in-comment by "the sim's actual range" — the exact anti-pattern `CLAUDE.md` names, and the
  range quoted is stale. It **runs away as the planet gets colder**: at −18 °C it takes 0.152 of the bedrock
  per step. Frost shattering peaks where temperature *cycles across 0 °C*, not where it is coldest; chemical
  weathering is Arrhenius and needs water. A correct record needs a **band-around-zero driver the reaction
  engine does not have** — a new rate model, and one that will move sediment production enough to invalidate
  any A/B running beside it. Documented with numbers at `reactions/GeoRecords.gd:23-46`.
- **D2 LITHIFICATION is ungated** (`gate_mask = 0`), has no burial or pressure term, and the per-cell loop
  runs all records in one dispatch — so D1 and D2 can futile-cycle in the same cell in the same step.
- **`PlateTectonics` rotates plate SEEDS and moves no crust** (`PlateTectonics.gd:81-82` is the entire motion
  model; the class never touches the field), so the Ring of Fire sweeps across stationary continents.
  **Maintainer's decision: advect the crust** — keep the kinematic Voronoi plates, but move `rock_fill` and
  `sediment` with the plate velocity so continents actually drift. Also drop the undocumented
  `VENT_CHANCE_DIVERGENT = 0.12`, which sits beside a sibling carrying a 20-line justification.
- **Craters excavate nothing**, so half the mineral ledger has nothing to check.

### 4 — HYDROLOGY IS REAL NOW, AND EVERYTHING DOWNSTREAM OF RAIN WAS FITTED WHILE IT WAS NOT

*(Rewritten 2026-08-03. The paragraph here quoted `moisture_total` 3742 → 2139 and `cloud_cells` 4210 → 373 as
evidence about capillary retention. Those numbers were measured against a saturation curve 3080x too large and
a rain threshold three times saturation, so none of them mean what they appear to; do not compare anything to
them.)*

Evaporation is the H₂O phase rule — saturation vapour pressure at the local temperature — and it now runs as
three records on one saturation-deficit driver over water, soil and snow, with the bespoke evaporation kernel
and its seven fitted constants deleted. Hydraulic conductivity is Kozeny-Carman from per-cell porosity and
grain size, spanning K = 2.4e-6 to 1.0e-1 m/s instead of one number. **Decide whether erosion carves drainage
to the sea over a long horizon by RUNNING one**, not by moving a constant back to where it made the old
numbers look right — and see the first bullet below for how long "long" now is.

- **Rain and groundwater now run at REAL rates, and a 600-frame run is 0.4 planet-days.** That is the thing to
  understand before reading any hydrology number. `real_seconds_per_step()` is 43.2 s, so 590 field steps is
  about 7 hours of planet time — during which Earth gets ~1 mm of rain and its groundwater moves ~0.1 m. The
  old build showed rivers inside a run because its sky held 3080x too much water and its regolith conducted at
  K = 4.05 m/s, twenty-six times the coarsest natural gravel. Anything slow-emergent in hydrology now needs
  thousands of frames, not hundreds. **Decide "do rivers run" with a 4000+ frame run, not by moving a rate.**
- **Latent heat is NOT coupled: evaporation does not cool and condensation does not warm.** This is the one
  thing the phase rule needs that the substrate cannot yet express — converting L_v into a temperature change
  needs a per-cell heat capacity at the reaction engine's hands, and `add_ch(TEMP, v)` adds bare degrees. It is
  a real negative feedback on the water cycle and on surface temperature, and it is missing. No constant was
  added for it, deliberately: an unused `LATENT_HEAT_*` in `LAPhysical` would be a promise the code does not
  keep. **Decide it by giving the reaction engine a heat-capacity slot, then adding `[TEMP, -L_v/(rho c)]` as
  a product on R23/R24/R25.**
- **The atmosphere still holds ~1.7x saturation on average**, i.e. the standing cloud-water load is high
  (`moisture_total` 0.97 against ~0.57 of saturation summed over open cells, `cloud_cover` 0.185 against
  Earth's ~0.67). Kessler autoconversion is the only sink aloft. **Decide it by measuring the condensate
  against `sat` per cell, not by moving `AUTOCONVERSION_RATE_PER_S`.**
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

**One wart found in the transport work:** `mineral_total` rides a **demand-gated mirror** — `rock_fill` is in `SITUATIONAL_CHANNELS`
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

**Known Rule Zero violations in creature code, RECORDED not fixed** — fixing them now would build on sand.
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
