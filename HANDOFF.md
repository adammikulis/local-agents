# What to do next

Work down this list. An item is DELETED the moment it lands — this file is the remaining work, never a
record of what happened. `git log` is the record. Physics work is in `docs/PHYSICS_TODO.md`; what costs
more than it should is in `docs/PERFORMANCE_TODO.md`.

Nothing here is a claim about the state of the tree, because a claim rots and nobody notices. Check the
code, then act. Report what was deleted; report no number this substrate printed.

**AN ITEM CARRIES A SYMPTOM AND THE COMMAND THAT REPRODUCES IT, NEVER A DIAGNOSIS.** A symptom holds until
it is fixed. An assertion about a cause rots in silence, reads as progress, and spends the next reader's day
on the file it named. If you know the cause you are close enough to fix it, so fix it.
`scripts/check_doc_prose.sh` fails the build on a tracker that names one.

**THE LIST IS ORDERED BY WHAT IS UPSTREAM OF WHAT: item 1 is what every item below it is measured against.** Re-order it at every landing.

**THE LADDER ADVANCES ONE APPROVED DEMO AT A TIME, AND EACH DEMO ADDS EVIDENCE OF ITS OWN PROCESS THE
MAINTAINER CAN SEE OR HEAR.** A run shows only what its rung contains. A rung is built only after the maintainer has
approved a demo of the rung below it, cut as a scene plus a `LocalAgentDemoEntry` in
`addons/local_agents/examples/demos/`. `scripts/agent_harness.sh ladder` names the first red rung;
nothing above the last APPROVED rung is examined.

---

## 1. THE PLANET'S SEEDED COLUMN IS NOT A FIXED POINT OF ITS DERIVE

`scripts/sim_run.sh --body --rung 2 --frames 6 --report pressure_rest_rel,derive_unconverged_cells`
reads `pressure_rest_rel` above its bar with every cell converged, now that the ground cells are
graded finer; the slice column (`scripts/sim_run.sh --rung 2 --frames 6`) reads zero.

## 2. THE BODY RECORD OMITS THE PORE WATER BELOW THE SEA FLOOR, AND ONE POROSITY LAW SERVES EVERY ROCK

`scripts/check_hydrosphere_mass.sh --body` is red: the water table saturates rock below sea level, and
the declared `hydrosphere_kg`/`groundwater_kg` in `LABodySystem.cpp` (Gleick 1996) count the surface
ocean and continental groundwater only. `REGOLITH_SURFACE_POROSITY` and `COMPACTION_LENGTH_M` (Athy
1930, shales) are applied to basalt and basement. Cite the oceanic-crust and sediment pore-water
reservoir and a porosity law per lithology from the substance table.

## 3. THE GROUND UNDER THE EYE IS NOT BUILT ON THE WHOLE BODY

`scripts/agent_harness.sh ground` exits 2: its shot reads `ground_meshed=false`, and the view axis
first meets built ground far past where the pose framed it. The same gate over a box,
`LA_GROUND_SLICE="-0.6129,surface,0,3,24,3,5120,10" scripts/check_ground_drawn.sh`, exits 0.
Reading: `is_area_meshed` in the terrain service answers whether a block is loaded at a level, not
whether the mesher shows it, so `ground_resolved()` can go true while half the frame is still coarse.

## 4. THE RUNG-1 AND RUNG-2 DEMOS ARE NOT CUT

`scripts/check_demo_catalog.sh` lists `slice_rung0.tres` and nothing above it. Each is a scene
declaring its rung and the slice box, and an entry; cut in order, each approved before the next rung
is built.

## 5. TWO REDUCE ROWS ARE NAMED BY A RUNG AND DECLARED BY NOBODY

`rg -n -e wind_x_sum -e wind_z_sum` finds both in `LAProcessSet.cpp`'s `ACOUSTIC_REDUCE` and in no
`reduce/*.gd` row. Removing them rebuilds the extension.

## 6. NOT EXAMINED UNTIL THE RUNG-2 DEMO IS APPROVED — rung 3

- `scripts/sim_run.sh --rung 3 --frames 8` on the planet ends with `timeout waiting for fence`.
- `LA_REST_CELL_M=68000 LA_REST_CELLS=8 scripts/check_atmosphere_at_rest.sh` reads a rest departure
  above its bar on a land column.
- `scripts/check_atmosphere_at_rest.sh`: the vent arm (top face to space) reads an energy residual
  near a tenth of the turnover against its float bar.
- `scripts/sim_run.sh --rung 3 --frames 3 --report nonfinite_cells,mach_max` refuses a water record at
  light speed by the second frame; `LA_PASS_PROBE=mach LA_PASS_PROBE_STEPS=1 scripts/sim_run.sh --rung 3
  --frames 1` names the cell and its faces.
- Maintainer's decision, standing: the acoustic part of the momentum equation goes implicit (one
  Helmholtz solve per field step on `gravity_poisson.glsl`'s operator shape), the field step is derived
  from the advective CFL, and `SIM_SECONDS_PER_STEP` is deleted. Declared in `docs/APPROXIMATIONS.md`
  when built.

## 7. NOT EXAMINED UNTIL RUNG 3 IS GREEN — the books above it

- The open-boundary books at run level: `scripts/sim_run.sh --frames 20 --slice-capture C` then
  `LA_RUN_TIMEOUT=900 scripts/sim_run.sh --slice --slice-state C --frames 650` fires
  CONSERVATION_VIOLATION on h2o, nitrogen, mineral, element_C and element_O.
- The h2o book on a shut box: with every wall shut, `scripts/agent_harness.sh sim --rung=8 --frames 20`
  ends with `h2o_total` below its sealed baseline while the element and mineral books close.
- A `--ui` run with fauna never reports: `LA_RUN_TIMEOUT=110 scripts/run_sim_offscreen.sh --path .
  addons/local_agents/game/VoxelWorld.tscn -- --sandbox --ui --run-frames=20` prints no report and
  logs no error; the same arm with `--planet-only --no-fauna` reports.

## 8. Reduce the rest on the device

`FieldPassAttribution3D._sums` walks the channels it downloads at a checkpoint; a reduce dispatch per
checkpoint replaces it. Three shapes refused a row and say why: `sea_surface_stats`, `lava_shell_diag`,
`rock_radial_profile`.

## 9. THE PHYSICS RUNS INSIDE GODOT'S PROCESS

Maintainer's decision, standing: the sim is a standalone native process with its own compute device,
clock and CLI; gates run it with no Godot launch; Godot attaches as a viewer. Today every pass is a
GDScript record on a Godot RenderingDevice (`LAFieldDriver`, `MaterialSphereGPU3D.gd`) and
`scripts/run_sim_offscreen.sh` launches Godot for every gate. The migration is phased so each
phase keeps lint green.

## 10. THE LEDGER RECONSTRUCTS ELEMENTS FROM CHANNEL AMOUNTS

Maintainer's decision, standing: per-cell moles of elements are the state and species are derived
(`docs/PHYSICS_TODO.md` B). Today the state is channel amounts (`Channels.gd`) and the ledger
reconstructs element totals (`mol_per_unit`).

## 11. GATES THAT DETECT CHANGE, NOT WRONGNESS

`scripts/check_driver_native.sh` arm two compares the seam rig's state byte for byte against
`scripts/fixtures/driver_seam_state.txt`, so a correct kernel change reads as red until re-recorded.
Audit every `scripts/check_*.sh` for the same shape and replace each with an invariant on its rig.

## 12. THE GPU ARM OF LINT RUNS ON THIS MACHINE ONLY

`.github/workflows/gpu-lint.yml` targets a self-hosted macOS runner labelled `gpu`; none is registered
(maintainer's hardware).

---

## How to run

Reproduce at the LOWEST rung that shows the defect: `scripts/agent_harness.sh sim --rung=N --frames 20`
runs a world holding only the processes up to rung N (`LAProcessSet` names them);
`scripts/agent_harness.sh ladder` climbs every rung and names the first red one.

`scripts/agent_harness.sh sim [--frames N] [--seed N] [--rung N] [--path DIR] [--fauna] [--full] [--raw]` — off-screen,
streamer off, re-imports when a kernel changed, and refuses to print if the run logged an engine error. Exit
codes are listed at the top of `scripts/run_sim_offscreen.sh`.

`scripts/agent_harness.sh lint` is what CI runs. `scripts/editor_scan.sh`, never a bare
`godot --headless --editor`: two concurrent scans segfault.

ONE run at a time — the GPU lock is machine-wide, and concurrent runs fail each other with
`timeout waiting for fence`. Finish the whole change set, then commit once: the pre-commit hook runs
`LA_NO_GPU=1 lint`, so a commit per step is a lint per step. A run past `docs/RUN_TIMEOUT_CEILING` needs
an explicit `LA_RUN_TIMEOUT` and is a declared soak.

A lane runs `LA_NO_GPU=1 scripts/agent_harness.sh lint` plus its own gates; the full lint is
`scripts/integrate.sh`'s. Never `pkill` by program name and never remove `la_sim_gpu.lock` by hand: both
reach runs this tree does not own.

Make every worktree with `scripts/new_worktree.sh`, which copies the primary's compiled `bin/`, links its
fetched `thirdparty/`, imports the `.glsl` kernels and editor-scans. Without the import the GPU field is
dead and the report still looks fine. Each worktree gets its OWN `bin/`: one shared copy cannot serve two
trees whose native `class_name`s differ, and the other tree stops parsing with "hides a native class".

A gate that passes with the feature disabled is not a gate. Mutation-test every gate you write, both ways.
