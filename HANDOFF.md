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

## 1. FEED THE OPEN BOUNDARY A REAL EXTERIOR, AND A SLICE BECOMES TESTABLE. TAKE THIS FIRST.

The seam is `LAFieldBoundary3D` (SHUT/WRAP/CONSTANT/REPLAY per face; node meta -> project setting ->
`LA_BOUNDARY_FACES`); CONSTANT and REPLAY refuse to run without a supplied state. What is left:

- **The capture pipeline.** Store a global run's drain as per-face states plus a time series, and feed
  `LAFieldBoundary3D.replay(face, state)` per step. One stored global run drives many slice runs.
- **Momentum crossing an open face is unbooked** — the mom rows bind `bnd_void` in `TransportPass._row_set`,
  so an open-boundary slice's momentum ledger residual carries the crossings. Give momentum its boundary
  book, the per-substance `bnd_*` shape.
- **One-way nesting reflects waves inward near the edge.** A relaxation zone is the standard answer and is
  an approximation, so it takes a row and an `LA_APPROX` marker.
- **Leave global, each cheap and none local:** the deep heat flux on the bottom face, without which no magma
  arrives from below; the solved potential sampled in, nearly uniform over a thin patch.

**Why it unblocks testing:** not speed at equal cells, but a SMALL SUFFICIENT domain. At the cell size a
whole planet forces, rain and eruptions may not be reachable at all. A slice with a declared boundary makes
"moist convection precipitates" and "overpressure erupts" assertions a gate can make.

## 0. MOMENTUM RUNS AWAY TO NON-FINITE. DOWNSTREAM OF ITEM 1; DO NOT START IT FIRST.

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

## 3. Sunlight reflected off the ground goes nowhere

`transport.glsl`'s gather takes `sun_w * sw_absorbed * (1 - shortwave_albedo)` and the beam march removes
the whole absorbed share, so what a surface reflects is subtracted from the beam and deposited in no cell.
Reflected shortwave is a real flux that crosses the atmosphere again and may be absorbed on the way out.
Building it means a scattered shortwave field, which no gate covers yet.

The band table also stops at 10000 cm^-1 and carries no ozone, so there is no stratospheric UV absorber.
That is a missing absorber rather than a fitted constant: `scripts/derive_absorption_bands.py` and
`scripts/fetch_hitran.sh` are where a species is added.

`check_radiative_row.sh` asserts the Stefan-Boltzmann law on its own isothermal block and NOT on the world
the sim seeds; its seeded arm reads only the sign of the two radiative books. The honest form is a per-cell
residual of `rad_emitted` against `6 * e * STEFAN * T^4 * dt / L`, computed in the RADIATE path beside the
field it measures and reduced to a MAX, exactly as gravity publishes Gauss's law.

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

## 9. An undeclared seed

- `MaterialSphereGPU3D._seed_silicate()` writes the whole `silicate` and `cement` buffers with
  `buffer_update` and never calls `note_creation`, so the planet's entire rock mass is absent from the seed
  manifest that is meant to be the scoreboard of what the substrate was told. `MaterialField3D` declares the
  same fact a second time.

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
