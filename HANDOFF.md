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

`bash scripts/check_process_ladder.sh` climbs to `hydrostatic` and stops at `acoustic`: that rung's own
arm, `scripts/agent_harness.sh sim --rung=3 --frames 8`, refuses to transport the h2o row because its
cells carry a signal speed at or past light, so no timestep integrates them and the harness withholds
every number.

`scripts/sim_run.sh --slice --rung 3 --frames 5` completes instead, and reads non-finite cells and
pressure falling going down in open cells.

`scripts/check_rung_acoustic.sh` and `scripts/check_atmosphere_at_rest.sh` are the acceptance tests. The
rest gate's sealed column moves, and its vented control does not finish inside
`docs/RUN_TIMEOUT_CEILING`, so the gate reports it has no control.
`docs/PHYSICS_TODO.md` E carries the wind as its own item, and E is downstream of item 1. Until it reads a physical speed no run's numbers
mean anything. `rho_max_open` is the reading that shows it: an open cell may not be denser than the densest
substance the table declares, and that is this item's acceptance test.

`bash scripts/check_boundary_momentum_book.sh` fails on the same refusal: its capture arm runs the
acoustic rung, which is where the momentum rows it weighs live.
An offset component of `surface` puts a box on the body without naming a radius.

## 1. BUILD THE GRADED GRID. IT IS THE TRUNK AND ITEM 0 WAITS ON IT

At every resolution the project offers, no open cell centre lies within a scale height of the surface, so
the seeded atmosphere is one shell with vacuum above it: no lapse rate, no vertical structure, and the
open cells the pressure audit compares are mostly the cube's corners. Item 0 cannot be read either way
until this lands.

**The grid is Cartesian with axis-aligned refinement. That is settled, with the reasoning, in
`docs/PHYSICS_TODO.md` — do not re-open it.** What is left is to build it:

- `LAVoxelGrid` gains per-cell geometry: refinement level, edge length, per-face area and centre distance.
  `cell_volumes()` stops filling one repeated value.
- `neighbours` generalises from six fixed slots to a per-cell face list, so a coarse cell can face four
  fine ones; `opposite_slot(d) = d ^ 1` becomes a stored partner slot and `check_neighbour_slots.sh`
  gates the new single definition.
- On the device, `params.cell_m` is replaced by per-cell and per-face buffers beside the `cell_vol` SSBO
  that `kernels3d/cellvol.glsli` already reads. `transport.glsl`, `transport_radiate.glsli`,
  `gravity_poisson.glsl`, `pressure.glsl`, `reduce.glsl` and `march.glsli` carry every site.
- Refinement is seeded from distance to the terrain SDF, which `MaterialFieldSolidCache3D` already
  samples. The vacuum corners and the quiet interior stay coarsest, which is what makes it affordable.
- The slice box becomes a refinement region rather than a second construction path.

**`check_voxel_grid.sh` asserts `volume_ratio == 1.0`** — a gate holding the grid uniform. It is INVERTED,
not deleted: it becomes the gate that a 2:1 neighbour's volume ratio is exactly 8 and that every transfer
goes through `cellvol.glsli`'s existing `vol_ratio(donor, receiver)`.

**The well-balanced scheme is required work, not a hope, and it decides whether the atmosphere is real.**
`scripts/check_atmosphere_at_rest.sh` is its gate and it is RED: the sealed column's own reading is
reproducible only when the run draws no ambient event, and a cell's pressure leaves the value it was
seeded with. Reproduce: `bash scripts/check_atmosphere_at_rest.sh`.

`check_alt_bands.sh` already fails on this: every populated altitude band reads the same minimum
temperature, because the bands hold one isothermal population and mostly the cube's corners. It goes
green when the atmosphere has vertical structure, so treat it as this item's acceptance test.

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

## 3. Three GPU gates are red and none is triaged

`check_slice_exterior.sh` reports `the exterior under the box is not under more pressure than the
exterior over it` and `SLICE_EXTERIOR_CAPTURE={"faces":6,"named":0}`. `check_alt_bands.sh` and
`check_boundary_momentum_book.sh` are red for the reasons items 1 and 0 carry.

Reproduce: `bash scripts/check_slice_exterior.sh`.

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
- The seed-time serial work still in GDScript: `MaterialFieldHydrosphere3D`'s priority flood,
  `MaterialFieldSolidCache3D`'s SDF spot check and file hashing, `MaterialFieldRegolith3D.compute`'s
  burial march, `FieldEnthalpySeed3D`'s per-cell mixture walk and its dynamic `f.get("_" + name)` lookup.
- The driver: `MaterialSphereGPU3D.gd` and `MaterialField3D.gd`. Last, after the pass seam settles.

## 8. A --ui run with fauna never reports, and the opening view frames open ocean

`LA_RUN_TIMEOUT=110 scripts/run_sim_offscreen.sh --path . addons/local_agents/game/VoxelWorld.tscn --
--sandbox --ui --run-frames=20` never prints a report and logs no error. The same arm with
`--planet-only --no-fauna` reports in about twenty seconds.

`scripts/check_ground_drawn.sh` passes and its picture is open sea: the eye stands 95 m over the water
on a bearing the spawn controller framed, while `LAVoxelTerrainService.land_direction()` reports 59 of
128 bearings carry land above the sea shell.


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
`timeout waiting for fence`. Finish the whole change set, then commit once: the pre-commit hook runs the
full lint, so a commit per step is a lint per step. A run past `docs/RUN_TIMEOUT_CEILING` needs an explicit
`LA_RUN_TIMEOUT` and is a declared soak.

Make every worktree with `scripts/new_worktree.sh`, which symlinks the compiled `bin/`, imports the `.glsl`
kernels and editor-scans. Without the import the GPU field is dead and the report still looks fine.
Each worktree gets its OWN `bin/`: one shared copy cannot serve two trees whose native `class_name`s
differ, and the other tree stops parsing with "hides a native class".

A gate that passes with the feature disabled is not a gate. Mutation-test every gate you write, both ways.
