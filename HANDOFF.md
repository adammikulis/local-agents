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

## 1. The REPLAY rim skips the momentum rows

The slice runs (`scripts/sim_run.sh --slice`; record a global run's exterior with `--slice-capture FILE`,
consume it with `--slice --slice-state FILE`, series-feed with `LA_SLICE_REPLAY=1`). Momentum's boundary
book exists (`BoundaryRows.BOOKED_SIGNED`), so the rim's reason for skipping the mom rows is gone: mark
them `relax` in `TransportRecords`, and verify the rim's nudge lands in `bnd_mom_*` on the REPLAY arm.

## 0. IDENTICAL-SEED RUNS DIVERGE, AND PRESSURE_BROKEN STILL EXITS 122

**Reproduce the divergence:** `scripts/agent_harness.sh sim --frames 5 --report h2o_total` twice and
diff — `h2o_total` differs in the ninth digit and `pressure_audited` by a few cells, with the field
finite throughout (`check_finite_channels` in `lint` holds it so).

**Reproduce the inversions:** `scripts/sim_run.sh --frames 10` exits 122 with `PRESSURE_BROKEN`, the
DRY open-pair class carrying nearly the whole count and wet/rock/surface near zero. On the slice
(`scripts/agent_harness.sh sim --slice --slice-box "0,2439700,0,24,32,24,2500" --frames 20`, finite)
the cells flanking the wrap seam accumulate multiple fills of h2o.

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
