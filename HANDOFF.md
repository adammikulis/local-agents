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

**Branch state (2026-08-03).** `0.4-dev` is the integration branch, lint green. Live worktrees beside the
primary checkout, none merged:
- **`feature/energy-balance`** — the big one. Real emissivity from the hydrostatic `pressure` channel, real
  solar constant (1361), water freezing at 0 °C, surface balance sub-steps instead of truncating, Darcy as a
  gradient, oxygen + fertility closed by identity, and the climate/conservation instruments merged in. It
  also **collapses the biosphere on purpose** — see item #1.
- **`feature/conservation-fixes`** — craters flood instead of becoming static sea; meteors excavate again.
- **`feature/planet-only`** — `--no-fauna` / `--planet-only`, and geology no longer waits for creatures.
- **`feature/constants-gate`** — `scripts/check_physical_constants.sh`, gating GLSL copies against `LAPhysical`.

`sorting.py` at repo root is the maintainer's, untracked — leave it.

**READ `CLAUDE.md` RULE ZERO FIRST.** Realism outranks everything. Every serious defect found on 2026-08-03
was catchable by one question — *is this how the world actually works?* — and every one was caught by the
maintainer rather than by an agent. Water froze at 12.5 °C; the core was 1300 °C (an erupting-basalt
temperature, a quarter of a real iron core); one thermal physiology covered a whale and a desert beetle;
volcanoes waited for rabbits.

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

**WHY it varied is now KNOWN and mostly FIXED (2026-08-03).** Two theories were refuted first and must not
be re-run: ambient disasters do NOT draw from Godot's global RNG (the director is fully routed through
`LASimRng`, and `VoxelDisasters.gd` has zero bare draws), and moving that director off the render clock onto
`_physics_process` — a real bug, and the same one `LAPlateTectonics` had fixed next door — did not narrow the
spread on its own. The actual cause was found by tracing draw counts per calling function under
`LA_RNG_TRACE=1`: `LAPlateTectonics` drew exactly 48 `_rand_unit` values in BOTH runs (it ticked
identically) while `_fire_boundary_event` fired 1 time in one and 3 in the other — its tick count was
deterministic, the VALUES it read were not, because creature cognition had moved the shared cursor first.
And cognition's draw count depends on how fast the LOCAL LLM answered, since an escalation holds its slot
until its answer arrives. **Inference latency was deciding the planet's geology.**
Fixed by SEPARATION, not more seeding: `LASimRng.for_domain(name)` gives each domain an independent stream
seeded by FNV-1a over the domain name mixed with the world seed. Planet-side callers (tectonics, the ambient
director, weather) draw from `"planet"`. Measured over 3 runs at one seed: planet-stream draws 151/151/151,
impacts 5/5/5, eruptions 3/3/3, `temp_mean` spread **12.7 °C → 0.70 °C**.
**Residual, and it is real coupling rather than a defect:** bolts still vary (12/10/14) because actors
physically inject into the field — a creature reaching water at a slightly different moment changes the
charge field. `--planet-only` removes it entirely, which is the mode to use for any planet measurement.

---

## DO THIS NEXT (ranked)

**THE ONE-LINE DIAGNOSIS, from four subsystem audits on 2026-08-03: every subsystem with a conservation
ledger conserves; every subsystem without one mints.** H₂O and mineral have ledgers and are honest. Carbon,
oxygen, fertility, biomass and energy had none — and every one of them was creating matter or energy from
nothing. The measurement gap is not a separate problem from the defects, it is the MECHANISM: where drift
would have shown, the physics had to be real. Ledgers now exist (`MaterialFieldMassBudget3D`,
`MaterialFieldEnergyBudget3D`, `MaterialFieldExtremes3D`, `MaterialFieldClimateSwing3D`) — use them, and
build one before trusting any new subsystem.

**1 — NITROGEN HAS NO SOURCE, AND THAT IS WHY THE BIOSPHERE COLLAPSED.** On `feature/energy-balance`.
Closing the fertility identity (`FERT_PER_DECOMPOSE` 1.5 → 0.05 = the 1/20 C:N ratio of leaf litter, uptake
matched at 0.05) drove `fert_drift_per_step` **+2.2406 → −0.0023** — the mint is gone — and `biomass_total`
to **7.24**, `fungus_total` to **13.61**, from ~1246 and ~1126. That collapse is the RESULT, not a
regression: the biosphere was being sustained by fertility created from nothing. R15 only recycles nitrogen
already in the litter and `FERT_DECAY` leaks some to nowhere, so the loop can only run down.
**Build the source: R-NFIX.** An atmospheric nitrogen channel with real fixation — biological (microbial /
legume, gated on biomass × moisture) and abiotic (lightning, which this sim already simulates and which
fixes real nitrogen on real planets). HANDOFF's own chemistry plan already called this "GENUINELY NEW …
Without this the loop leaks fertility and can't sustain." It was right; the measurement is the proof.
**Do NOT restore the mint.** That was tried once before — the same collapse is recorded in
`MaterialReactions3D.gd` above `FERT_UPTAKE_COST`, and the response then was to cut uptake 25× until
nutrient limitation stopped binding.

**2 — CARBON IS STILL MINTED, BY A PRESCRIBER.** `carbon_drift_per_step` is **+1.5664** (was +6.4811 before
the stoichiometry fix). The remainder is R12: `_co2` is seeded to **zero** (`MaterialField3D.gd` —
`_co2.resize()` with no `.fill()`, note the line above DOES fill `_o2`), and every carbon atom that has ever
existed in this sim is created by one `RELAX_TARGET` record. `reactions_sphere3d.glsl` skips the entire
reactant-cap block for that rate model, so it has no source pool and no conservation. It creates CO₂ at the
TOP OF THE ATMOSPHERE, ~78 world units above the plants, so primary productivity is set by a diffusion
coefficient — and `PHOTO_RATE` was measurably tuned against it ("the binding constraint is not the rate, it
is how fast CO₂ gets down here from the sky trace"). Same for O₂, pinned to ambient at 50%/step, which is
why the oxygen ledger reads flat rather than rising.
**Replace with:** a finite initial atmosphere + volcanic outgassing (exists) as the source and silicate
weathering (exists as D1, currently dead — see #5) as the sink. Then `carbon_total` becomes falsifiable.

**3 — THE REACTION ENGINE HAS NO CLOCK.** `ReactionsPass` uploads `dt`; `reactions_sphere3d.glsl` declares
it; **nothing reads it** (grep finds it only in comments, and `EcoSurfacePass` says so outright). Every rate
is per-FRAME, so no constant in the table can be compared to any measured chemical rate, and combustion
literally runs 16× slower far from the camera because the LOD stride skips steps and persists state. Make
every extent `x = k · dt · f(drivers)` and re-derive each k from a real timescale.

**4 — THE CORE IS A QUARTER OF A REAL CORE, AND IT NEVER DEPLETES.** Pinned at **1300 °C** — an erupting
basalt temperature. Earth's inner core is ~5200 °C, the core-mantle boundary ~3700. The comment admits the
value was chosen by what the surface could survive ("was pinned to 150 °C as an interim fix when … a hot
core baked the surface to ~110 °C"). `CORE_FLUX` on the energy branch rate-limits it but it is still an
unbounded source, so `temp_mean` climbs monotonically with nothing to stop it.
**Replace with:** a finite reservoir seeded at a real temperature that COOLS as it conducts outward, plus a
small radiogenic term — which is what actually keeps a planet's interior hot for 4.5 Gyr.

**5 — THE AQUIFER CANNOT REACH THE SURFACE, SO THERE ARE NO SPRINGS.** Two defects in one loop
(`soil_sphere3d.glsl`). The units bug is FIXED (Darcy is a gradient now, not a raw head in world units).
**Still open: the loop spends its outflow budget greedily in SLOT ORDER, and slot 0 is the inward
neighbour**, which `head_of()` makes lower-head unless brim-full — so whenever the cell below has headroom
the whole budget drains downward and no lateral flow or spring runs at all. Equilibrium is a water table
pinned ~2 cells below the surface everywhere. Fix with proportional allocation (compute all six desired
flows, scale them to the budget together); it restructures a conservation-critical gather, so verify it
alone. **This is what unblocks geysers, fumaroles and volcanic tidal pools** — the magma-free hot-spring
mechanism already exists and is emergent (`soil_sphere3d.glsl` mass-weights geothermal heat onto surfacing
groundwater); it just has no water to work with, and the ocean thermostat that used to quench it is already
deleted on `feature/energy-balance`.

**6 — THE CREATURE LAYER'S ENERGETICS ARE FICTIONAL** (the demography is not — see below). In order:
- **`CreatureDigestion.ambient_graze` mints food.** It reads the TEMPERATURE at the animal's feet, converts
  it to "lushness", and ingests — with no source and nothing decremented. Its own comment: *"never depletes,
  can't be crashed."* At the planet's coldest ground a herbivore earns ~2× its total burn rate, forever.
  Herbivore numbers are therefore set by `pop_cap`, a JSON integer, not by food; predators sit on that. It
  explains the death histogram (old age 665, starvation 23): **starvation is unreachable.** Make grazing
  debit the real biomass field, rate-limited by bite mechanics and gated on standing crop (Holling type II).
- **Nothing scales with body mass.** A fox is 19× a mouse's mass and burns identical energy. `size` drives
  health and food value but not metabolism, lifespan, gestation or thermal tolerance. `basal_metabolism` and
  `active_metabolism` genes exist on the DNA strand and are read by NOTHING. Kleiber (M^0.75) gives the whole
  roster's physiology from one measured mass per species instead of eleven hand-fitted constants.
- **One thermal physiology for every animal** — `WARM_COMFORT 28 / COOL_COMFORT 8 / LETHAL_HEAT 50 /
  LETHAL_COLD −18` as module consts, zero thermal keys across all 28 species JSONs, no gene. Ectotherms
  (16 of 28 species) should have Q10 scaling and CTmin/CTmax, not an endotherm's comfort band.
- **`Plant.gd` regrows a grazed plant fully in ~6 s** at a flat rate regardless of biomass, light, soil or
  season, and `feed()` never consumes it. **`Fish.gd` spends energy only `if not preys_on.is_empty()`** — bug,
  shrimp, jellyfish, crab and turtle never spend energy and cannot starve, and they are the base of the
  aquatic web.

**7 — GEOLOGY IS PROBABILITY ROLLS, NOT MECHANISM.** `D1 WEATHERING` is gated `GATE_SURFACE`, which this
file defines as the TOP OF THE ATMOSPHERE — `rock_fill` there is 0, so the record is **dead** and the
latitudinal weathering gradient it claims to produce does not exist. Its `WEATHER_TEMP = 20.0` is
`FREEZE_TEMP = 12.5`'s sibling, set explicitly from "this world's open-cell range", and the sign is
backwards (chemical weathering is Arrhenius and needs water; frost shattering needs freeze-thaw CYCLING, not
monotonic cold). `D2 LITHIFICATION` turns surface sediment to bedrock in ~50 steps with no burial and no
pressure, and can run in the same cell as D1 in the same step — a futile cycle. `PlateTectonics` rotates
plate SEEDS and moves no crust, so the Ring of Fire sweeps across stationary continents, and
`VENT_CHANCE_DIVERGENT = 0.12` is a second undocumented rarity roll beside the one already flagged.

**8 — `mineral_total` HAS NO DRIFT GAUGE.** It is called "the unification's proof object" and reports six
absolutes and zero deltas, while fed by an admitted "effectively infinite" mantle. Give it the H₂O ledger's
`*_drift_per_step` and a `LA_MINERAL_BUDGET`, unify the five legs' inclusion masks (`dust_total` masks on
open cells, the other four do not), and split `mineral_credited` (crater, a real transfer) from
`mineral_minted` (vent, a source) — they currently land in one gauge, which pollutes the documented
crater-vs-vent cross-check.

**9 — SMALLER, ALL MEASURED.**
- `fungus_peak()`, `fungus_cells()`, `detritus_peak()` are hardcoded `return 0.0` in `MaterialField3D.gd` —
  the decomposer loop has been reporting three permanent zeros while `fungus_total` reads real values.
- `MaterialFieldPhotoStats3D.sun_dir()` dots a WORLD-frame sun against a BODY-LOCAL radial, so `light_mean`
  and everything derived from it are only correct at identity rotation.
- The energy budget's global net is a lava thermometer (`energy_magma_share` 0.94 — 94% of longwave leaves
  through 386 of 8684 cells). **Read `energy_net_cool`, not `energy_net`.**
- Interaction radii were never scaled when the planet doubled (`PLANET_SCALE` covers world-gen geometry and
  `cell_size` only). Craters were the visible casualty and are fixed; `SEED_HEAT_R` 12 and `VAPOR_INJECT_R`
  14 are still sub-cell but degrade gracefully.
- Four dead `248.0` sea-radius fallbacks survive where the live value is 500.
- `--fixed-fps 60` fixes the field clock but NOT the disaster draw. The planet now has its own RNG stream
  (impacts 5/5/5, eruptions 3/3/3, temp spread 12.7 °C → 0.70 °C); the residual is actor splashes perturbing
  the charge field, which `--planet-only` removes entirely.

**10 — A4: rebuild `VoxelWorld` → Anima. HELD for supervised handling.** Refactor the inline
`VoxelWorld._ready` to compose from `SimWorld` + the reusable nodes, and rename the game `VoxelWorld` →
**Anima**. It rebuilds the composition root, so it needs launched-window verification.

**WHAT IS SOUND — do not rebuild these.** The H₂O ledger and its inclusion rule; the inject queue's
transfer/add split; the DEFS record engine (std430 layout verified) and every 1:1 conserving record
(R19's water leg, R21/R22, M3–M6); the neighbour/tangent tables; `REPOSE_TAN = 0.70` (the one
physically-sourced constant found in the whole geology scope); `MaterialFieldSoilBudget3D`; and on the
creature side per-creature courtship and gestation, the DNA codon strand, disease with acquired immunity,
the true-3D breathing rule, kinship, and carcass decomposition. The demography is real. The energetics
under it are not.
## 0.4 — WHAT IS LEFT

The substrate is genuinely most of the way there; almost every gap below is **coupling / read-out of fields
already simulated**, not new systems. Guiding: dissolve-don't-patch · emergent-everything · perf-first ·
Big-O + compaction on PHYSICAL predicates (never on camera distance — see the deleted-LOD warning below) ·
**fakery = the LOD tier** for ACTORS and RENDERING (cheap analytic stand-ins for distant/dormant/offscreen,
re-materialize on approach), not for the field's physics.

### Keystone B — vegetation → albedo. The light and water halves are DONE.

*(Corrected 2026-08-03. This section claimed photosynthesis was "being driven by the temperature field
standing in for the sun" and that a dry plateau "greens like a rainforest". Both are false now and the
evidence is in the code: `reactions_sphere3d.glsl` binds a per-cell `Radial` buffer, `sun_dir` rides the push
constant, `light_at()` computes `max(0, dot(cell_radial, sun_dir))`, and R19 drives on `LIGHT` with three
Liebig reactants — CO₂, `SOIL_ROOT` water, and FERT — plus transpiration as a conserving soil→moisture
transfer. The quoted kernel comment about needing radial+sun_dir bindings is stale. `PHOTO_WATER_COST` is a
real water limit, so water DOES gate growth.)*

**What is actually left of this keystone is the ALBEDO leg: vegetation does not affect reflectivity.** On
`0.4-dev` no albedo term exists in any kernel at all; `feature/energy-balance` introduces ground/water/ice
albedo but nothing for vegetation. A forest is much darker than bare ground or sand (broadleaf ~0.15-0.18,
conifer ~0.08-0.12, desert sand ~0.35-0.40), so vegetation cover genuinely changes the surface energy
balance, and the ice-albedo feedback's biological counterpart — greening darkens, darkening warms, warming
greens — cannot appear until it does. One term in the heat kernel's `albedo` mix, keyed on the biomass
channel it already has access to.

**Also still owed and now measurable:** whether primary production is water-limited where it should be.
`MaterialFieldPhotoStats3D` reports the Liebig limiter mix, but see item #9 — its `sun_dir()` dots a
world-frame sun against a body-local radial, so `light_mean` and anything derived from it are wrong except
at identity rotation. Fix that before drawing conclusions from it.

### Camera-relevance field LOD — DELETED 2026-08-03. Do not rebuild it.

*(This section used to say the activity-bubble LOD was "shipped in its cheap form" and ask for the
`LA_NO_ACTIVITY_LOD=1` A/B before building an O(active) version. The A/B was run and the answer was to delete
the mechanism, so the whole entry is replaced by this warning.)*

`ActivityPass` + `activity_sphere3d.glsl` scored every cell 0..1 from a local wake bubble AND its distance to
the camera, and seven kernels turned that score into a per-thread update stride. It **charged 4.5 C of global
mean temperature for a NEGATIVE perf return** (matched runs, seed 4242, 600 frames, identical disaster load:
`temp_mean` 38.65/39.11/39.20 gated vs 34.73/34.17 ungated; `field_ms` 5.210 gated vs 4.938 ungated). It also
made the planet's physics depend on where the player was looking, which is a Rule Zero violation on its face.
Gone; the measurement and the reasoning live in `MaterialSphereGPU3D.gd`'s header note.

**Two things found while deleting it, both worth keeping.** (1) `LA_NO_ACTIVITY_LOD=1` was never a clean
control — the `activity` channel allocates zero, so step 0 was still gated at stride 16, and that ONE step of
798 permanently moved `soil_total` by 18% (373.8 vs 442.8) and `sediment_total` by 5% (1005.2 vs 957.3). Any
figure quoted from that bypass is off by that much. (2) So the gate was never "behaviourally exact" as its
comments claimed: over an INTEGRATING process (a filling aquifer) a skipped step has no restoring force and
becomes a permanent offset.

**What survives, and is the pattern to copy:** `LavaCellListPass` + `cell_list_lava_sphere3d.glsl`, a real
O(active) compaction feeding an indirect dispatch, now keyed on the PHYSICAL predicate "this cell holds molten
rock in open space". If another kernel should scale with its phenomenon instead of the planet, compact it the
same way. Compact on what the matter is doing; never on where the viewer is.

**Which passes could take the same treatment, and which must not.** Compaction is only legal for a kernel
whose skip path is a bare `return` — anything that WRITES on its skip path (a ping-pong carry, a persist, a
scratch reset) needs that write hoisted somewhere that still covers every cell first. And several passes are
continuous planetary forcings that are active nearly everywhere, so compacting them would buy nothing:
`AtmospherePass` (the ocean is a perpetual unconditional source), `ReactionsPass` (background biology),
`EcoSurfacePass` (mixed sparsity, already cheap), `SolidDerivePass`, and the continuous legs of `ThermalPass`
/ `GasWindPass`. Note also that dispatch is only ~4% of field cost here (`field_dispatch_ms` 0.18 of
`field_ms` 5.2) while readback is ~75% — so the readback item below is the larger lever by an order of
magnitude, and any further dispatch-side work should justify itself against that.

### Keystone A — erosion. Behavioural proof still owed.

The pickup kernel ships (`kernels3d/erosion_pickup_sphere3d.glsl` via `sphere_passes/ErosionPickupPass.gd`,
registered at `MaterialSphereGPU3D.gd:51` immediately before `ReactionsPass` so SETTLE reads freshly-scoured
`susp` in the same step), and `susp` is a live phase in the mineral ledger. **What is owed is the behavioural
proof** that deltas, beaches, canyons and floodplains actually form over geological time. Use `--fast=8` to
compress that (see CLAUDE.md's measured throughput table); nothing else blocks the observation.

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
  per-cell array just to sum it on the CPU — `hot_cell_count`, `soil_total`,
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
  structures + O(active) compaction on physical predicates; relevance/LOD for actors and rendering, NOT for
  the field's physics) · **bias to action** · **config over `if species==X`**.
- **Dual-purpose:** a reusable Godot dev tool (the `LocalAgent` LLM node) AND a full game that is the
  flagship demo. Local LLMs drive creature cognition + the streamer, fully offline — headline this.

---

## Guiding principle
**dissolve-don't-patch + emergent-everything** — one substrate, universal rules, named phenomena fall out;
removing a hack to make behavior emergent is the definition of done. See `EMERGENCE.md`.
