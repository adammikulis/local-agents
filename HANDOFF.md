# TODO / Roadmap — Local Agents (voxel-planet caretaker sim)

**This file is the map of what is LEFT. It is not a history.** Anything finished is deleted from here the
moment it is committed — git is the record of what was done, and a tracker that doubles as a changelog buries
the next agent's actual job under work nobody needs to read again. Two rules follow from that:
- **When you finish something, delete its entry.** Do not tick it, strike it, or annotate it as done.
- **When you find an entry is FALSE, fix it in place** and say what it claimed, so nobody re-derives the same
  wrong conclusion. A confidently wrong tracker is worse than an out-of-date one. Durable lessons belong in
  `CLAUDE.md` (process) or `GODOT_BEST_PRACTICES.md` (Godot/runtime), not here.

Main scene: the game boots to `addons/local_agents/game/menu/MainMenu.tscn` (`project.godot:15`); the flagship
sim is `addons/local_agents/game/VoxelWorld.tscn`. Read `CLAUDE.md` + `addons/local_agents/sim/EMERGENCE.md`
first. *(Some `scenes/simulation/voxel/...` paths survive further down — treat any of them as pre-split; the
addon-UX split moved everything under `addons/local_agents/{sim,game}/`.)*

## ▶ START HERE

**0.4 is THE EMERGENT PLANET** (pivot 2026-07-12; creatures moved to 0.5, the full solar system to 0.6).
The physical substrate is the star — geology, hydrology, volcanism, climate, all emergent from the ONE field,
simulated start to finish: a geological bake (rough world → erosion/volcanism/climate run forward) frozen as a
livable start state you can tend or just watch. Look = cel-shading. 0.3.1 shipped on `main` (`v0.3.1`);
development is on `0.4-dev`. Work in a worktree off it. Memories worth loading: `roadmap-0.4-life-cycle`
(the pivot), `dissolve-dont-patch`, `perf-first-ruthlessly`, `big-o-first-class`, `iterate-fast`,
`verify-before-merge`, `worktree-shader-import-gotcha`, `three-d-always`.

**Branch state (2026-08-03):** `0.4-dev` is the integration branch, CI green, lint green. Two live feature
branches, both with a worktree beside the primary checkout:
- **`feature/energy-balance`** — rebased onto `0.4-dev` (no conflicts), emissivity now varies with the
  hydrostatic `pressure` channel. Mechanism works; the balance does not close yet. See item #1.
- **`feature/lava-supply`** — `erupt_source` moved onto the sparse device add. See item #4.

`sorting.py` at repo root is the maintainer's, untracked — leave it.

**MEASUREMENT DISCIPLINE, learned the expensive way this session — read before comparing any two runs.**
Runs are **not reproducible at a fixed seed**. Three 2000-frame runs at `--seed=4242` drew **110 / 28 /
126 phenomena** (bolts 514 / 18 / 1025) and ended at `temp_mean` **62.8 / 59.4 / 78.3**. So:
- **Never A/B two branches on one run each.** Doing exactly that produced a 7 °C difference that looked
  like a GPU race and was entirely the weather. Three runs per arm, minimum.
- **Quote `phenomenon`, `phenomenon/impact`, `phenomenon/eruption` and `bolts` beside every scalar**, and
  compare arms at MATCHED disaster load, not row-for-row.
- **Trust monotone trends within one run** (a pole cooling steadily over 2000 frames) far more than any
  level compared across runs.
- `--fixed-fps 60` is still required and still goes BEFORE the `--`; it fixes the field clock
  (`field_step` was identical across all six runs of a 3×3) but not the disaster draw.

**WHY it varies is still OPEN, and one attractive theory is already REFUTED — do not re-run it.**
*(2026-08-03.)* The obvious suspect was that ambient disasters "draw from Godot's global RNG". **They do
not.** `VoxelSettingsApplier._pick_disaster_kind`, `_random_surface_point` and the `_disaster_next` jitter
all already go through `LASimRng`, and `VoxelDisasters.gd` contains zero bare RNG calls. The second
suspect was that the director counted its interval down on the RENDER-frame delta in `_process` — which
was TRUE (it did, and `--fixed-fps 60` does not fix that clock) and is the same bug `LAPlateTectonics`
had fixed one directory over. Moving it to `_physics_process` **did not narrow the spread**: three
600-frame runs gave phenomena 16 / 23 / 27 and bolts 12 / 46 / 76, against 22 / 19 / 25 before. That
change is parked, unmerged, on `feature/deterministic-disasters` (kept only because a difficulty director
*should* advance on simulated time so its cadence scales with `--fast`).
**The live theory, untested:** `LASimRng` is a SINGLE SHARED STREAM and 51 bare global-RNG draws remain
outside it. Any consumer whose *number* of draws per frame varies — creature cognition and think-LOD are
framerate-sensitive, and the population itself changes — shifts the stream position for every later
consumer, so a correctly-seeded disaster draw comes from a different point in the sequence. If that holds,
seeding harder cannot fix it and the answer is **per-subsystem streams** (an independent `LASimRng` per
domain: disasters, heredity, actors, weather). Cheapest probe: log `LASimRng`'s draw count per frame across
two runs and find the first frame they diverge.

---

## DO THIS NEXT (ranked)

**1 — Finish the energy balance. It just became possible.** On `feature/energy-balance` (rebase first).
Every prescribed temperature target is already gone and the surface does `dT = (absorbed − σεT⁴)·dt/C` with
albedo and per-cell heat capacity. What was missing was any altitude dependence: `LAPSE` was the only height
term in surface temperature and it died with the prescriber it belonged to, so a summit and a sea-level cell
at the same latitude reach the same equilibrium, and snow / sea ice sit at zero.
**Do not re-prescribe a lapse.** A real surface is colder at height because the column above it is thinner.
**Air mass now exists as a channel**, so `EMISSIVITY` (a constant `0.9` in `heat3d_solar_sphere3d.glsl`) can
finally vary with the overlying air mass — which gives the lapse rate, the snow line and the ice-albedo
feedback in one change, with nothing prescribed. Floor was 4.27 °C when the branch was parked.

**2 — DECIDE: how much water should the planet start with?** *(Needs the maintainer.)* Now that the cycle
conserves, the planet is dry: `biomass_total` is 933–951 where the old minting build read 1594–1605, and
`soil_total` settles at 173–205 against a theoretical maximum of ~7994 (13323 regolith cells × `CAPACITY`
0.6), i.e. ~2.4% saturation. Creatures hold (177–190) so the food web survives, but standing vegetation
halved. The old figure was partly fed by water that did not exist, so **933–951 is the honest number and
should not be reverted.** How much H₂O a planet HAS is a legitimate world-gen initial condition, not a fake —
it currently seeds 7485.40 units (water 3483.78, soil 3997.07, moisture 4.55).
**Measure before seeding more:** `INFIL_RATE` is deliberately set below the rainfall rate so storms produce
runoff, which may be starving the water table rather than the planet being short of water. Raising the seed to
paper over a recharge limit would be fitting a constant to an outcome.

**3 — The world does not sustain a population over a long run, at any speed. MEASURED 2026-08-03, and it is
not what this entry used to say.** *(It previously cited a 1500-frame diagnostic ending near 2 creatures with
"suffocation 111, frozen 73, old age 72, starvation 58" and called that "the map of what to fix". Re-measured
on `0.4-dev` at `--fixed-fps 60 --fast=8 --seed=4242 --run-frames=2000`, every one of those four numbers is
wrong: **suffocated 0, frozen 0, heatstroke 4**, and the dominant cause by a factor of three is **old age**.)*

The arc, from `POP_TRACE` (creatures, every 180 frames): 239 · 234 · 183 · **71** · 32 · 15 · 8 · 3 · 2 · 1 ·
**0**. Total land extinction by frame 1980; fish hold flat at 52 because aquatic breeding has a survival floor
(`EcologyBreeding.gd` `GRAZE_BIOMASS_FLOOR`). Final histogram: **old age 665**, starved 199, thirst 65,
starvation 23, heatstroke 4, eaten 1, burned 1, frozen 0, suffocated 0, drowned 0.

Two distinct failures, in order:
- **A thirst mass-casualty between frames 540 and 720**, where the population halves (183 → 71) and `thirst`
  goes 0 → 50 with rabbit deaths 5 → 50 in the same window. The land is dry: `water_total` 1039 and
  `soil_total` **91.7** at `field_step 1990`, against the ~173–205 item #2 quotes at a shallower horizon, so
  the drying continues rather than settling.
- **Then no replacement.** After that cliff nothing breeds; `old age` climbs 217 → 665 while every other cause
  goes nearly flat. The survivors simply age out.

**And the likely upstream cause is item #1, not a carrying-capacity constant.** `temp_mean` rises
monotonically across the whole run — 29.5 · 36.9 · 40.4 · 41.4 · 44.7 · 48.0 · 50.4 · 53.7 · 58.2 · 60.5 ·
62.1, ending at 62.8 with no sign of levelling — while `moisture_total` climbs 1851 → 4665 as `water_total`
and `soil_total` fall. That is a warming atmosphere raising `sat(T)`, holding water as vapour, and drying the
land the creatures drink from. `0.4-dev` has no radiative sink at all, so nothing bounds this.
**Do not tune breeding or thirst rates against these numbers until #1 lands** — re-measure after, because the
mechanism being fixed is the one that produced them. (`surf_mean`, the temperature at trees/plants, oscillates
10–15 °C and does NOT trend, so the runaway is in the atmospheric/interior mean, not at the creatures' feet.)

**4 — The seabed vent: SUPPLY PATH FIXED (merged `a4f8098`); the SHAPE is still unproven.** The root cause
was worse than this entry described. `_lava` was never refreshed from the device *at all* — the channel is
demand-gated and `erupt_source` never requested it, so the readback scatter's `size() == n` guard never
fired and the mirror stayed a monotonic running total of every deposit ever made, which the step then wrote
over the live GPU buffer every step. That undid **M5 solidify** (so the vent minted mineral and the column
plugged at the speed of the upload, not the supply — every height ever measured, `ISLAND_FREEBOARD` included,
was measuring that) and **annihilated `lava_flow`'s lateral spread** each step, which is why the pile could
only ever grow straight up as a picket fence. It also explains the three substrate rules that "moved neither
height nor shape": their output was overwritten before it could compound. `erupt_source` now uses the sparse
device add. Verified: `lava_total` 297.60 → 50.80 at `field_step` 590.
**What is still owed:** the behavioural proof, in screenshots — that a vent now builds a connected, spreading
pile and keeps erupting past frame 300. Re-run the three parked substrate rules against the fixed path before
concluding anything about them; a patch of the `lava_flow` downslope leg + `magma_buoy` confinement gate is
worth recovering from the session scratchpad if anyone still wants them.

**5 — Mask-exit vs displacement in the H₂O ledger.** ~1080–1755 units leave the counted mask by
`field_step 767` (moisture dominant) while `MineralStamp3D._settle_h2o` displaces only 23–306, a 13× spread
across runs that is itself unexplained. Mass is not destroyed — it is sealed in cells now classified rock, and
the budget's residual matches `h2o_buried` exactly, 3 runs of 3. Two questions: should pore water be displaced
into neighbours or is burying it correct, and should the ledger report it as a named compartment rather than
letting it look like a decline. `LA_H2O_BUDGET=1` is the instrument.

**6 — Delete the two surviving band-aids, once #1 lands.** Both suppress runaways whose opposing term is the
radiative sink, so neither can come out before the energy balance closes, and **removing them IS that work's
acceptance test.** `CLOUD_OPACITY_CAP` (+ `INSOLATION_MIN/MAX`) in `SystemOrbits.gd` caps a cloud→insolation
feedback whose stabiliser is σεT⁴. `VOLCANO_CHANCE_CONVERGENT = 0.3` in `PlateTectonics.gd` keeps arc
volcanoes rare because heat entering the field has nowhere to leave. To settle the second, raise it by a large
factor (0.3 → 1.0) and compare `temp_mean` / `temp_ground_mean` at equal `field_step` over three runs per arm.
If a runaway returns, **say so** — do not quietly restore the clamp and claim the root fix.

**7 — Residual non-determinism (low priority).** With the cognition budget moved to the sim clock, three runs
at `--fixed-fps 60` give identical creature counts and `decision` within 2, but `escalations` (1/2/0) and
`slow_brain_calls` (11/12/9) still vary: an escalation holds its slot until its answer *arrives*, which is
real time whenever a model is answering. Field numbers are unaffected. A fix would resolve on a fixed frame
budget rather than on arrival, buffering early answers — probably a determinism-mode option, since real play
wants the answer as soon as it exists.

**8 — A4: rebuild `VoxelWorld` → Anima. HELD for supervised handling.** Refactor the 730-line inline
`VoxelWorld._ready` to compose from `SimWorld` + the reusable nodes, and rename the game `VoxelWorld` →
**Anima**. It rebuilds the composition root, so it needs launched-window verification.

---

## 0.4 — WHAT IS LEFT

The substrate is genuinely most of the way there; almost every gap below is **coupling / read-out of fields
already simulated**, not new systems. Guiding: dissolve-don't-patch · emergent-everything · perf-first ·
Big-O + activity-bubble LOD · **fakery = the LOD tier** (full sim in the compute-bubble; cheap analytic
stand-ins for distant/dormant/offscreen, re-materialize on approach).

### Keystone B — moisture → vegetation → albedo. The one genuinely owed keystone.

**Photosynthesis is being driven by the temperature field standing in for the sun.** R19 is
`_rec(OPTIMUM_BAND, PHOTO_RATE, LIGHT, [[CO2,1.0],[SOIL_ROOT,PHOTO_WATER_COST],[FERT,FERT_UPTAKE_COST]], …)`
after the 2026-07-29 rework, but the underlying proxy issue is the thing to check first: `MaterialReactions3D.gd`
had `temp` as the daylight proxy, and its own comment said so — *"temp = the daylight proxy; the day side is
warmer → fixes more"*. Consequences if any of that survives: a hot desert fixes carbon at night, a bright cold
polar summer barely fixes any, and lava and wildfires feed plants.

It is a plumbing gap, not a design choice, and the kernel admits it: *"NEAR_GROUND / DAYLIGHT: no live record
needs them yet (would require radial+sun_dir bindings)"* (`reactions_sphere3d.glsl:186`). Both already exist in
the driver — `heat3d_solar_sphere3d.glsl` computes real per-cell insolation as `max(0, dot(cell_radial,
sun_dir))`, `radial` is a bound per-cell buffer, and `sun_dir` is a pass-context value (`ThermalPass.gd:150`,
`:285-287`). So: bind real light into the reaction engine, make R19 light-driven with CO₂/water/nutrient as
Liebig limits and transpiration as a conserving soil→moisture transfer, and delete the temp-as-daylight proxy.
Adding a moisture cap on top of the proxy would cement it.

Also still owed: `grep -n moisture MaterialReactions3D.gd` returned one comment about H₂O conservation and
nothing else, so a dry plateau greens like a rainforest.

### Keystone C — activity-bubble LOD. The asymptotic half.

Shipped in its cheap form (`kernels3d/activity_sphere3d.glsl` + `sphere_passes/ActivityPass.gd`, registered at
`MaterialSphereGPU3D.gd:55`), computing a wake-bubble plus camera-proximity relevance with an
`LA_NO_ACTIVITY_LOD=1` A/B knob. But gating is per-cell stride and early-out, so **every kernel still
dispatches the full grid and cells merely bail** — that saves ALU, not dispatch or bandwidth. CLAUDE.md
sanctions the early-out form as the floor, so this is a deliberate stopping point, not a relic.
**Before building the O(active) indirect-dispatch version, run the `LA_NO_ACTIVITY_LOD=1` A/B that already
exists** and find out whether the shipped gating buys measurable frame time. That measurement decides whether
the rewrite is worth it.

**Deferrals, with reasons, so nobody re-attempts the unsafe ones.** The old "extend the gate to the other 8
passes" instruction was WRONG as written — several of those passes are continuous planetary forcings, not
sparse events, and gating them on an activity bubble silently disables them almost everywhere. Deliberately
ungated: `magma_buoy_sphere3d.glsl` (its 2-pass donor/receiver transfer loses mass under per-thread gating —
needs wake-on-inject first), `AtmospherePass` (the ocean is a perpetual unconditional source), `ReactionsPass`
(background biology is active almost everywhere — would need per-record gate bits), `EcoSurfacePass` (mixed
sparsity, already cheap), `SolidDerivePass` (runs before relevance exists), and the continuous legs of
`ThermalPass` / `GasWindPass`.

### Keystone A — erosion. Behavioural proof still owed.

The pickup kernel ships (`kernels3d/erosion_pickup_sphere3d.glsl` via `sphere_passes/ErosionPickupPass.gd`,
registered at `MaterialSphereGPU3D.gd:51` immediately before `ReactionsPass` so SETTLE reads freshly-scoured
`susp` in the same step), and `susp` is a live phase in the mineral ledger. **What is owed is the behavioural
proof** that deltas, beaches, canyons and floodplains actually form over geological time — which needs
Keystone C's fast-forward before it can be observed.

### Still owed elsewhere

- **T1:** hot springs · moisture growth-gate (Keystone B's sim half).
- **T2:** weathering + lithification (2 DEFS records) · snow render from the real `_snow` field with an honest
  0 °C freeze · sea-ice/snow-line behaviour once #1 lands · emergent river supply (highland baseflow + snowmelt).
- **T3:** cloud→ground shadows · re-enable sun shadows · grass/ground-cover [FAKE] · climate-typed flora
  envelopes · glacier flow (retarget slump to `_snow`) · cheap strata [FAKE] · lava tubes (edge-cooling).
- **T4:** geotime `--geotime=N` bake → bake-then-freeze orchestration (the snapshot path exists) · season/year
  retune.

**FAKE ledger (deliberate):** tides · far/orbit ocean (mid/ground MUST be real) · accretion (see-once) · plate
tectonics (kinematic Voronoi; true tectonics = 0.5) · grass / clouds / strata.
*(The static sea and static lakes were on this list as "the livability anchor — a fully-conserved cycle drains
land dry". They are GONE as of 2026-07-30: the static mask made the sea evaporate water it never lost, minting
+6263 units. The conserved cycle does drain the land drier, which is item #2 above, but that is a world-gen
water-budget question, not a reason to keep a mask that invents mass.)*

**Livability risks:** volcano thermal runaway (→ the radiative sink, item #1) · land drains dry (→ #2, spring
baseflow) · erosion mass drift (→ cap by stream-power, verify against `mineral_total`).
*(The "high-`--fast` field desync" risk that sat here is REFUTED — there is no desync at any supported speed;
see `CLAUDE.md`'s corrected `--fast` bullet.)*

---

## LIVE ENGINE CONSTRAINTS (measured here — do not re-derive)

- **`buffer_get_data_async` returns STALE data** for compute-shader-written buffers on Godot 4.4+ (open engine
  bug [#105256](https://github.com/godotengine/godot/issues/105256)). Do not use it to fix readback. Forking
  the engine was considered and explicitly rejected.
- **There is NO GPU-side execution timer in this build.** `gpu_ms` is always `0.00`; `field_dispatch_ms`
  measures CPU-side command RECORDING, not shader execution. `capture_timestamp` is illegal while a compute
  list is open, and `get_captured_timestamps_count()` still reads 0 in this driver even for the smallest case.
  Metal's `get_captured_timestamp_gpu_time` always returns 0; Vulkan/MoltenVK works, and `LA_RENDER_DRIVER=vulkan`
  exists for a one-off diagnostic. **So read fps / `field_ms` as directional only, and never claim a
  dispatch-side perf win from them.**
- `field_readback_ms` (~4.4–4.7 ms) dominates `field_dispatch_ms` (~0.13–0.19 ms) by 25–30×, so dispatch-side
  savings stay invisible until readback is addressed.
- **Still owed on readback:** GPU-side reduction kernels for the `report()` aggregates that read back a FULL
  per-cell array just to sum it on the CPU — `hot_cell_count`, `active_cells`/`mean_relevance`, `soil_total`,
  `sediment_total`/`susp_total`, `_open_temp_stats`, `mineral_total`, `scent_cell_count`, in that order of
  callsite frequency × array size. Likely the larger remaining lever. Measure with `--bench=readback`.
- **The neighbour table and the tangent frame are SEPARATE tables, and must stay that way.** The six lateral
  slots are a 2-factor pairing chosen for slot-opposite reciprocity (what the gather kernels need); the tangent
  basis is face-local (what Coriolis needs). One table cannot be both — it is the discrete hairy-ball theorem,
  proved and recorded in `GODOT_BEST_PRACTICES.md`. Anything reading a vector across a seam must use the
  precomputed per-link rotation.

---

## 0.5 — THE LIVING CREATURES (moved from 0.4 — their entire life cycle)

Where 0.3 went broad (the game + emergent world), **0.4 goes deep on the creatures themselves — the whole arc
of a life**, all emergent (one substrate, reaction engine, config over `if species==X`). The creatures are the
star (local LLMs driving the minds). **This section is the approved, sequenced plan** (idea bank:
`docs/0.4_CREATURE_FEATURES.md`; split plan: `docs/0.4_PARALLELIZATION_GUIDE.md`).

> **The memory/social substrate this release needs already exists and is reachable.**
> `graph/BackstoryGraphService.gd` is wired to `LocalAgent`. It
> supplies factions with dated membership (the real version of `family_id`), persistent per-creature
> goals with state across days (the long-horizon intention the per-tick drive stack lacks), oral
> knowledge with transmission lineage and hop counts, and per-creature belief that can contradict world
> truth. Design the signal system with that in hand: the "deception" the scope note expects to fall out
> is `upsert_npc_belief` disagreeing with `upsert_world_truth`, and "dialects" are lineage distortion
> across hops. Nothing here needs a model. It is SQLite; only semantic recall wants embeddings.

**Scope decisions (locked):** full living-creatures release, **sequenced** (no single centerpiece) · build ONE
**general signal system first**, then every call/scent/display composes in (deception/dialects fall out) ·
**heritable, not yet evolving** (offspring inherit/blend; no mutation/selection loop pushed) · the **pet
companion is later/stretch** (ecosystem + communication richness first).

**Standing rule (user directive):** whenever a phase gives the chance, **add chemistry to the substrate** (new
conserved substances / DEFS reaction records) and **rip out hand-coded systems** that should be emergent —
don't route around them. This is the definition of done, not scope creep. Concrete 0.4 targets the exploration
already found: Phase 1 deletes the ad-hoc `match call_type` comms branches (`Creature.gd:992-1003`) + per-type
`EcologyStimulus` methods → one emergent signal+learned-meaning path; Phase 3 adds digestion/microbiome/soil
**as DEFS reactions** (chemistry), not hand-coded metabolism; personality/diet become heritable genome config,
not `if species==X`. See [[dissolve-dont-patch]].

### Reuse-vs-build ground truth (from code exploration — anchors)
| Concern | Verdict | Anchor |
|---|---|---|
| Learning core (`reinforce_cue`, `decide`, `learn_and_veto`, reward/valence, veto, social `observe`) | reuse, **generalize off `LocalAgentCreature`** | `cognition/Cognition.gd` (545/144/201/278/227/424) |
| Slow brain (LLM + teacher, budget, perception scans) | reuse, generalize | `cognition/CognitionScheduler.gd:73,220` |
| Kinship graph + `family_id` · Leadership/leader-pin (= pet's "player as Leader") | reuse as-is | `ecology/KinshipGraph.gd` · `actors/creature/CreatureLeadership.gd` |
| Genome (crossover+mutate exist; `eye_fov`/`sense_radius` acuity already heritable) | reuse, **extend** (add personality + diet genes) | `cognition/Genome.gd` (22/92/113) |
| Scent field (5 GPU channels evolve on-device: prey/predator/blood/food/alarm) | **partial — finish CPU wiring** (~4 sites) | GPU live `EcoSurfacePass.gd:205`; stubbed `MaterialField3D.gd:908-937`, `MaterialFieldSphereStep3D.gd:124-145` |
| Sound calls / scare bus (ad-hoc per-type today) | reuse, **generalize** | `ecology/EcologyStimulus.gd:96-144`, `Creature.gd:979-1003` |
| Perception spatial index · Shock/charge read+emit (charge lacks `gradient()`) | reuse as-is | `actors/creature/SpatialIndex.gd` · `MaterialShock3D.gd`, `MaterialField3D.gd:817,1149` |
| Generic signal/stimulus + learned-meaning layer | **must build** (the Phase-1 spine) | only ad-hoc `EcologyStimulus.gd` |
| `Creature.gd` god-file (1042; every workstream routes through it) | reuse, **split #1** | `actors/Creature.gd` |
| Graded life stages / body growth (binary `is_mature()` only) · courtship/gestation | **must build** | `Creature.gd:1017`, `EcologyService.gd:485` |

### Phase 0 — FOUNDATIONS (serialized, one-owner; FIRST, so the fan-out stays parallel)
- [ ] Split `Creature.gd` → modules under `actors/creature/` (hand/carry/throw · damage/death/fling · think-LOD ·
  movement · social/calls · life-stage · nesting-glue · state-tint); split `EcologyService.gd` → Spawner/
  Breeding/Plants/Aquatic (guide Wave 0a).
- [ ] **Generalize cognition off `LocalAgentCreature`** — a small duck-typed cognizer interface + `cognition/adapters/`
  per actor kind (unblocks bee/fish/pet minds). Keep `reinforce_cue` verbatim.
- [ ] **Finish the scent-field wiring** — scatter `_f._scent` in `_apply_readback` (+ `"scent"` in driver
  `read()`), implement `scent_at`/`scent_gradient` (5-packed `base=ch*cell_count`), `deposit_*` → seed +
  `_scent_dirty`, dirty-gated `set_field("scent", …)` upload. Same pattern shock/charge already use.
- [ ] **Extend `Genome`** — add personality/temperament gene(s) + heritable diet/appearance; mutation modest.
- [ ] **Goal-directed foraging: FIND + STEER (user-flagged, foundational — do via workflow/subagents).** Two
  primitives every forager / hunter / pollinator needs and lacks today: **(A) sense the nearest edible** — query
  the shared 3D spatial index by the creature's diet → a target; **(B) steer locomotion toward a chosen
  direction/target** (goal-seek, not just wander/flee). Right now forage has NO food-seeking steer, so a hungry
  bee can't approach a flower (0.3 fell back to proximity pollination). Add both to the generalized cognition +
  radial locomotion so true nectar-seeking, grazing-toward-pasture, and pursuit hunting fall out emergently.

### Phase 1 — THE SIGNAL SPINE (build once; communication emerges)
- [ ] One general **Signal** system: emit (a typed record: medium + payload + intensity) into a medium
  (scent/sound/shock/charge/posture/touch) → perceive (via `LASpatialIndex` + field reads) → **meaning is the
  learned response** (`reinforce_cue`). Refactor the ad-hoc `EcologyStimulus` methods + `Creature.hear_call`
  `match` branches into this path; each concrete signal (alarm scent, mating call, threat display) becomes a
  **data record**, not code. Honest-vs-deceptive signalling, dialects, skepticism fall out.

### Phase 2 — FAN OUT over the spine (Workflow — each workstream = "config a signal + a learned response")
- [ ] **W-COMMS:** scent trails, alarm/mating/contact/food calls, visual displays/postures, touch/grooming,
  seismic (shock), electric (charge + `charge_gradient()`), bioluminescence.
- [ ] **W-SOCIAL:** dominance hierarchy (extend leadership), cooperation (pack hunt/mobbing/sentinel/
  alloparenting), bonding/alliances/reciprocity, play, territory (scent boundaries), migration, culture-spread.
- [ ] **W-FISH minds** (generalized cognition via a fish adapter). **W-BEES** learning + pollinator-driven
  flower selection (needs bee cognition + scent — both unblocked by Phase 0; coordinate with 0.3 #76).
- [ ] **W-TRAITS:** circadian/dormancy (hibernation/torpor/estivation — compose with compute-bubble LOD),
  thermoregulation, crypsis/mimicry, predator/prey tactics, foraging/caching, parental care/teaching, disease/
  parasites, personality-driven behavior, emotional states, habituation.
- [ ] **W-LIFECYCLE:** graded life stages + body-growth curves, courtship/mating (→ kinship mate edge), aging/
  senescence.

### Phase 3 — THE NUTRIENT / METABOLIC CYCLE (#75 flagship)
- [ ] Digestion over time (efficiency set by the microbiome; herbivores need gut flora) + gut-microbiome benefit +
  excretion/pooping (→ soil detritus/fertility + spreads gut bacteria) + soil bacteria/nitrogen-fixers (→ plants
  grow) + death decomposition (0.3 shipped the field-side taste). Bacterial **roles as DEFS reactions**;
  conserved matter food→energy+waste→soil→plants→food.
  **The loop already closes** — `CreatureExcretion` deposits real feces detritus, R15 fungus-decompose produces
  fertility, R19 consumes FERT as a Liebig-limiting reactant — so what this phase still owes is the deeper
  metabolism rather than the cycle: digestion over time (a gut buffer instead of instant `feed()`), the
  microbiome efficiency scalar, and nitrogen-fixer bacteria as a genuinely new DEFS reaction (R-NFIX).

### Phase 4 — THE PET COMPANION (stretch — end of 0.4 or 0.5)
- [ ] Large animal + player pinned as permanent **Leader** + **operant conditioning** (`reinforce_cue`) +
  non-verbal need/emotion readout UX. "Not a special system" — the shared richness focused on one bonded
  individual. Only if the ecosystem lands with room.

### Phase 5 — REUSABLE CREATURE NODE + perf/platform (deferred)
- [ ] **Reusable creature NODE (#dual-purpose gap)** — decouple `Creature` behind small interfaces + a default
  adapter so a bare "AgentCreature" works standalone (rules-based) and lights up with a sim + a model.
- [ ] **Async/partial GPU field readback** (#72 — dominant field cost; speeds every verify). **HTML5 web-export
  spike** (#44 — browser-local LLM via WASM/WebGPU + `JavaScriptBridge`, chat/agent first). **Composition-per-
  cell** (#30 — DEFS ~80% there; thin slice when a metal/ore/salt feature is wanted).

### Chemistry to add + hand-coded to rip out (specifics — the standing rule, grounded)
**New DEFS reactions/channels** (`material/MaterialReactions3D.gd`, `_rec(rate_model, k, driver, reactants[],
products[], gate_mask, threshold, driver2)`; slots biomass/O₂/CO₂/detritus/fungus/fertility already exist — the
carbon loop **R15 fungus-decompose** `detritus+O₂→CO₂+fertility` and **R20 respiration** `biomass+O₂→CO₂+detritus`
already close it):
- **Excretion → soil (mostly REUSE):** creatures deposit feces into the existing **detritus** channel
  (`deposit_detritus`) → **R15** already rots it → fertility. Only add a faster **R-MANURE** (BILINEAR decompose
  on a new `manure` slot) if leaf-litter rate is too slow for feces to enrich noticeably.
- **Nitrogen fixation → fertility (GENUINELY NEW):** add an atmospheric **nitrogen** slot + **R-NFIX**
  `nitrogen(air)→fertility(soil)`, BILINEAR/CONST gated (`gate_mask`) on legume-biomass × moisture (the N-fixer
  bacterial role the user named). Conserved (draws from the N pool); makes fertility actually replenish → plants
  regrow. Without this the loop leaks fertility and can't sustain.
- **Death decomposition = UNIFY, do NOT re-add:** a carcass becomes **biomass/detritus in the field** → the
  existing **R20 + R15** rot it → CO₂ + fertility. No new reaction.
- **Digestion + gut microbiome = per-creature metabolism, NOT a field CA** — lives in `CreatureMetabolism`
  (gut buffer: ingested biomass → energy + waste over time, efficiency × microbiome scalar); only its **waste
  output** deposits into field detritus. State this boundary so it isn't mis-built as a DEFS record.

**Hand-coded systems to rip out → emergent** (delete + route through substrate/cognition):
- **Comms (Phase 1):** `Creature.gd:992-1003` `hear_call` `match call_type` branches + per-type
  `EcologyStimulus` methods (`broadcast_call`/`broadcast_scare`, :96-144) → ONE signal record + `reinforce_cue`
  learned meaning.
- **Eating (Phase 3):** instant `feed()`→energy (`Creature.gd:1031` `feed`/`food_profile`/`nutrition`) →
  digestion-over-time gut buffer × microbiome efficiency.
- **Death decomposition (Phase 3):** the bespoke `CreatureRagdoll` `MICROBE_SEED`/`DECOMP_RATE_PER_SEC` bloom
  (0.3's field-side taste) → carcass = biomass/detritus rotted by R20+R15; delete the constants.
- **Breeding (Phase 2 W-LIFECYCLE):** population-tick `EcologyService._tick_breeding` (:485, every 2 s fraction +
  `pop_cap`) → emergent per-creature courtship/mate-seeking + gestation; population regulated by food/energy/
  space, not a global cap.
- **Fish (Phase 2 W-FISH):** brainless config-band swim logic in `Fish.gd` → generalized cognition via a fish
  adapter. **Any `if species==X`** → genome/config (the new personality/diet genes).

### Field/GPU work left in the 0.4 field pass
*(Corrected 2026-08-03. Three "confirmed bugs" sat here — combustion writing O₂/CO₂ to the wrong ping-pong half,
the fuel channel allocated to zeros and never populated, and grown storm charge unable to fire a bolt. **All
three were already fixed in-tree**, by commits at or before `9883fec`, i.e. before the `sim/`+`game/` split, so
these bullets had been sending work at solved problems for weeks. What is actually there now:
`FireDustPass.gd:85-90` binds `[6, o2[back]], [7, co2[back]]` with a comment explaining why; a whole module,
`MaterialSurfaceSeed3D.gd`, seeds fuel on ground-surface cells and refills it from biomass every 40 steps
(`:87-102`), uploaded at `MaterialFieldSphereStep3D.gd:203-207`; and `MaterialCharge3D.gd:39-44` closes the
strided-probe blind spot with `FULL_SCAN_EVERY = 20`, after which `:98-99` sets `_charge_woke` from a true
all-cell peak. Verify before re-adding any of them.)*
- [ ] **Energy chemistry 0.4 deepening:** the 0.3 muscle-lactate/conserve-drive is the first step — deepen into full
  ATP / glycogen / O₂-gated aerobic-vs-anaerobic chemistry (ties into the nutrient cycle + DNA-driven metabolism).

### Orchestration + verification
Phase 0 = serialized (splits + generalize + wiring). Phases 1→2 = **Workflow fan-out** (`pipeline()`
implement→verify per workstream; worktree isolation; per-agent pre-write contract + behavioural SIM_REPORT gate;
adversarial verify for correctness-sensitive bits). Main thread integrates/merges/gates. Verify behaviourally:
`scripts/smoke_check.sh` while iterating; a long `--run-frames=1500`/`--fast` run + `--shoot` at each phase gate
(population stable, herds/kinship intact, no NaN/runaway, fps good; scent round-trips, a signal's meaning is
learned-not-branched, fish/bees learn, the nutrient loop conserves matter). Windowed launch for the pet.

## 0.6 — THE FULL SOLAR SYSTEM (moved from 0.5 by the 2026-07-12 pivot; 0.4=planet, 0.5=creatures)

0.3 shipped the **moving-frame** solar system: the sim stays centred on the planet, but a real heliocentric
orbital STATE drives the sun across the sky, seasons (axial tilt), insolation (bake/freeze/impact-winter), a
moon, and momentum knock-out-of-orbit. 0.5 makes the system **literal + navigable**:
- [ ] **Literal planet flight through space** — migrate the GPU field/ocean to a **moving-frame body-local**
  representation so the planet node can actually translate (not just its orbital state). Unblocks everything
  below. (The one 0.3 relic: `MaterialField`/ocean/water are world-anchored at the planet's start.)
- [ ] **Full multi-body physics** — planets + moons + sun as first-class bodies on real orbits; fly between
  them; land on the moon (give it terrain/field); N-body for the bodies themselves, not just test particles.
- [ ] **Solar-system view renders the real orbits** (the campaign capstone) from the body states.
- [ ] **Persist + save** the orbital state; barycentre drift; slingshot missions; comets.

## How to run / verify
- **Non-interactive (off-screen, focus-safe, SILENT audio) — always use the wrapper:**
  `scripts/run_sim_offscreen.sh --path . addons/local_agents/game/VoxelWorld.tscn -- --run-frames=N`
  → one `SIM_REPORT={…}` line (gauges: fps/field_ms/physics_ms/leaders/followers/…; field/population/cognition
  sections). `--shoot=<png>` for a screenshot; `--campaign`/`--sandbox` to boot the sim in a mode; disaster
  triggers `--auto-{meteor,volcano,lightning,tornado,thunderstorm,hurricane,earthquake}`; `--auto-select`.
  `LA_RES=WxH` sets resolution; `LA_NO_STREAMER=1` skips the LLM streamer; `LA_NO_AUDIO=0`/`--audio` forces
  audio on in dev. Acceptance is BEHAVIOURAL (aggregates sane, no NaN/runaway, fps good) — no CPU↔GPU parity.
- **Gotcha:** a NEW `.gd` `class_name` / `.gdextension` / new `.glsl` registers only after an editor scan:
  `godot --headless --path . --editor --quit-after 400`. Native changes (e.g. `LAProcess`) need the extension
  rebuilt (CI `build-extension.yml` or the local build).
- **Lint/tests:** `scripts/agent_harness.sh <lint|fast|bounded|extension>`; `scripts/check_max_file_length.sh`.
- **REPRODUCIBLE MEASUREMENTS — add `--fixed-fps 60` (2026-07-30).** It is a Godot ENGINE flag, so it goes
  BEFORE the `--` separator: `run_sim_offscreen.sh --path . --fixed-fps 60 <scene> -- --run-frames=N ...`.
  With it, field/climate/conservation numbers reproduce: three runs gave `soil_total` and `biomass_total`
  identical and `creatures` identical. Without it they do not — three runs at one seed gave creatures
  169/172/180 and phenomenon totals 11/11/17.
  - **Buy horizon with MORE FRAMES, not a lower rate.** At `--fixed-fps 60` 150 frames covers only
    `field_step 46` against ~746 unfixed, but frames are nearly free in wall clock (the windowed scene never
    exits, so the wrapper waits out `LA_RUN_TIMEOUT` regardless). `--fixed-fps 10` gives 6x the horizon and
    LOSES determinism, because at `--fast=2` a 0.1 s delta lands exactly on the field's 0.2 s per-frame
    ceiling where the excess is discarded, and the longer horizon lets the agents feed back into the field.
  - **Still needs repeats:** anything gated on escalation or decision counts (#27). `escalations` and
    `slow_brain_calls` still vary, because an escalation holds a slot until its answer arrives and that
    latency is real time. Field numbers are unaffected.
  - The two fixes that made this work: the cognition budget now counts physics frames instead of
    `Time.get_ticks_msec()` (`067552a`), and `--seed` now actually reaches `LASimRng`, which nothing had ever
    called `reset()` on (`61206c1`).

## Where everything lives
- **Front end:** `scenes/menu/` (MainMenu · SettingsMenu + Graphics/Sim sections · CreditsMenu · HelpMenu/tabs ·
  GameSettings/GameMode/GameSave). **Game systems:** `scenes/simulation/voxel/game/` (GameProgression ·
  WorldSaveState/Controller). **Composition root:** `VoxelWorld.gd` (extract-only). **Quit:** `scenes/AppExit.gd`
  + native `LAProcess`.
- **THE substrate:** `material/MaterialField3D.gd` (thin facade, extract-only) + modules `MaterialSphereGPU3D`
  (GPU host) · `sphere_passes/*` · `kernels3d/*_sphere3d.glsl` (authoritative) · `MaterialField{Queries,Inject,
  Snapshot}3D` · `Material{Ejecta,Charge,Shock}3D` · `MaterialReactions3D` (DEFS) · `WaterParticles` ·
  `mesh/VegetationRenderer`.
- **Actors:** `actors/{Creature,Fish,Plant,Tree,Rock,Nest,Food}` + `actors/creature/*` (leadership/metabolism/
  flocking/think/senses/nesting/ragdoll/field-forces); disasters `actors/{Meteor,Volcano,…}` (dissolved →
  seeds/visuals). **Cognition:** `cognition/*` (value-based policy + sparing local-LLM slow brain).
  **Ecology:** `ecology/{EcologyService,EcologySpawner,KinshipGraph}`. **Events/streamer:** `events/*`,
  `streamer/*`. **UI:** `ui/*` (HUD, thought panel, debug, tutorial). **Data:** `data/species/**/*.json`.
- **Reusable addon (dev tool):** `agents/` (LocalAgent + Agent3D) · `runtime/` · `ui/ModelManager*` ·
  `examples/` (AgentQuickstart, demos, DemoLauncher). **Design:** `EMERGENCE.md`, `docs/TRAILER.md`, `docs/EXPORT.md`.

## North-star
- **Dissolve, don't patch (THE CORE):** ONE physical substrate (`MaterialField3D`) — matter with pressure/
  temperature/phase/gravity/momentum + chemistry (a generic DEFS reaction engine). Named phenomena
  (volcano, eruption, tornado, storm, weather, decomposition, …) have **zero dedicated behavior code**; they
  EMERGE. Removing a hack (a timer/cap/`restock`-from-nowhere/special-case) and making it emergent is the
  **definition of done, not an optional feature.** Success = special-case code DELETED.
- **Emergent-everything** · **3D always** (no 2.5D holdovers) · **GPU/native-first, GPU-GLSL-only** (no CPU
  oracles) · **perf-first** (playable frame-rate is first-class) · **Big-O first-class** (better-scaling
  structures + do-less-by-relevance/LOD + activity bubbles) · **bias to action** · **config over `if
  species==X`**.
- **Dual-purpose:** a reusable Godot dev tool (the `LocalAgent` LLM node) AND a full game that is the
  flagship demo. Local LLMs drive creature cognition + the streamer, fully offline — headline this.

---

## Guiding principle
**dissolve-don't-patch + emergent-everything** — one substrate, universal rules, named phenomena fall out;
removing a hack to make behavior emergent is the definition of done. See `EMERGENCE.md`.
