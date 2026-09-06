# What to do next

Work down this list; an item is DELETED the moment it lands. Physics work is in `docs/PHYSICS_TODO.md`,
cost in `docs/PERFORMANCE_TODO.md`. Check the code, then act; report what was deleted and no number
this substrate printed. **AN ITEM CARRIES A SYMPTOM AND THE COMMAND THAT REPRODUCES IT, NEVER A
DIAGNOSIS** (`scripts/check_doc_prose.sh`). **THE LIST IS ORDERED BY WHAT IS UPSTREAM OF WHAT.**
**THE LADDER ADVANCES ONE APPROVED DEMO AT A TIME, AND EACH DEMO ADDS EVIDENCE OF ITS OWN PROCESS THE
MAINTAINER CAN SEE OR HEAR**: a run shows only what its rung contains; a rung is built only after the
demo below it (a scene plus a `LocalAgentDemoEntry` in `addons/local_agents/examples/demos/`) is
approved. Rung 0 is approved. A process the world contains switches off and on mid-run through
`LAAblate`, one registry for modules and physics. A fake is a record in `sim/LAFakes.gd` naming the
rung whose landing deletes it (`scripts/check_fakes.sh`).

---

## 1. THE PLANET'S POISSON RESIDUAL STOPS FALLING, AND THE MASS IT WEIGHS GROWS

`scripts/sim_run.sh --body --frames 6 --report gravity_residual_rel,gravity_vcycles,gravity_total_mass_kg`
reads a residual above `GravityPass.RESIDUAL_TOLERANCE` with the V-cycles spent, so
`MaterialFieldGravity3D.solve` invalidates the run, and a mass maximum several times its own minimum
while `mineral_total` and `h2o_total` drift by nothing. Branch `multigrid-gravity` holds an unlanded
V-cycle solver, green on the slice, red on the planet.
Reading: `MODE_SEED` in `kernels3d/gravity_poisson.glsl` writes `grav_ref` as one monopole.

## 2. THE PLANET'S SEEDED COLUMN IS NOT A FIXED POINT OF ITS DERIVE

`scripts/sim_run.sh --body --rung 2 --frames 6 --report pressure_rest_rel,derive_unconverged_cells`
reads `pressure_rest_rel` above its bar with every cell converged; the slice column
(`scripts/sim_run.sh --rung 2 --frames 6`) reads zero. `scripts/check_derive_safe_math.sh` counts
`pressure`, `p_fluid`, `k_cond`, `temp` and `temp_lith` as channels whose readings differ between
Godot's fast math and lasim's `MTLMathModeSafe`; its `once`/`twice` arms replay `plan_derive.lapl`
through `lasim --passes derive`. `docs/DERIVE_SAFE_MATH_CEILING` ratchets the count to zero.
Reading: `state_derive.glsl` ends the (T, p) solve on `abs(f) <= LA_STATE_TOL * max(p_pa, 1.0)`.

## 3. THE BOUNDARY GATES CANNOT RECORD THEIR OWN CAPTURE, AND A GHOST'S REST GRAVITY IS READ PAST ITS BUFFER

`scripts/check_boundary_books.sh` with no `LA_LINT_CAPTURE` exits 2: its capture run,
`scripts/sim_run.sh --body --frames 20 --rung 3 --slice-capture C`, ends `RUN FAILED, exit 122` with
`PRESSURE_BROKEN: pressure fell going down.` `rg -n 'g_rest.*cc \* 3' addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd`
Reading: `_allocate_declared` in `MaterialSphereGPU3D.gd` adds `_ng` once to a declared length, so a
three-vector declared `{"n": cc * 3, "ghosts": true}` is `cc * 3 + ng` long.

## 4. THE BODY RECORD OMITS THE PORE WATER BELOW THE SEA FLOOR, AND ONE POROSITY LAW SERVES EVERY ROCK

`scripts/check_hydrosphere_mass.sh --body` is red: the declared `hydrosphere_kg`/`groundwater_kg` in
`LABodySystem.cpp` (Gleick 1996) count the surface ocean and continental groundwater only, and
`REGOLITH_SURFACE_POROSITY`/`COMPACTION_LENGTH_M` (Athy 1930, shales) are applied to basalt and basement.

## 5. A SKY CELL HOLDS MORE GAS THAN STANDS IN IT

`scripts/check_body_measured.sh` is red: `body_mass_by_channel` puts the whole excess over the declared
body mass in `co2` and `n2`, and the excess scales with the box. `scripts/check_atmosphere_mass.sh` is in
no `[[gate]]` row, and its rung-2 arm compares one slab against the whole planet's inventory.
`rg -n "r_sea \+ 1.0e7" addons/local_agents/gdextensions/localagents/src/LAFieldLithostaticSeed.cpp`
finds the datum's shell integral cut at a chosen radius, where the exobase is the radius the gas leaves.
Reading: `shape_atmosphere` in `LAFieldLithostaticSeed.cpp` gives each cell `Π_a sinh(x_a)/x_a`.

## 6. THE CRUST HAS TWO REPRESENTATIONS, AND THE SEA IS A SPHERE AT ONE RADIUS

Maintainer's decision, standing: one substrate everywhere. The field is the only representation of
matter; the ground and the water surface are detectors on it (an isosurface a compute kernel extracts
into mesh buffers per block, which is also the collider); the generator is sampled into the field once
at seed; a body of water is where the inventory settled under the solved gravity, one liquid in one
channel. `rg -n "sea_radius|OceanPlane|_open_sea|sea_level_m|resample_terrain" addons/local_agents`
finds the sea as a declared shell radius and the field sampling the generator after the seal.

## 7. THE LEVEL BOUNDARY DRAWS AS A LINE ACROSS THE GROUND

`scripts/shoot_demo.sh addons/local_agents/examples/SliceRung1Demo.tscn <dir>` carries thin dark lines
running to the horizon in every pose under a kilometre, straight in world space and jointed at right
angles. Read the PNGs.
Reading: `get_transvoxel_position` in `VoxelTerrainTriplanar.gdshader` moves a transition vertex onto
the coarse surface and leaves its `NORMAL` at the fine one's.

## 8. THE DEMO SITE HOLDS NO WATER A VIEWER CAN STAND BESIDE

`LA_SHOTS="30:-3:0" scripts/shoot_demo.sh addons/local_agents/examples/SliceRung1Demo.tscn <dir>` shows
the nearest free water surface a kilometre off and reads as an opaque dark plate with a straight edge;
`scripts/sim_run.sh --slice --rung 1 --frames 4 --report water_liquid_total,wet_cells` counts what stands
in the box.
Reading: `coast_site` in `LAPlanetTables.cpp` bisects onto the waterline and then scores the site by
`land_m + depth_m`, which is largest where the relief is steepest rather than where the box's own
footprint is half wet.

## 9. PHYSICS IS NOT IN THE ABLATION REGISTRY

`scripts/sim_run.sh --slice --rung 1 --ablate=gravity --frames 4` refuses the name: `LAAblate.names()`
lists presentation modules only and `LAProcessSet` resolves the rung once at launch. A process the rung
contains switches through the same `set_on`, the sweep measures its cost the same way, `LAAblate` moves
from `creatures/sim/SimAblate.gd` to `sim/`. A body released with gravity off keeps the ground's
tangential velocity and departs along the tangent; state the expression `LABallistics.drop` gives it.

## 10. THE SURFACE IS STILL: EVERY WEATHER-SHAPED STAND-IN IS ABSENT RATHER THAN FAKED

`docs/FAKES.md` carries what creatures need and nothing the surface shows: `wind_field` (deleted by
ACOUSTIC), `rain` (WATER), `streams` (ADVECT), `diurnal_heat` (RADIATION), each read through the query
the real row will answer, offered in the HUD as a stand-in.

## 11. A FREE BODY IS INTEGRATED AT THE FIELD'S STEP, AND IMPACTORS ARE SIZED BY AN INVENTED DRAW

`LABallistics::step(dt_s)` takes the whole of `SIM_SECONDS_PER_STEP` in one go, so a body crossing the
atmosphere rams it at one density for the whole crossing. `scripts/shoot_demo.sh
addons/local_agents/examples/SliceRung1Demo.tscn <dir>` photographs a test mass already landed: the
world advances 43.2 simulated seconds per rendered frame, so a two-kilometre fall is over between two
frames and nothing is seen falling. `rg -n "randf_range\(0.55" addons/local_agents/sim/actors/Meteor.gd`
finds the impactor size drawn from an invented range (the measured law: Brown et al. 2002,
N(>E) ∝ E^-0.9, a cited chondrite density). `LAMeteorImpacts.arrive()` counts a rock `launch()` refused.
`SPHERE_CD` in `LABallistics.cpp` is the hypersonic limit at every Re.

## 12. A THROWN BODY FALLS UNDER THE ENGINE'S GRAVITY, NOT THE FIELD'S

`rg -n "gravity_scale" addons/local_agents/creatures/creature/CreatureRagdoll.gd` reads `1.0`, so the
live gravity switch never reaches a flung or dying creature; `impulse.length() > 3.0` in `Creature.gd`
is an invented threshold. The design: kinematic until thrown; then a Jolt `RigidBody3D` with
`gravity_scale = 0` pushed each tick by `m·g(pos)` from `LABallistics.g_at` plus the seeded air's drag
(bound, not copied), the impulse from the overpressure in its cell, kinematic again when asleep.

## 13. A BODY'S MASS, CARBON, ENERGY AND RATES ARE NOT IN REAL UNITS

`rg -n "MASS_UNIT_SCALE|TISSUE_PER_KG|RESP_K" addons/local_agents/creatures` finds a scale factor with
no referent spent as mol/m³ of a cell. The species mass is the one input; the rest derives (Kleiber).

## 14. NOT EXAMINED UNTIL THE RUNG-2 DEMO IS APPROVED — rung 3

- `scripts/check_bench_shock_tube.sh`: at a 10:1 Sod jump the rarefaction head stands outside the bound
  and the overshoot grows as the grid halves; at a 1% jump every claim passes.
- `scripts/sim_run.sh --rung 3 --frames 8` on the planet ends with `timeout waiting for fence`.
- `LA_REST_CELL_M=68000 LA_REST_CELLS=8 scripts/check_atmosphere_at_rest.sh` reads a rest departure
  above its bar on a land column; its vent arm reads an energy residual near a tenth of the turnover.
- `scripts/sim_run.sh --rung 3 --frames 3 --report nonfinite_cells,mach_max` refuses a water record at
  light speed by the second frame; `LA_PASS_PROBE=mach LA_PASS_PROBE_STEPS=1` names the cell.
- Maintainer's decision, standing: the acoustic part of the momentum equation goes implicit (one
  Helmholtz solve per field step on `gravity_poisson.glsl`'s operator shape), the step is derived from
  the advective CFL, `SIM_SECONDS_PER_STEP` and the acoustic temporal levels are deleted; declared in
  `docs/APPROXIMATIONS.md` when built.

## 15. NOT EXAMINED UNTIL RUNG 3 IS GREEN — the rows above it and their books

- `scripts/check_bench_heat_slab.sh` (rung 4): a slab held between 20 and 520 °C leaves that range.
  Reading: `la_row_need` in `flux.glsl` gates the conduction row on `cap_sensible[c] > 0`.
- `scripts/check_bench_darcy.sh` (rung 5): six regolith columns under a head difference transfer zero.
- `scripts/check_bench_grey_atmosphere.sh` (rung 7): identical neighbours exchange unevenly past the
  bound; the lit plate settles below the grey Eddington skin temperature.
- `scripts/sim_run.sh --frames 20 --slice-capture C` then `LA_RUN_TIMEOUT=900 scripts/sim_run.sh --slice
  --slice-state C --frames 650` fires CONSERVATION_VIOLATION on h2o, nitrogen, mineral, element_C and
  element_O; with every wall shut, `scripts/agent_harness.sh sim --rung=8 --frames 20` ends with
  `h2o_total` below its sealed baseline while the element and mineral books close.
- `LA_RUN_TIMEOUT=110 scripts/run_sim_offscreen.sh --path . addons/local_agents/game/VoxelWorld.tscn --
  --sandbox --ui --run-frames=20` prints no report and logs no error; `--planet-only --no-fauna` reports.

## 16. ONLY WATER AND SILICATE MELT AND BOIL WHERE THEIR TABLE SAYS, AND TWO ROWS ARE EMPTY

`rg -n "LADDER|la_sensible_only|LA_MIX_MAX" addons/local_agents/sim/material/kernels3d/state_derive.glsl`:
every other condensed channel is e = c·T at every temperature while `LASubstances.cpp` cites its melting
point and fusion enthalpy; the CPU twin `LAMixtureEnthalpy` reads the table for any id and is the spec
(`scripts/check_enthalpy_ssot.sh`). `apatite` carries neither a melting point nor a fusion enthalpy, and
every planet mineral carries basalt's `albedo` and `emissivity`.

## 17. THE PHYSICS RUNS INSIDE GODOT'S PROCESS

Maintainer's decision, standing: a standalone native process with its own device, clock and CLI; gates
run it with no Godot launch; Godot attaches as a viewer. Today every pass is a GDScript record on a Godot
RenderingDevice (`LAFieldDriver`) and `scripts/run_sim_offscreen.sh` launches Godot for every gate.
Branch `native-plans` is unlanded: `scripts/check_lasim_parity.sh` there reads `plan_reduce.lapl is truncated`.

## 18. THE LEDGER RECONSTRUCTS ELEMENTS FROM CHANNEL AMOUNTS

Maintainer's decision, standing: per-cell moles of elements are the state and species are derived
(`docs/PHYSICS_TODO.md` B); today the ledger reconstructs them from `Channels.gd` (`mol_per_unit`).

## 19. PRESENTATION LIVES ON THE SIM SIDE OF THE EJECTA MODULE, AND THE GPU LINT RUNS HERE ONLY

`rg -n 'MultiMeshInstance3D|la_effects_scale' addons/local_agents/sim/material/MaterialEjecta3D.gd`
finds a draw cap read off the graphics preset and a MultiMesh built under `sim/`.
`.github/workflows/gpu-lint.yml` targets a self-hosted macOS runner labelled `gpu`; none is registered.

## How to run

`scripts/agent_harness.sh sim --rung=N --frames 20` runs a world holding only the processes up to rung N;
`scripts/agent_harness.sh ladder` names the first red rung; `scripts/shoot_demo.sh <scene> [outdir]`
renders the poses `--shots=alt:pitch:yaw;...` declares (look at the PNGs); `--ablate=a,b` switches names
off and `--ablate-sweep=N` measures each one's frame cost. A lane runs `LA_NO_GPU=1 scripts/agent_harness.sh lint`
plus its own gates; the full lint is `scripts/integrate.sh`'s, one landing at a time, and a source-file
merge conflict is resolved by hand. Worktrees come from `scripts/new_worktree.sh`; without its kernel
import the GPU field is dead and the report looks fine. Mutation-test every gate you write, both ways.
