# TODO / Roadmap — Local Agents (voxel-planet caretaker sim)

**This file is the map of what is LEFT. It is not a history.** A finished item is deleted the moment it is
committed; git is the record of what was done. When an entry is FALSE, fix it in place and say what it
claimed, so nobody re-derives the same wrong conclusion.

**Physics work is NOT tracked here. It is tracked in `docs/PHYSICS_TODO.md`, which is the one list.** This
file holds the things that are not physics: how to run and measure, the staged roadmap, what is settled,
the open decisions, and where everything lives. If you find a physics defect, it goes in `PHYSICS_TODO.md`,
not here. This file duplicated that list for weeks and every copy rotted separately.

**KEEP THIS FILE AND `CLAUDE.md` CORRECT — THAT IS THE JOB, NOT A PERMISSION TO ASK FOR.** He cannot police
every line of two long documents; an agent that finds a wrong entry and asks permission has handed the work
back. Fix it, say what it claimed, and move on.

**Distrust the FRAMINGS here, not just the facts.** A previous version led with "every subsystem with a
conservation ledger conserves; every subsystem without one mints", and a full session was planned against
that sentence. Every factual claim in it was checkable. The framing was the problem — "minting" made
**creating matter from nothing** sound like an accounting discrepancy, so the plan it produced was to
measure the discrepancy better and to fix a shortage by adding another source. If a phrase here lets you
think about a physics violation without picturing the physics, replace the phrase.

---

## ▶ START HERE

**THE GOAL IS THE ACTUAL EARTH, to a chosen granularity.** Not a planet tuned to be pleasant. Every constant
is a measured property of real matter, every initial condition describes what the planet was made of, and
**temperature, atmosphere, ocean and habitability are OUTPUTS, never inputs.**

**0.4 is the PLANET. Creature work is 0.5** — not lower priority, premature. But **a defect you find is
FIXED, wherever it lives.** Nothing here licenses recording a broken thing instead of repairing it.

**Read `CLAUDE.md`'s first two rules before touching anything.** Delete what is wrong rather than preserving
it behind a flag, and get the maintainer's permission BEFORE writing any departure from real physics.

`sorting.py` at repo root is the maintainer's, untracked — leave it.

### State (2026-08-11) — `feature/live-breakages`

**THE TOP ITEM IS `PHYSICS_TODO.md` E1: THE AIRBORNE TRACERS CREATE MASS.** `o2_total` reaches 4.4e17
against a seeded ~37 000, and `o2_first` — latched at the seal on field_step 2 — is ALREADY 4.67e17, so it
multiplies by ~1e13 inside two dispatches rather than accumulating. `mineral_total`, which does not ride
`tracer_transport`, stays sane; that is the tell. It was bisected to `bf710bd`, whose lateral-base
correction is CORRECT and is not being reverted — it was masking this. E1 records what has been ruled out
by measurement, what has been ruled out on paper, the one false lead, and the four places left to look.
Read it there. Do not re-derive it.

**EVERY CONSERVATION FIGURE RECORDED BEFORE TODAY IS DEAD, AND SO IS EVERY ONE RECORDED TODAY.** Three
things invalidated the recorded numbers in sequence this session, and E1 invalidates what replaced them:
- the seal used to latch late (see below), so the baselines were taken near the end of the run;
- `gravity_flow_sphere3d.glsl` gathered from the wrong neighbour slot, destroying and duplicating mass
  (`34808ee`), and its outflow pass pushed mass UPWARD (`7a257ec`);
- twelve more kernels had the same wrong belief about the slot layout and were walking sideways around the
  sphere at constant radius (`1433765`).
Do not quote a drift percentage from this file, from a commit message, or from a comment. Measure it.

**THE SEAL NO LONGER DEPENDS ON WHO IS LOOKING.** `LAMaterialFieldSeal3D.poll()` used to be called only
from `MaterialFieldReport3D.report()` on the 64-frame gauge cadence, and a demand-gated channel counted as
live only if some RENDERER had already made its mirror resident. The seal landed at `field_step` 9 with the
render layer up and 265 without it, which latched every conservation baseline near the end of the run and
made the drift gauges read a trivial 0.000% — a gate that always passes. `poll()` now runs on the field
step, right after the readback (`MaterialFieldSphereStep3D.gd:224`); both arms seal at step 2.

**THE SIM, THE CAMERA AND THE UI ARE THREE SCENES, AND `--bare` IS DELETED.**

| scene | flag | contents |
|---|---|---|
| `game/Simulation.tscn` | always | planet, field, star, ecology, geology, telemetry, persistence |
| `game/RenderLayer.tscn` | `--render` | `Camera3D` + the spatial nodes that draw the world |
| `game/UiLayer.tscn` | `--ui` | `Control`/`CanvasLayer` menus and panels + their input; implies `--render` |

A camera is not UI. Two nodes were doing both jobs and both were load-bearing physics: `LAVoxelTimeControl`
was a `CanvasLayer` that owned `Engine.time_scale` (split — `LASimTimeAuthority` is a plain Node and owns
the clock), and the sun the field integrates was a light owned by the sky VISUAL cycle (`LAStar` carries
the direction and the `insolation` meta now and re-aims as it orbits). `--wind=` went with `--bare`, along
with the dead prescribed-wind chain behind it. **Use `--render` when you need to SEE a run; do not reach
for `--ui`.** `SIM_REPORT` publishes `ui_nodes` and `sim_run.sh` exits 5 when a run without `--ui` has any.

**ONE SSOT FOR THE NEIGHBOUR TABLE, AND REVERSE LINKS ARE NO LONGER COMPUTED.** `kernels3d/neighbours.glsli`
holds the slot layout (`N_IN`, `N_OUT`, `N_A0..N_B1`, `N_LAT0`) and every kernel includes it; no kernel
indexes `nbr[]`/`send[]` with a bare number. `LASphereGrid` resolves each reverse link into
`link_partner[c*6 + d]` by SEARCHING the neighbour's own six slots (`sim/sphere/SphereGrid.gd:204`), so a
two-pass gather is `send[partner[base + d]]` — a lookup, not arithmetic. **`opposite()` is deleted** and
`scripts/check_neighbour_slots.sh` fails the build on any kernel that computes a reverse link.
`LASphereGrid.validate()` runs (it was complete and nothing called it); a bad table prints `GRID_INVALID`
and `sim_run.sh` exits 6.

**A KERNEL CAN NOW BE TESTED ON A 4x4x6 GRID INSTEAD OF BISECTED OUT OF A 200-FRAME RUN.**
`addons/local_agents/tests/KernelConservation.tscn` dispatches one kernel on a real cubed-sphere and asserts
total mass is unchanged; `scripts/check_kernel_conservation.sh` is the gate (windowed, so it is NOT part of
the headless lint). 8 checks pass: slot reciprocity, `gravity_flow`, `erosion_transport`, and
`tracer_transport` under still air, wind, a solid crust and a 160 m/s gale. **So the kernels are proven
clean and E1 is not in them — do not spend time re-reading them.**

**Kernel count is 25** (`kernels3d/*_sphere3d.glsl`), down from 32. The floor is about 18; the remaining
merge candidates are in `PHYSICS_TODO.md` D2.

### Claims struck this session — do not re-derive these

Kept rather than deleted, because each one sent real work at a problem that did not exist.

- ~~"`--bare` CHANGES THE PHYSICS"~~ — the effect was real; the flag is gone. There are three scenes and two
  flags now (`--render`, `--ui`), and the seal fix removed the mechanism.
- ~~"`moisture` IS DEAD"~~ — FALSE. It reads `moisture_total` 2.7–20.3 and `cloud_cells` 9344–9840 in every
  arm measured. The claim rested on a comment saying the channel "was never in the GPU seed list", which is
  true and irrelevant: moisture starts at zero because it IS zero. What was actually happening is
  `bf710bd`'s finding — the shared tracer operator shed its downward flux into solid ground where nothing
  gathered it, so the vapour half of the water cycle drained as fast as it filled.
- ~~"`dust_total` reads 0"~~ — FALSE. It reads 2106–2300 in every arm measured.
- ~~The conservation DEBT TABLE~~ — every row of it is superseded. Re-measured on the unmodified tip
  `54f6e58`, `mineral_total` was **+149%**, not the recorded -0.0064%, and `o2_total` was positive where
  the table recorded -24.71%. The table was not fabricated — it was measured before the kernel collapse and
  nobody re-measured after — but no number in it survives, and E1 means the current ones do not either.
  `LAMaterialFieldConservation3D.DEBT` is the only place these live; do not keep a second copy here.
- ~~"the seal latches at field_step 9"~~ — it latches at 2, and no longer depends on renderer channel
  residency.
- ~~"three condition gates exist that no record uses"~~ — `GATE_SURFACE`, `GATE_OPEN_ABOVE` and
  `GATE_DAYLIGHT` are DELETED (`9ff2f97`), along with `DAYLIGHT_MIN`. `light_at()` stays: photosynthesis
  takes light as its rate DRIVER, not as a gate.
- ~~`opposite()`, and any instruction to compute a reverse link~~ — deleted; kernels use `link_partner`.
- ~~"`params.dt` is uploaded to `reactions_sphere3d.glsl` and never read, so every reaction rate is
  per-STEP"~~ — the first half was true and the upload is deleted; the second half was the wrong diagnosis.
  Five records already fold `real_seconds_per_step()` into their own `k`, so a kernel-side `dt` would
  double-count them. The real defect (two rate units in one table) is `PHYSICS_TODO.md` C3.
- ~~"`snow_cells` fell 1170 → 76 → 17 and nothing keeps snow on this planet"~~ — UNVERIFIED, not disproved.
  Every one of those figures predates the kernel-collapse bugs and the seal fix, so none of them measures
  the substrate that exists now. Re-measure before planning against it.
- ~~"`METRES_PER_MODEL_UNIT` and the geotherm's depth conceit are two live answers to how big this planet
  is"~~ — they are not in conflict. `MaterialFieldGeotherm3D._derive_gradient()` (`:208`) computes the
  exaggeration explicitly as `GROUNDWATER_CIRCULATION_M / (REGOLITH_CELLS * cell_size)` and derives the
  gradient from it. The real defect is that the grid cannot RESOLVE the aquifer, which is `PHYSICS_TODO.md`
  D5.

Line-number citations in this file were re-checked on 2026-08-11 and most had rotted — the comment sweep
shifted every line in the kernels and `slump_sphere3d.glsl` no longer exists. **Cite an identifier, not a
line, unless the line is the point.** A grep resolves an identifier; nothing resolves a stale line number.

---

## HOW TO RUN AND MEASURE

**THE ONE RUN COMMAND IS `scripts/agent_harness.sh sim`** (it forwards to `scripts/sim_run.sh`). It runs the
standard arm off-screen with the streamer off, re-imports only when a kernel actually changed, and **counts
engine errors FIRST and refuses to print numbers if there are any**. Do not hand-write the wrapper
invocation again.

```
scripts/agent_harness.sh sim [--frames N] [--seed N] [--fast N] [--path DIR]
                             [--fauna] [--full] [--raw] [--report k1,k2] [--keep] [-- <scene args>]
```

Defaults: 200 frames, seed 4242, `--fast=8`, `--planet-only --no-fauna`. The conservation gate needs 600+
frames to audit at all. A 600-frame windowed run costs about 90 s and exits by printing `LA_RUN_COMPLETE`,
so looping three runs per arm is fine.

**Exit codes** (`sim_run.sh`): 0 clean · 2 usage · 3 stale shaders · 4 the run logged engine errors, numbers
withheld · 5 a UI node was built without `--ui` · 6 `GRID_INVALID` · 124 never reported · 125 hung after
reporting · **126 `CONSERVATION_VIOLATION`**.

**Never launch godot windowed directly** — it steals the maintainer's keyboard focus. `--fixed-fps 60` is an
ENGINE flag and goes BEFORE the `--`. Both are handled for you by the harness.

**In a fresh worktree, in this order, or your measurements are fiction:** use `scripts/new_worktree.sh`,
which does all three — symlink the GDExtension binaries (`addons/local_agents/gdextensions/localagents/bin`,
NOT a `bin/` at the repo root, which does not exist), then `godot --headless --path . --import`, then
`scripts/editor_scan.sh`. Never a bare `godot --headless --editor`; two concurrent scans segfault.
A long-lived checkout goes stale the moment someone else's kernel edit merges — `.glsl` kernels are imported
resources and nothing recompiles them outside the editor. The wrapper refuses to launch against a stale tree
(`STALE_SHADERS`, exit 3). Do not bypass it to "just get a number".

**Gates:** `scripts/agent_harness.sh lint` is what CI runs. It includes `check_max_file_length.sh`,
`check_physical_constants.sh`, `check_reaction_balance.sh`, `check_heat_capacity_ssot.sh`,
`check_enthalpy_ssot.sh`, `check_neighbour_slots.sh`, `check_comment_density.sh`, `check_no_inferred_typing.sh`,
`check_tool_safety.sh`, `check_public_surface.sh`, `check_demo_catalog.sh` and `check_library_only.sh`'s
force-load. `check_kernel_conservation.sh` is windowed and runs separately.

**Instruments.** `LA_SOIL_BUDGET=1` and `LA_MINERAL_PROFILE=1` sample outside the contended slot and can be
armed with anything. **Four probes share the driver's ONE `set_step_probe` slot and are mutually exclusive**,
in this declared precedence (`MaterialFieldSphereStep3D.gd:63-90`): `LA_MINERAL_BUDGET`, `LA_H2O_BUDGET`,
`LA_ENERGY_BUDGET`, then `LA_PASS_PROBE=<channel>` at lowest precedence. Arming more than one push-warns,
names every armed flag, and runs the first. `LA_PASS_PROBE` takes any channel name, so the next runaway is
attributable without writing a bespoke probe.

**Reading a run:**
- **Three runs per arm**, quoting `phenomena_kinds` (a dict, e.g. `{"impact": 20, "eruption": 1}`) and
  `bolts` — residual spread is discrete and disaster-driven. Compare at equal `field_sim_s`, never equal
  `--run-frames`.
- **Read the books out of `SIM_REPORT` rather than arguing from temperature:** `conservation`,
  `conservation_worst`, `conservation_violations`, `conservation_steps`, `conservation_failed`,
  `world_seed`, `world_seal_step`, `energy_run_drift` / `energy_stock_first`, `energy_residual` /
  `energy_booked`.
- **A global mean cannot answer a local question.** `temp_mean` is inflated by magma; use `temp_ground_p50`.
- **CHECK THE SIM IS ALIVE FIRST.** A silent load failure once printed a normal-looking `SIM_REPORT` with
  zero reaction records. An aggregate that is exactly `0.00`, or an order of magnitude off, is a broken
  pipeline until proven otherwise.
- **A gate that passes with the feature disabled is not a gate.** Build the disabled arm. This caught an
  inert 175-line module that had passed every check written for it.
- **At 43.2 s per field step, a 600-frame run is ~7 hours of planet time** — during which Earth gets about
  1 mm of rain. "Do rivers run" needs 4000+ frames, not a bigger constant.
- **A `const Dictionary` built from another script's constants can fail to compile at runtime**, and when it
  does the whole script exposes NO static methods — `LASubstances.table()` vanished that way while the
  editor scan reported 0 errors throughout. Use static funcs. (`c185203`.)

**`world_seed` IS THE SCOREBOARD.** Everything in it is something the substrate was TOLD rather than worked
out, and progress is entries being DELETED, each with the acceptance test that the thing it asserted now
emerges. The bar is a post-Theia seed: a molten body and a bulk composition, with ocean, atmosphere and
crust all OUTPUTS. `INITIAL_TEMP = 15.0` is asserted in `MaterialField3D.gd` and is NOT on the scoreboard,
so the one seed most worth deleting is the one nothing is scoring. Either note it into the manifest or stop
calling the manifest the whole scoreboard.

---

## INSTRUMENTS THAT LIE

These are gauge defects, not physics defects, which is why they are here and not in `PHYSICS_TODO.md`.

1. **`molten_counts()` CAN REPORT ZERO FROM A STALE MIRROR WITH NO PROVENANCE FLAG.**
   `MaterialFieldQueries3D.molten_counts()` (`:388`) reads the `lava` and `solid` mirrors, and `lava` is
   demand-gated (`MaterialSphereGPU3D.SITUATIONAL_CHANNELS`, `:75`), so between eruptions the gauge cannot
   tell "no lava" from "the channel never arrived" — exactly what `mass_live` exists to prevent for the
   element inventory. `magma_cell_count()` (`:408`) and `magma_erupting()` (`:418`) delegate to it and
   inherit it. **Deciding it:** give `molten_counts()` the same provenance flag and read it on a run with
   no eruption.
2. **`fire_peak` READS 0.0 AND NOBODY KNOWS WHICH ZERO IT IS.** `fire` is also situational, and
   `MaterialFieldQueries3D.fire_peak()` (`:470`) has no provenance flag — the same defect on a different
   channel. A gauge that cannot distinguish "nothing burned" from "the channel never arrived" cannot verify
   any change to combustion, which is precisely what it is asked to do.
3. **`fuel_total()` IS THE LAST MASKED CONSERVATION TOTAL.** `MaterialFieldQueries3D.fuel_total()` (`:460`)
   gates on `solid[c] == 0`, and it is what `SIM_REPORT` publishes as `fuel_total`
   (`MaterialFieldReport3D.gd:271`) — so the number a reader sees is the masked one while the mask-free twin
   sits in another module under another name (`MaterialFieldElementInventory3D` publishes `fuel_all` beside
   `fuel_open_total`, `:145-146`). This already produced one false finding: fuel "falling from 216 to ~152"
   was read as combustion, and `fuel_all` says the seeded 216 is all still there — ~61 units of it went
   under the solid mask. Burial is not loss. **Deciding it:** publish the twin beside it, or make
   `fuel_total` the unmasked one and rename the masked reader. The other `solid[c] == 0` gates in that file
   are shell-mean, flow and fertility diagnostics — not conservation gauges, and correctly masked.

---

## DO THIS NEXT — the staged plan

Each stage has its own verification. Do not merge stages. **The physics items inside each stage live in
`docs/PHYSICS_TODO.md`; what is below is the sequencing and the acceptance test.**

**STAGE 1 — stop the sim creating matter and energy.** The balance gate, the element inventory, the
composition table, the seal, the conservation gate and the per-kernel conservation harness all exist. What
is left is `PHYSICS_TODO.md` section E, and **E1 is the whole of it right now** — no other conservation
number can be interpreted while a tracer multiplies its channel by 1e13 in two dispatches. After E1:
per-pass attribution for ELEMENTS (E5), which is the instrument that turns "carbon moved" into "this
reaction moved it". Mineral and energy each have a probe and each named its culprit in a single run.

Energy is NOT gated and must not be — sunlight enters and longwave leaves, so what has to go to zero is
`energy_residual`, not the change in stock. **Read the total, not the rate times a step count:**
`energy_run_drift` is published as an absolute, and the ledger's own clock (`energy_run_steps`) is not the
field's. The work queue is the unbooked terms the ledger names in its own header
(`MaterialFieldEnergyLedger3D.gd`) — read it there rather than copying it here, because it cites the exact
line of each leak.

**STAGE 2 — seed a primordial planet.** Post-magma-ocean Hadean, ~4.4 Ga: hot surface, thick CO₂/N₂
atmosphere, water still largely steam, **no free O₂** (it is a product of life), no biosphere. **Oceans must
CONDENSE, not be placed.** Delete `INITIAL_TEMP = 15.0` and every "partway" seed. Source and cite the
composition, and name the era. **Uninhabitable for a whole run is an acceptable result.** `6ad2417` on
`feature/conservation` (one commit off `0.4-dev`, tagged WIP and explicitly droppable) is a start on this.
The pressure-dependent `boil_c_at` is the other half: at 100 bar water boils at 306 °C, and a magma-ocean
planet condenses its ocean when the surface passes ~300 °C, so a model waiting for a flat 100 °C waits
forever and the failure reads as "the physics does not work".

**STAGE 3 — does it cool, and where does it settle?** Run 4000–6000 frames; watch `temp_ground_p50` for an
asymptote and `snow_cells` for an ice-albedo runaway. **Do not tune the solar constant** — 1361 W/m² is a
measured fact. Note the conservation gate audits ONCE at a fixed horizon past the seal, so a 4000-frame run
gets one early audit and then runs 3400 more frames ungated. If Stage 3 is where a leak shows up, that
horizon is the thing to revisit. *(This stage used to open with "kill the ocean thermostat first". The
thermostat was already dead when that was written, and following it costs a session on a non-problem.)*

**STAGE 4 — oceans condense.** Verify the sequence *happens*: cooling past the condensation point rains the
atmosphere out. Success is the event occurring, not a number looking right. The CO₂ half of this stage
landed — silicate weathering is the Urey reaction (`GeoRecords.gd` D1b, CaSiO₃ + CO₂ → CaCO₃ + SiO₂). Two
things it left open, both now `PHYSICS_TODO.md` items: the return leg D1c never fires because metamorphic
decarbonation needs 280.7 °C and the hottest cell reaches ~256 °C, so the sink is one-way and CO₂ declines
forever (C1); and this planet's atmosphere is only a few cells deep over every weathering cell, so its CO₂
reservoir is thin relative to the reacting surface. Neither is fixed by moving a rate constant.

**STAGE 5 — the geological bake (`--geotime`).** Run the planet forward through geological time and freeze
the result as the start state. This is what makes habitability an output. Needs a real stopping condition
(temperature asymptote, oceans condensed, atmosphere stable). The snapshot path exists; `--geotime` does
not. Two things it will trip over, both verified 2026-08-08: in-memory snapshots DROP the GPU field unless
`LA_SNAPSHOT_FIELD` is set (`WorldSaveController.gd`), so a bake wants the disk path; and a restored field
is pinned to `grid_res_per_face` × `grid_depth`, i.e. to the quality preset, because
`MaterialFieldSnapshot3D.restore()` refuses a cell-count mismatch outright.

Life is not a stage. It is what stage 5 hands to 0.5.

---

## HOW GOOD IS IT? — `PHYSICS_RUBRIC.md`

Six criteria, 0–4, with a dated score history; `scripts/physics_score.sh` computes criteria 1, 2 and 5 out
of `SIM_REPORT` and 3, 4 and 6 are hand-entered audit counts, so those are the ones to distrust. Opening
score 7/24 (2026-08-09). It records two hard couplings: seed minimality cannot pass 2 until energy is
booked, and matter conservation is gated on per-pass attribution existing. **The score has not been
recomputed since the kernel fixes; recompute before quoting it.**

---

## WHAT IS SETTLED — do not rebuild these

*(The most dangerous list in this file, because work AVOIDS what is on it — so an entry that stops being
true has to come OFF. `REPOSE_TAN` did: the value was right and the application was not. It was applied as
a mass difference against a tangent, which asserts cells are cubes; on the cubed sphere the aspect runs
1.07–4.08, so sediment stood at 33° at the shell floor and 9.8° at the top. Fixed via `LASphereGrid.link_arc`,
and the repose gate now lives in `gravity_flow_sphere3d.glsl` with the tangent supplied per row by
`WaterSlumpLavaPass` from `LAPhysical.REPOSE_TAN_DRY_GRANULAR`.)*

Each of these is one grep from being falsified if you doubt it. Identifiers, not line numbers.

- the H₂O ledger's inclusion rule — `MaterialFieldLedger3D.gd`;
- the DEFS record engine's std430 layout — `ReactionDefs.gd`, `RECORD_BYTES = 144`, documented in
  `serialize()`. Note the file has NO `Records` suffix, so the old `{ReactionDefs,Bio,Phase,Geo}Records.gd`
  glob named a file that does not exist;
- the neighbour / tangent / lateral-slot tables and `link_partner` — `sim/sphere/SphereGrid.gd`, gated by
  `check_neighbour_slots.sh` and by `LASphereGrid.validate()` at runtime;
- the soil budget's per-leg identity — `MaterialFieldSoilBudget3D.kernel_residual`, exactly 0.0;
- the erosion transport law — no fitted constant, load moves in the same proportions as the water carrying
  it (`erosion_transport_sphere3d.glsl`);
- the geotherm as a seeded initial condition with a DERIVED vertical scale — `MaterialFieldGeotherm3D`
  states the one conceit (depth is vertically exaggerated) and `_derive_gradient()` computes the
  exaggeration from `GROUNDWATER_CIRCULATION_M` rather than asserting it;
- ONE definition of a cell's volumetric heat capacity per side of the GPU boundary — `kernels3d/rc_shared.glsli`
  and `material/HeatCapacity.gd`, held equal by `check_heat_capacity_ssot.sh`, which gates the FORMULA
  rather than the values because the values were never what drifted;
- ONE definition of the enthalpy ladder per side — `kernels3d/enthalpy.glsli` and `LASubstances`, held equal
  by `check_enthalpy_ssot.sh`, which also checks the phase ladder appears in the same ORDER on both sides.
  The GLSL twin deliberately stops at gas; the high rungs need bisection (`PHYSICS_TODO.md` A2);
- the aquifer's `k_rel` / `RESIDUAL` capillary retention — `soil_sphere3d.glsl`;
- the saturation curve from August-Roche-Magnus; Kozeny-Carman conductivity from porosity;
- weathering as ice expansion and Arrhenius dissolution, and lithification on real lithostatic pressure
  against `LAPhysical.LITHIFICATION_PRESSURE_PA` — `GeoRecords.gd`;
- metabolism as the substrate's own respiration reaction, mass-scaling emergent rather than typed.

---

## OPEN DECISIONS

- **Memory/Graph lane: keep the SQLite-only graph architecture, or introduce a specialised graph backend?**
  (`controllers/ConversationStore.gd` → `docs/NETWORK_GRAPH.md`.) Nobody has picked a side and the status
  quo ships: `gdextensions/localagents/src/NetworkGraph.cpp` is the raw `sqlite3` C API, vector search is a
  hand-rolled VP-tree over the `embeddings` table, and four consumers share one
  `user://local_agents/network.sqlite3` (`ConversationStore.gd`, `graph/ProjectGraphService.gd`,
  `graph/BackstoryGraphService.gd`, `sim/ecology/BandChronicle.gd`). **What should decide it:** FTS5 is not
  compiled into this build, so full-text search over node data is unavailable today — establish whether
  that is a blocker before weighing a new backend, because enabling FTS5 is a build flag and a backend swap
  is not.

---

## 0.5 — THE LIVING CREATURES — PARKED

Does not begin until the planet is locked down. Plans: `docs/0.5_CREATURE_FEATURES.md`,
`docs/0.5_PARALLELIZATION_GUIDE.md`, `docs/ROADMAP_0.5.md`.

Two things to establish FIRST, because both are unmeasured rather than broken:

- **Whether the food web works has never been measured.** The two gauges previously cited cannot answer it:
  `biota_node_intake` reads 0.00 when predation WORKS (it is credited only on the fallback branch for prey
  with no body ledger, and every creature in the library has `draw_body_mass`), and `death/eaten` 0 is
  guaranteed by `--planet-only`, which spawns no animals at all. The predation path is present and
  reachable — `CreatureThink.gd:178,194` and `Fish.gd:844` call `prey.die("eaten")`. **It needs a
  fauna-enabled run, which nobody has done.**
- **Breeding has a global `pop_cap` ceiling and SPACE does not regulate it.** Food and energy do:
  `EcologyBreeding._spawn_cost()` refuses to spawn below `SPAWN_ENERGY_FLOOR` and charges
  `SPAWN_ENERGY_FRAC` of the parent's maximum, and the birth count is multiplied by a biomass food gate.
  The land and aquatic caps sit on top of those as hard ceilings. Space is the unregulated one.

## 0.6 — THE FULL SOLAR SYSTEM

Make the moving frame literal: migrate the GPU field to a body-local representation so the planet can
translate; planets, moons and sun as first-class bodies on real orbits; land on the moon; render the real
orbits; persist the orbital state.

---

## Where everything lives

- **Substrate:** `material/MaterialField3D.gd` (thin facade, **extract-only**) + `MaterialSphereGPU3D` ·
  `sphere_passes/*` · `kernels3d/*_sphere3d.glsl` (authoritative) + `neighbours.glsli` / `rc_shared.glsli` /
  `enthalpy.glsli` · `MaterialReactions3D` (registry) + `material/reactions/` — six files: `ReactionDefs.gd`
  (the slot enum + record layout), `BioRecords.gd`, `PhaseRecords.gd`, `GeoRecords.gd`,
  `CombustionRecords.gd` and `ReactionBalance.gd` (the gate, which lives in this directory rather than
  beside `PhysicalConstants.gd`) · `material/Substances.gd` (`LASubstances`, the SSOT for matter) ·
  `material/PhysicalConstants.gd` (`LAPhysical`) · the budget/probe/inventory modules.
- **The grid:** `sim/sphere/SphereGrid.gd` — neighbours, lateral slots, `link_arc`, `link_partner`,
  `validate()`.
- **The books:** `material/MaterialFieldSeal3D.gd` (SEEDING → SEALED, and the `world_seed` manifest) ·
  `MaterialFieldConservation3D.gd` (the gate, and its `DEBT` table — the SSOT for how far off each substance
  is) · `MaterialFieldEnergyLedger3D.gd` (the stock, and the unbooked-terms work queue in its header) ·
  `MaterialFieldEnergyProbe3D.gd` / `MaterialFieldMineralProbe3D.gd` (per-pass attribution, heat and rock) ·
  `MaterialFieldPassProbe3D.gd` (`LA_PASS_PROBE`, any channel) ·
  `MaterialFieldElementInventory3D.gd` (moles, with `_all` mask-free twins and `mass_live` provenance).
- **Kernel tests:** `addons/local_agents/tests/KernelConservation.tscn` + `scripts/check_kernel_conservation.sh`.
- **Composition root:** `game/VoxelWorld.gd` (**extract-only**) + `game/world/*`; the three layer scenes are
  `game/Simulation.tscn`, `game/RenderLayer.tscn`, `game/UiLayer.tscn`.
- **Actors:** `sim/actors/*`, `creatures/**`; disasters are seeds/visuals only. **Cognition:** `creatures/cognition/*`.
- **Reusable addon:** `agents/` (LocalAgent + Agent3D) · `runtime/` · `examples/`.

## North-star

Not restated here. `CLAUDE.md` holds it, and a second copy is a second thing to drift.
