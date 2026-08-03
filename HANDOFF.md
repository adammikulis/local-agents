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

**Branch state (2026-08-03, late).** `0.4-dev` is the integration branch, lint green, and **everything that
was outstanding is merged**. *(This block previously listed four live worktrees as unmerged. There were
actually SIX; `feature/climate-instruments` was a direct ancestor of `feature/energy-balance` so merging the
latter subsumed it, and `feature/thermal-traits` was an empty branch pointing at a `0.4-dev` ancestor. Worse,
`feature/planet-only` carried NO commits — its work existed only as four uncommitted files in the worktree,
one `git checkout .` from being lost. All six are now merged or retired and every worktree is pruned.)*

What landed, in merge order: `planet-only` (`LAAblate` + `--no-fauna`/`--planet-only`, and geology no longer
waits for a creature to spawn), `conservation-fixes` (craters flood; meteors excavate), `energy-balance`
(real emissivity from the hydrostatic `pressure` channel, solar constant 1361, water freezing at 0 °C from
`LAPhysical`, Darcy as a gradient, oxygen + fertility closed by identity, and the climate/conservation
instruments — it also **collapses the biosphere on purpose**, see item #1), `constants-gate`
(`scripts/check_physical_constants.sh`, now running inside `agent_harness.sh lint`).

`sorting.py` at repo root is the maintainer's, untracked — leave it.

**A FALSE ALARM THAT MUST NOT BE RE-RAISED:** an exploration pass reported that merging these branches would
revert `LASimRng.for_domain`, because `git diff 0.4-dev <branch> -- SimRng.gd` showed 87 deleted lines. That
is an artefact of a TWO-dot diff, which only shows the branches were 17 commits behind. The three-dot form
(`git diff 0.4-dev...<branch>`) is empty for all four — none of them touch the file. `for_domain` is intact
at `creatures/sim/SimRng.gd:181`.

**READ `CLAUDE.md` RULE ZERO FIRST.** Realism outranks everything. Every serious defect found on 2026-08-03
was catchable by one question — *is this how the world actually works?* — and every one was caught by the
maintainer rather than by an agent. Water froze at 12.5 °C; the core was 1300 °C (an erupting-basalt
temperature, a quarter of a real iron core); one thermal physiology covered a whale and a desert beetle;
volcanoes waited for rabbits.

**MEASUREMENT DISCIPLINE — and the platform is now GOOD, which is new.** With `--fixed-fps 60`, a fixed
seed, and `--no-fauna`/`--planet-only`, runs now reproduce well enough to A/B on. Measured 2026-08-03 over
six 600-frame runs at `--seed=4242`: phenomenon **8/8/8**, impact **5/5/5**, eruption **3/3/3**, `field_step`
**590** in every run, `temp_mean` spread **0.64 °C**. *(This block used to say runs are "not reproducible at
a fixed seed", citing 110/28/126 phenomena and a 19 °C `temp_mean` spread. That was measured BEFORE
`LASimRng.for_domain` gave the planet its own stream and before `--planet-only` existed. Both landed; the
claim is stale and was discouraging A/Bs that now work.)* Still true and still worth obeying:
- **Three runs per arm, minimum**, and **quote `phenomenon`, `phenomenon/impact`, `phenomenon/eruption` and
  `bolts` beside every scalar** — the residual spread is DISCRETE, dominated by how many disasters a run drew.
- **Compare at equal `field_sim_s` / `field_step`, never at equal `--run-frames`.**
- **Trust monotone trends within one run** far more than a level compared across runs.
- `--fixed-fps 60` is an ENGINE flag and goes BEFORE the `--`.
- **Even `--planet-only` is not perfectly deterministic yet** — three runs drew eruptions 4/3/3. Its commit
  message claims it is "the only mode that can be fully deterministic"; that is the goal, not the state.

**CHECK THE SIM IS ALIVE BEFORE YOU TRUST A NUMBER (2026-08-03, cost a full round of measurements).** The
reaction table was briefly unloadable — the record modules resolved a `class_name` through Godot's global
class cache, and the split was merged without an editor scan. `ReactionsPass`'s `load()` returned null and
the sim ran with **zero reaction records**: every same-cell reaction silently off. It still printed a
completely normal-looking `SIM_REPORT` with no error. The tells were only visible against a baseline —
`sediment_total` exactly **0.00** against 972, `susp_total` **2300** against 72, `lava_total` **1313**
against 37, `temp_mean` **152** against 39. Both halves are now fixed (the modules `extends` by resource
path, so parsing no longer depends on the cache; and an empty table is a hard `push_error`, not a 0-byte
SSBO). **The habit to keep: an aggregate that is exactly 0.00, or an order of magnitude off baseline, is a
broken pipeline until proven otherwise — not a result.**

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
ledger conserves; every subsystem without one mints.** H₂O has a ledger and is honest. Carbon,
oxygen, fertility, biomass and energy had none — and every one of them was creating matter or energy from
nothing. The measurement gap is not a separate problem from the defects, it is the MECHANISM: where drift
would have shown, the physics had to be real. Ledgers now exist (`MaterialFieldMassBudget3D`,
`MaterialFieldEnergyBudget3D`, `MaterialFieldExtremes3D`, `MaterialFieldClimateSwing3D`,
`MaterialFieldMineralBudget3D`) — use them, and build one before trusting any new subsystem.

*(Corrected 2026-08-03. This paragraph said "H₂O and mineral have ledgers and are honest". **Mineral had no
ledger** — six absolutes, zero deltas — which is why it was item 8 below. Given one, mineral turns out to be
the rule's exception in a mild way: 3 runs, `--planet-only`, 600 frames, seed 4242, 5 impacts / 3 eruptions
each, at `mineral_run_steps` 760 it does not mint, it LEAKS `mineral_net_per_step` **-0.043 / -0.042 /
-0.041** units per field step — about -0.10% of a ~32000-unit inventory over the run — while the vent's
declared mantle source runs +0.285/step, so the raw total rises and hid the leak.)*

**8b — THE MINERAL LEAK IS ENTIRELY `FireDustPass`, AND IT IS THE RELEVANCE GATE.** `LA_MINERAL_BUDGET=1`
(`MaterialFieldMineralProbe3D`, per-pass, same instrument shape as `LA_H2O_BUDGET`) reports `legs_all`
**0.0000 for eleven of the twelve passes** at every sample — solid_derive, water_slump_lava, lava_cell_list,
thermal, gas_wind, atmosphere, soil, erosion_pickup, reactions, activity, eco_surface — and `fire_dust`
-0.0008 → -0.0516/step as `dust` climbs 1.85 → 26.68. Mechanism to check: a stride-skipped cell copies
`dust_out = dust_in` (`dust_transport_sphere3d.glsl:83`) and never collects flux its running neighbours
already sent, and `dust_outscale_sphere3d.glsl:77` writes 0.0 for a gated cell, which the transport reads as
"that neighbour sent nothing". WHAT DECIDES IT: fix the gate to be flux-symmetric, re-run the probe, and
require `fire_dust` to read 0.0000. Compare with `LA_NO_ACTIVITY_LOD=1` first to confirm the gate is the
cause.

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
**Replace with:** a finite initial atmosphere + volcanic outgassing as the source and silicate weathering
(exists as D1, currently dead — see #7) as the sink. Then `carbon_total` becomes falsifiable.
*(Corrected 2026-08-03: this said "volcanic outgassing (exists)". It does NOT. No lava, magma or vent path in
the repo has a CO₂ leg — `MaterialFieldInject3D.add_lava`, `lava_phase`, `lava_flow` and `magma_buoy` contain
no `co2` reference at all. The only non-R12 carbon source in the entire sim is combustion,
`fire_sphere3d.glsl:137`. Outgassing has to be BUILT, not wired up.)*
Measured on the merged branch, `--no-fauna`: `carbon_drift_per_step` **+1.94/+2.37/+2.09**, `carbon_first`
720 against `carbon_total` ~5200 — carbon has grown 7× from its seeded value.

**3 — THE PHYSICS RATE DEPENDED ON WHERE THE CAMERA POINTED. Being fixed by DELETING the activity LOD.**
*(Corrected 2026-08-03. This item read "THE REACTION ENGINE HAS NO CLOCK … every rate is per-FRAME, so no
constant in the table can be compared to any measured chemical rate." The first half is overstated and the
second half is false. `MaterialFieldSphereStep3D.gd:14` sets `STEP_DT = 1.0/10.0` and the step loop consumes
the accumulator in fixed 0.1 s slices, so every `k` in the DEFS table IS a per-0.1-s rate and IS convertible
to a real timescale. `reactions_sphere3d.glsl:140` does declare a `dt` nothing reads, but under a fixed step
that is tidiness, not a defect — and the reaction engine is not relevance-gated at all, so the "combustion
runs 16× slower far from the camera" example was pointing at the wrong file.)*

**The real defect was in nine OTHER kernels**, which skipped time on a per-cell camera-relevance stride with
no catch-up (`fire_sphere3d.glsl:102-106` is the pattern: `fire_out[g] = fire_in[g]; return;`). Measured
2026-08-03, `LA_NO_ACTIVITY_LOD=1` as the control, matched disaster load, 3 runs vs 2:

| | LOD on | LOD off | |
|---|---|---|---|
| `active_cells` | 26,966 | 69,120 | skips **61%** of per-cell work |
| `field_ms` | 5.210 | **4.938** | **the LOD is SLOWER** |
| `field_dispatch_ms` | 0.188 | 0.184 | no difference |
| `temp_mean` | 38.65/39.11/39.20 | 34.73/34.17 | **4.5 °C of climate error** |
| `sediment_total` | 976.6/986.2/968.3 | 1000.5/1008.4 | −2.7%, arms do not overlap |

Skipping 61% of the work made it *slower*, because `ActivityPass` is itself a full-grid dispatch computing
relevance for every cell — you pay a whole pass to decide what to skip, and dispatch is only 4% of field
cost. So it charged 4.5 °C of physics error and bought nothing. **Maintainer decision: delete it** (keeping
the lava cell list, whose compaction is the genuinely good O(active) form — re-pointed at a physical
predicate instead of camera relevance).

**4 — THE CORE IS A QUARTER OF A REAL CORE, AND IT NEVER DEPLETES. IN FLIGHT.** Armed at **1300 °C** from a
call-site literal (`game/world/VoxelSpawnController.gd:138`) — an erupting-basalt temperature
(`LAPhysical.UPPER_MANTLE_C`). Earth's inner core is ~5200 °C (`INNER_CORE_C`), the core-mantle boundary
~3700 (`CORE_MANTLE_BOUNDARY_C`). `temp_max` reads **exactly 1300.0** in every run because of it. The
mechanism now lives in `material/MaterialFieldGeotherm3D.gd` (extracted 2026-08-03 out of the extract-only
field hub). `CORE_FLUX = 10.0` bounds how fast a core cell re-warms — that is what made the energy budget
closable at all — but the reservoir behind it is still infinite, and the module says so itself.
**Replace with:** a finite reservoir seeded at a real temperature that COOLS as it conducts outward, plus a
small radiogenic term — which is what actually keeps a planet's interior hot for 4.5 Gyr.
**And the geotherm around it is fitted, and inverted.** `kernels3d/heat_sphere3d.glsl:39-41` sets
`VOID_CONDUCT = 0.016` / `ROCK_CONDUCT = 0.004` with the comment *"Tuned so a 1300°C core coexists with a
temperate (~15-30°C) surface"* — a fitted physical constant by this repo's own rule. It is also backwards:
rock conducts heat ~100× **better** than still air (~2.5 vs ~0.026 W/m·K), not 4× worse. A planet keeps a
hot interior and a temperate surface because geothermal flux is negligible against solar (0.087 vs
1361 W/m², both already in `LAPhysical`) across kilometres of rock — not because rock insulates.

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

**8 — CRATERS EXCAVATE NOTHING, so half the mineral ledger has nothing to check.** Measured 2026-08-03 over
six 600-frame `--planet-only` runs, seed 4242: five impacts every run and `crater_cells 0`, `crater_mass 0.0`,
`mineral_inject_moved 0.0` in all six. `LAMeteor._on_impact` (`Meteor.gd:337-350`) carves the SDF and then
routes the substrate half through `_ecology.material_field()`, so the excavation is gated on the ECOLOGY
service — geology depending on biology, the same shape as "volcanoes waited for rabbits". Either that gate is
failing or every drawn strike lands where `resample_terrain`'s `is_solid` probe still reads rock
(`MaterialFieldInject3D.gd:445`). WHAT DECIDES IT: one run with `--auto-meteor` on known land; if
`crater_cells` is still 0 the gate is the cause, if it is nonzero the ambient strikes are all landing at sea.
Until this is settled the crater-vs-vent cross-check (`mineral_inject_moved` against `crater_mass`) has only
one side.

**9 — SMALLER, ALL MEASURED.**
- The energy budget's global net is a lava thermometer (`energy_magma_share` 0.94 — 94% of longwave leaves
  through 386 of 8684 cells). **Read `energy_net_cool`, not `energy_net`.**
- Interaction radii were never scaled when the planet doubled (`PLANET_SCALE` covers world-gen geometry and
  `cell_size` only). Craters were the visible casualty and are fixed; `SEED_HEAT_R` 12 and `VAPOR_INJECT_R`
  14 are still sub-cell but degrade gracefully.
- ONE dead `248.0` sea-radius fallback is left, `sphere_passes/ThermalPass.gd:166`, where the live value is
  500. *(Corrected 2026-08-03: this said "Four". The other three — `MaterialFieldAtmos3D.gd:119`,
  `WaterParticles.gd:24`, `game/world/BiomeShaderController.gd:58` — are gone, replaced by a direct
  `sea_radius()` read plus a `push_error` for the case the terrain is genuinely missing.)*
- `MaterialFieldChannels3D.breathable_o2_at` walks up to **4 cells** radially outward through rock before a
  creature counts as encased. Cells are 16 world units thick here (`8.0 * PLANET_SCALE`), so a creature 64
  units under solid rock still breathes. Sized as a margin against terrain relief inside one cell (relief is
  46+6 units), so it is not obviously wrong — but it is unverified either way, and settling it needs a
  windowed run with fauna and something buried.
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
Big-O + activity-bubble LOD · **fakery = the LOD tier** (full sim in the compute-bubble; cheap analytic
stand-ins for distant/dormant/offscreen, re-materialize on approach).

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
`MaterialFieldPhotoStats3D` reports the Liebig limiter mix, and its sun frame is now correct — but **discard
every light-vs-growth figure taken before 2026-08-03.** *(Corrected 2026-08-03. This said "its `sun_dir()`
dots a world-frame sun against a body-local radial, so `light_mean` and anything derived from it are wrong
except at identity rotation. Fix that before drawing conclusions from it." The frame is fixed —
`sun_dir()` now returns `dir_to_field(...)`, the same expression `MaterialFieldSphereStep3D.gd:158` hands the
GPU. The second half was the wrong emphasis: measured over three 600-frame runs, the two frames disagreed by
up to **135°**, yet `light_mean` moved only 8.1% and `light_lit_frac` 7.0%, because a rotated hemisphere is
still a hemisphere. What the error actually destroyed was the light-vs-response CONTRAST:
`biomass_lit_dark_ratio` read **1.35 / 1.32 / 1.41** in the world frame against **2.37 / 2.30** in the body
frame, and `biomass_dark_mean` was off by up to 99%. `light_mean` is nearly blind to this class of bug and is
the wrong sentinel for it.)*

### Keystone C — activity-bubble LOD. MEASURED, AND BEING DELETED. Do not rebuild it.

The A/B this section asked for was run on 2026-08-03, and the answer was decisive: the camera-relevance LOD
**costs 4.5 °C of climate error and is measurably SLOWER than not having it** (full table in item #3). It
skipped 61% of per-cell work and moved `field_ms` from 4.938 to 5.210, because `ActivityPass` is itself a
full-grid dispatch — you pay a whole pass to decide what to skip, and dispatch is only 4% of field cost.

**Do not build the O(active) indirect-dispatch version on this evidence.** Dispatch is not where the time
goes. The one piece worth keeping is the lava cell list, whose compaction + indirect dispatch is the good
form; it is being re-pointed at a physical predicate (a cell carries lava) instead of camera relevance.

**WHERE THE FIELD'S TIME ACTUALLY GOES** (measured, same runs, `field_ms` 5.210 total):

| | ms | share |
|---|---|---|
| `field_readback_ms` | 4.020 | **77%** |
| `field_pin_ms` | 0.660 | 13% |
| `field_dispatch_ms` | 0.188 | **4%** |
| `field_post_ms` | 0.097 | 2% |

So the ranked perf work is: **(1) GPU-side reduction kernels** — `MaterialFieldQueries3D` has 18 full-array
`for c in` loops that drag whole per-cell arrays back just to sum them on the CPU (`soil_total`,
`mineral_total`, `sediment_total`, `_open_temp_stats`, …). **(2) The core pin's full-channel upload** —
`field_pin_ms` exists only because `_pin_core_heat` edits `_temp` CPU-side, forcing a re-upload every step;
moving that boundary GPU-side deletes it (folded into item #4). **(3) The CPU instruments** —
`energy_scan_ms` is ~10.5 ms per sample at `HEAVY_EVERY_FRAMES = 8`, ~1.3 ms/frame amortised, a quarter of
the whole field step spent on telemetry.

**Deferrals, with reasons, so nobody re-attempts the unsafe ones.** The old "extend the gate to the other 8
passes" instruction was WRONG as written — several of those passes are continuous planetary forcings, not
sparse events, and gating them on an activity bubble silently disables them almost everywhere. Deliberately
ungated: `magma_buoy_sphere3d.glsl` (its 2-pass donor/receiver transfer loses mass under per-thread gating —
needs wake-on-inject first), `AtmospherePass` (the ocean is a perpetual unconditional source), `ReactionsPass`
(background biology is active almost everywhere — would need per-record gate bits), `EcoSurfacePass` (mixed
sparsity, already cheap), `SolidDerivePass` (runs before relevance exists), and the continuous legs of
`ThermalPass` / `GasWindPass`.

### Keystone A — erosion. THE TRANSPORT LEG DOES NOT EXIST, so sediment cannot move.

*(Corrected 2026-08-03. This said the proof "needs Keystone C's fast-forward before it can be observed."
That is wrong, and it sent the work at a scheduling problem when the problem is structural.)*

The pickup kernel ships (`kernels3d/erosion_pickup_sphere3d.glsl` via `sphere_passes/ErosionPickupPass.gd`,
registered at `MaterialSphereGPU3D.gd:59` — not `:51` — immediately before `ReactionsPass` so M3 SETTLE
reads freshly-scoured `susp` in the same step). But **the pickup credits `susp` to its OWN cell**
(`erosion_pickup_sphere3d.glsl:130`) and the kernel's own header at `:23` states outright *"Nothing else
touches susp."* M3 then settles it back in that same cell. `erosion_advect_sphere3d.glsl` and
`erosion_deposit_sphere3d.glsl` **do not exist** — and `EcoSurfacePass.gd:41-42`'s claim that "only the box
versions are present" is itself false; there are no box versions either.

So erosion scours rock and drops it exactly where it was. Deltas, beaches, canyons and floodplains are not
unproven, they are **impossible by construction**. What is owed is a TRANSPORT kernel: advect `susp` with the
water flow and deposit where the flow slows. The proof to demand afterwards is that mineral marked in a
highland measurably appears in a basin.

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
