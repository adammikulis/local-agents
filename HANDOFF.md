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

## 0. MOMENTUM RUNS AWAY TO NON-FINITE. THE SLICE IS THE TEST DOMAIN.

Same lane, second symptom: **identical-seed runs diverge on a clean tree.** Reproduce:
`scripts/agent_harness.sh sim --frames 5 --report h2o_total` twice and diff — one key differs at 5
frames and the whole report by 20. Transport, gravity, pressure and the reduce fold are
order-independent by construction.

**Reproduce:** `LA_FINITE_FRAMES=20 scripts/check_finite_channels.sh` on `feature/momentum-advection`.
`nonfinite_cells` counts three per affected cell — `mom_x`/`mom_y`/`mom_z` and nothing else.

`scripts/sim_run.sh --frames 10` also exits 122 with `PRESSURE_BROKEN`, whose counters read 0 for
rock-on-rock and 0 for open-standing-on-rock; the remainder are open-on-open.

The gate is mutation-tested three ways and is **NOT wired into `lint`**. Wire it the moment it passes.
`feature/momentum-advection` carries the work, declared in `docs/OPEN_BRANCHES.md`.

## 2. The open-boundary books do not close at run level, and a capture's six faces read identical

`scripts/sim_run.sh --frames 20 --slice-capture C` then `scripts/sim_run.sh --slice --slice-state C
--frames 650` fires CONSERVATION_VIOLATION on h2o and mineral, and C carries one state on every face —
the box bottom, deep underground, reads the same temperature as the sky. `check_boundary_books.sh` holds
the kernel's per-dispatch booking closed on the same capture, so the work is behind it:

- `MaterialSphereGPU3D.gd` clears `bnd_*` every step and `LABoundaryBooks.sample` multiplies one drained
  rate by the elapsed steps; the crossing integral belongs on the device.
- `LAFieldBoundaryCapture3D._exterior_face_cells` lands every face plane of the default box in the same
  few coarse global cells.
- `MaterialFieldMomentumLedger3D` accumulates its `_cum_*` books only across report samples, and a
  measurement run reports once, so `momentum_book_bnd` cannot fold in that mode.

## 4. Reduce the rest on the device

`ReduceRecords` + `reduce.glsl` + `ReducePass` is the machine; the ledger fold and the report sweeps
already use it. Left:

- `FieldPressureAudit3D`, `MaterialFieldMomentumLedger3D`.
- `clim_alt_min` (per-altitude-band minima above the sea shell) needs `sea_radius` on the device: a static
  row cannot carry an instance value, so give `MaterialSphereGPU3D._ctx` a setter like `set_sun_dir` and
  let `state_derive.glsl` write `alt` relative to the shell; the open-air `air_grad_*` rows measure the
  lapse until then.
- `FieldPassAttribution3D._sums` walks the channels it downloads at a checkpoint. ReducePass runs last, so
  it cannot answer "which pass moved it": that wants a reduce dispatch per checkpoint, not a row.
- Three shapes refused a row and say why: `sea_surface_stats` (a median needs a declared range nothing
  supplies), `lava_shell_diag` (five outputs over two gates), `rock_radial_profile` (a binned reduction
  plus a gravity march in one walk).

The ops are BUILT — `Mask.GROUND`/`Mask.AIR`, `Op.COUNT_LT`, `enum Nbr` (below, above, six-face gradient)
and the derived `speed`/`lat`/`alt` channels — so a sweep converts without adding machinery, and every
latitude and altitude band is an ordinary row on the existing `gate_lo`/`gate_hi`.

Free today, no new op: `momentum_vec` is three `SUM` rows on `vel_*` with `aux: "air"`, weighted, OPEN;
`momentum_mass_kg` is one. **Coriolis then costs nothing** — it is linear in v, so it is
`spin × momentum_vec × -2Ω` on the CPU, and the per-cell accumulation is pure waste.

## 5. Move what the device cannot take into the GDExtension

GDScript keeps bindings. `gdextensions/localagents/` already builds; a class is a `.cpp`/`.hpp` pair, one
`SRC` line and one `register_class`.

- The tables: `Substances.gd`, `AbsorptionBands.gd`, `PhysicalConstants.gd`. Move
  `check_physical_constants.sh`, `check_model_parameters.sh` and `gen_shared_constants.py` in the same
  commit — a gate left parsing a deleted file is a gate that cannot fail.
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

## 12. `LAFieldGeometry.above` and `below` are not inverses, and `PRESSURE_BROKEN` still fires on it

`slot_toward` snaps the local vertical to one of six axes, so across the diagonal where the snap flips,
`above(below(c)) != c`. The pressure column, `air_above`, `ground` and `burial_steps` all march that
relation, and no column integral can be monotone along a `below` step its own `above` step does not undo.
One vertical relation, built once and inverse by construction, is what removes it.

**A RADIAL COORDINATE SYSTEM IS NOT THE ANSWER. This is the maintainer's DECISION, not a law.** It has been
tried twice: the cubed-sphere shell was replaced by the uniform Cartesian box on purpose, and a
true-radial-ray traversal built to remove this very snap measured WORSE, because with no structural relation
to the grid's own vertical step, ray divergence across a density contrast dominates. Fix the relation on the
Cartesian grid.

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
