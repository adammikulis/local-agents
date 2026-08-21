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

## 0. IDENTICAL-SEED RUNS DIVERGE, AND PRESSURE_BROKEN STILL EXITS 122

**Reproduce the divergence:** `scripts/agent_harness.sh sim --frames 5 --report h2o_total` twice and
diff — `h2o_total` differs in the ninth digit and `pressure_audited` by a few cells, with the field
finite throughout (`check_finite_channels` in `lint` holds it so).

**Reproduce the inversions:** `scripts/sim_run.sh --frames 10` exits 122 with `PRESSURE_BROKEN`, the
DRY open-pair class carrying nearly the whole count and wet/rock/surface near zero.

**The 2.5 km slice still reaches non-finite momentum past ~10 frames** while the default box stays
finite: `scripts/agent_harness.sh sim --slice --slice-box "0,2439700,0,24,32,24,2500" --frames 20 --report nonfinite_cells`.
The cells flanking the wrap seam accumulate multiple fills of h2o first, and `celerity_max` leaves the
physical range before the momentum does. `LA_PASS_PROBE=nonfinite LA_PASS_PROBE_STEPS=12` prints each
pass's peak-cell state and per-channel non-finite counts.

## 2. The open-boundary books do not close at run level, and a capture's six faces read identical

`scripts/sim_run.sh --frames 20 --slice-capture C` then `scripts/sim_run.sh --slice --slice-state C
--frames 650` fires CONSERVATION_VIOLATION on h2o and mineral, and C carries one state on every face —
the box bottom, deep underground, reads the same temperature as the sky. `check_boundary_books.sh` holds
the kernel's per-dispatch booking closed on the same capture, so the work is behind it:

- `MaterialSphereGPU3D.gd` clears `bnd_*` every step and `LABoundaryBooks.sample` multiplies one drained
  rate by the elapsed steps; the crossing integral belongs on the device.
- `LAFieldBoundaryCapture3D._exterior_face_cells` lands every face plane of the default box in the same
  few coarse global cells.

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
- `MixtureEnthalpy.gd` walks a cell's substances and calls native `LASubstances` on every rung, so it
  pays a GDScript-to-native hop per boundary. It is the next class to move.
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

Make every worktree with `scripts/new_worktree.sh`, which symlinks the compiled `bin/`, imports the `.glsl`
kernels and editor-scans. Without the import the GPU field is dead and the report still looks fine.

A gate that passes with the feature disabled is not a gate. Mutation-test every gate you write, both ways.
