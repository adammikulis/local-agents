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

---

## 0. THE WIND BLOWS PAST ITS OWN SOUND SPEED, AND THE DEFAULT BOX IS NOT EXEMPT

`bash scripts/check_rung_acoustic.sh` reads a cell moving faster than its own sound speed. The
peak stops climbing and holds, and it holds far past the ~70 m/s of a real jet stream, on a world nothing
drives but pressure and gravity, which cancel at balance. **Reproduce:**
`for n in 4 8 16; do scripts/sim_run.sh --rung 3 --frames $n --report wind_speed_max; done`.

`bash scripts/check_wind_subsonic.sh` reads that same peak against the sound speed the substrate states
for it.

`bash scripts/check_atmosphere_at_rest.sh` is rung 3's other gate: its sealed column moves. Its vented
control opens the column's side and reads past it, so the gate has a control.
`docs/PHYSICS_TODO.md` E carries the wind as its own item, and E is downstream of item 1. Until it reads a physical speed no run's numbers
mean anything. `rho_max_open` is the reading that shows it: an open cell may not be denser than the densest
substance the table declares, and that is this item's acceptance test.

`bash scripts/check_boundary_momentum_book.sh` publishes `momentum_book_bnd` on any run holding momentum
rows; its twenty-frame capture arm runs long enough for the wind to refuse the transport.
An offset component of `surface` puts a box on the body without naming a radius.

A slice's one basin cell is seeded brim full and reads back superheated. Reproduce:
`LA_PASS_PROBE=h2o scripts/sim_run.sh --slice --rung 3 --frames 1`.

## 1. THE FIELD GOES NON-FINITE AT THE TOP RUNG, AND NOT REPRODUCIBLY

`bash scripts/agent_harness.sh lint` fails `check_finite_channels.sh` on a null `energy_stock`, or
`check_stack_balance.sh`, or neither, on the same tree. The capture's own world reports non-finite cells
on the runs that fail and none on the runs that pass. **Reproduce:** run `bash scripts/lint_capture.sh`
five times and read nonfinite_cells and energy_stock out of each capture report it writes; or
`scripts/sim_run.sh --path . --frames 20 --seed 4242 --rung 8 --from-seal --report
nonfinite_cells,energy_stock`, which reports non-finite cells with a uniform grid too.

The drain and the capture are not the race: `LAMaterialSphereGPU3D._drain_pending` syncs before
`LAFieldDriver.gather_read`'s copies, and `scripts/lint_capture.sh` renames `report.raw` only after
`sim_run.sh` has exited.

## 1a. TWO SLICE GATES CANNOT RUN

`bash scripts/check_boundary_books.sh` and `bash scripts/check_boundary_momentum_book.sh` exit 2: their
slice arms log `TransportPass: the h2o row's own cells carry a signal speed at or past light`, which is
the substep budget `docs/UNRUNNABLE_GATES_CEILING` names. **Reproduce:** either command.

## 2. The open-boundary books do not close at run level

`scripts/sim_run.sh --frames 20 --slice-capture C` then
`LA_RUN_TIMEOUT=900 scripts/sim_run.sh --slice --slice-state C --frames 650` fires
CONSERVATION_VIOLATION on h2o, nitrogen, mineral, element_C and element_O.

Two things already hold, so the leak is in neither: `check_boundary_books.sh` holds the kernel's
per-dispatch booking closed on that same capture, and the ledger folds the drain on every field step, so
no step's crossings are dropped and nothing is extrapolated over a window.

## 6. The h2o book does not close on a shut box

With every wall shut, `scripts/agent_harness.sh sim --frames 20` ends with `h2o_total` below its sealed
baseline while the element and mineral books close. Same symptom on the pre-conversion tree.

## 4. Reduce the rest on the device

`ReduceRecords` + `reduce.glsl` + `ReducePass` is the machine; the ledger fold and the report sweeps
already use it. Left:

- `FieldPassAttribution3D._sums` walks the channels it downloads at a checkpoint. ReducePass runs last, so
  it cannot answer "which pass moved it": that wants a reduce dispatch per checkpoint, not a row.
- Three shapes refused a row and say why: `sea_surface_stats` (a median needs a declared range nothing
  supplies), `lava_shell_diag` (five outputs over two gates), `rock_radial_profile` (a binned reduction
  plus a gravity march in one walk).

The ops are BUILT — `Mask.GROUND`/`Mask.AIR`, `Op.COUNT_LT`, `enum Nbr` (below, above, six-face gradient)
and the derived `speed`/`lat`/`alt` channels — so a sweep converts without adding machinery, and every
latitude and altitude band is an ordinary row on the existing `gate_lo`/`gate_hi`.

## 5. Move what the device cannot take into the GDExtension

GDScript keeps bindings. `gdextensions/localagents/` already builds; a class is a `.cpp`/`.hpp` pair, one
`SRC` line and one `register_class`.

- **Do not move `PhysicalConstants.gd`.** godot-cpp binds only INTEGER class constants, so its floats
  have no native form a GDScript `const` can fold; native code reads it through
  `include/LAPhysicalRead.hpp`.
- The seed-time serial work still in GDScript: `MaterialFieldSolidCache3D`'s SDF spot check and file
  hashing, `MaterialFieldRegolith3D.compute`'s burial march, and `LAFieldEnthalpySeed.seed`'s per-cell
  loop, which now calls native for the masses and keeps the mixture arithmetic here.

## 8. A --ui run with fauna never reports, and the opening view frames open ocean

`LA_RUN_TIMEOUT=110 scripts/run_sim_offscreen.sh --path . addons/local_agents/game/VoxelWorld.tscn --
--sandbox --ui --run-frames=20` never prints a report and logs no error. The same arm with
`--planet-only --no-fauna` reports in about twenty seconds.

`scripts/check_ground_drawn.sh` passes and its picture is open sea: the spawn controller frames a
bearing with no land on it, while `LAVoxelTerrainService.land_direction()` has bearings that carry land
above the sea shell.


## 7. Build the binding registry

SSBO binding numbers are a bare integer in GLSL and a second bare integer in one of fourteen uniform-set
builders. `check_binding_collisions.sh` check 4 already holds a pass to indices its kernel declares, so what
is unheld is narrower: that one index names the same BUFFER on both sides. Build
`addons/local_agents/sim/material/Bindings.gd` on `Channels.gd`'s shape — a `static func rows()`, never a
`const Dictionary` built from another script's constants — and one gate absorbing the hand-written binding
stanzas. Mutation-test it both ways. Delete the claim below with this item.

<!-- claim: nofile addons/local_agents/sim/material/Bindings.gd -->

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
