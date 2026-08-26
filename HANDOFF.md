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

## 0. PRESSURE_BROKEN EXITS 122, AND THE COUNT GROWS WHILE THE RUN STEPS

`scripts/sim_run.sh --frames 10` exits 122. The DRY open-pair class carries the whole count, rock and
surface read zero, and the count RISES across the run's own reports while `pressure_audited` barely moves.

The audit cannot say how big an inversion is: `LAReducePressureRows` counts `Op.COUNT_GT` on the raw pair
difference against a bare `0.0`, and its numerator gates on `h2o` while its denominator gates on
`pressure`, so the two span different cells.

**A slice goes non-finite while the default box stays finite,** and the momentum run never starts, so
`momentum_book_bnd` is absent and `check_boundary_momentum_book.sh`'s replay arm fails on it. Reproduce:
`scripts/sim_run.sh --frames 20 --slice-capture C`, then
`scripts/sim_run.sh --slice --slice-state C --frames 20 --report nonfinite_cells,momentum_live`.
The cells flanking the wrap seam accumulate multiple fills of h2o first, and `celerity_max` leaves the
physical range before the momentum does. `LA_PASS_PROBE=nonfinite LA_PASS_PROBE_STEPS=12` prints each
pass's peak-cell state and per-channel non-finite counts. An offset component of `surface` puts a box on
the body without naming a radius.

## 1. BUILD THE GRADED GRID. IT IS THE TRUNK AND ITEM 0 WAITS ON IT

`LAFieldLithostaticSeed.shape_atmosphere` seeds the whole atmosphere into one cell shell with vacuum above
whenever the scale height is under a cell edge, and that holds at every resolution the project offers: no
lapse rate, no vertical structure, and the open cells the pressure audit compares are mostly the cube's
corners. Item 0 cannot be read either way until this lands.

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

**The well-balanced scheme is required work, not a hope, and it decides whether the atmosphere is real.**
`transport.glsl`'s `face_p()` already reconstructs face pressure hydrostatically; it has to be good enough
in the stratified direction. Its gate is the only test that matters: an atmosphere at rest, in balance,
stays at rest. Build that gate first and watch it fail.

`check_alt_bands.sh` already fails on this: every populated altitude band reads the same minimum
temperature, because the bands hold one isothermal population and mostly the cube's corners. It goes
green when the atmosphere has vertical structure, so treat it as this item's acceptance test.

`shape_atmosphere`'s `flat` branch is DELETED when this lands. If it cannot come out, the root is not
fixed.

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
- **Blocking `check_gdscript_budget` right now:** `LABodySeeds`, `LABodyMeasure`, `LAOrbitState` and
  `LAFieldCellMass3D`. Their line count is the whole of the lane's overage, and the gate's own message
  names the GDExtension as where serial seed-time work belongs.
- The seed-time serial work: `MaterialFieldLakes3D`'s priority flood, `MaterialFieldSolidCache3D`'s SDF
  spot check and file hashing, `MaterialFieldRegolith3D.compute`'s burial march, `FieldEnthalpySeed3D`'s
  per-cell mixture walk and its dynamic `f.get("_" + name)` lookup.
- The driver: `MaterialSphereGPU3D.gd` and `MaterialField3D.gd`. Last, after the pass seam settles.

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

`scripts/agent_harness.sh sim [--frames N] [--seed N] [--path DIR] [--fauna] [--full] [--raw]` — off-screen,
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

A gate that passes with the feature disabled is not a gate. Mutation-test every gate you write, both ways.
