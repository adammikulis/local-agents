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

## 0. THE TWO HALVES OF `h_j_m3` DISAGREE, AND ONE OF THEM IS INFINITE. TAKE THIS FIRST.

`energy_stock` serialises to null and the run logs Godot's own "NaN found in JSON.stringify". Every ledger
watt goes null with it: `energy_absorbed_w`, `energy_emitted_w`, `energy_net_w`, `energy_booked`,
`energy_residual`. The energy conservation row reads UNMEASURED rather than conserved.

`h_j_m3` is a PAIR channel. Read both halves off the device on the same step and they hold different
worlds: one carries a physically ordinary enthalpy density, the other carries `inf`. The CPU mirror
`_f._h` — which `LAMaterialFieldSphereStep3D.step()` hands straight back to `begin_frame()` to upload —
carries the infinite one. Cells whose enthalpy is enormous report ordinary temperatures, and at least one
of them reports exactly `-273.15`, the `total <= 0.0` branch of `state_derive.glsl`: no matter at all.

**Reproduce:** in `MaterialSphereGPU3D`, read `_bufs["h_j_m3"][0]` and `_bufs["h_j_m3"][1]` back after a
step and compare their maxima, against `_f._h`'s. `MaterialFieldQueries3D.row_f("all_temp_max")` reads
correctly at the same moment, so `temp` derives from the sound half while the mirror does not.

Nothing measured anywhere in the substrate means anything while this holds: temperature is derived from
enthalpy every step and drives the phase ladder, every reaction gate and both radiative terms. Note
`_live()` returns `_bufs[name][_phase]` and `step()` flips `_phase` after dispatching, while the readback
runs from the NEXT `begin_frame` — establish which half each pass writes before changing anything.

## 1. Reduce the rest on the device

`ReduceRecords` + `reduce.glsl` + `ReducePass` is the machine; the ledger fold and twenty-one report
sweeps already use it. Left:

- `MaterialFieldReport3D.surface_climate`, `MaterialFieldPhotoStats3D`,
  `MaterialFieldClimateSwing3D._site_stations`.
- `FieldPressureAudit3D`, `MaterialFieldMomentumLedger3D`, `MaterialFieldElementProbe3D`,
  `MaterialFieldOrganic3D`.
- `CLIMATE_MAX_CELLS` and its stride delete with the climate scan.
- `FieldPassAttribution3D._sums` walks the halves it downloads at a checkpoint. ReducePass runs last, so
  it cannot answer "which pass moved it": that wants a reduce dispatch per checkpoint, not a row.
- Three shapes refused a row and say why: `sea_surface_stats` (a median needs a declared range nothing
  supplies), `lava_shell_diag` (five outputs over two gates), `rock_radial_profile` (a binned reduction
  plus a gravity march in one walk).
- `_liquid_mirror` is a per-cell product of two buffers the GPU already holds, rebuilt per drinking
  creature per tick. A derived buffer written by `StateDerivePass` deletes the loop with no reduce row at
  all; its four consumers convert with it, and `drink` stops writing its depletion into a throwaway copy.

The ops are BUILT — `Mask.GROUND`/`Mask.AIR`, `Op.COUNT_LT`, `enum Nbr` (below, above, six-face gradient)
and the derived `speed`/`lat`/`alt` channels — so a sweep converts without adding machinery, and every
latitude and altitude band is an ordinary row on the existing `gate_lo`/`gate_hi`.

Free today, no new op: `momentum_vec` is three `SUM` rows on `vel_*` with `aux: "air"`, weighted, OPEN;
`momentum_mass_kg` is one. **Coriolis then costs nothing** — it is linear in v, so it is
`spin × momentum_vec × -2Ω` on the CPU, and the per-cell accumulation is pure waste.

## 2. Collapse the per-cell kernels into one dispatch

`CellListPass` is the seventh, and it stays a pass until the compaction becomes a mode of `transport.glsl`:
`check_binding_collisions.sh` fails any pass naming two kernel paths, so it cannot simply be folded into
`TransportPass`. The compaction needs workgroup-shared memory and barriers in uniform control flow, which
`PASS_GRAIN` shows a transport mode can carry.

The target is six: gravity, derive, pressure, transport, reactions, reduce.

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

## 9. An instrument that cannot fire, and two re-sweeps

- `FieldAttributionRecords3D.SILENT_HEAT_PASSES` now lists only `"fungus"`, and there is no `FungusPass` in
  `PASS_SCRIPTS` — while `PRODUCERS` still names one for a channel `Channels.gd` declares as a single
  buffer. That instrument's silent-heat check names no live pass, so it cannot fire. Wire it to the
  surviving passes or delete it. Removing the constant outright breaks `check_parse_all` — it is read from
  inside its own file.
- `check_shaders_compile.sh`'s kernel floor is `docs/SHADER_FLOOR` and `write_ceilings.sh` lowers it. Do not
  bake a count back into the gate.
- `MaterialFieldReport3D` publishes `element_C_total_drift_per_step`, a bare-SI rate with no consumer; the
  dimensionless `element_C_total_rel_drift` beside it is what anything reads. One-line deletion.
- `PHYSICS_RUBRIC.md` quotes `energy_residual / energy_booked` figures in prose. That denominator no longer
  exists — the residual is a fraction of turnover now — and measured figures in a doc are banned anyway.
- `LASpatialIndex.rebuild_if_stale` rebuilds a whole group's dictionary every frame it is touched rather
  than tracking per-node cell changes, and `LASimReport.snapshot` deep-copies its events and gauges on every
  call. Both are constants, not asymptotes.

## 10. A constant that is not what it names

- `AMBIENT_O2_DENSITY_KG_M3` is air at a different temperature from `AIR_DENSITY_KG_M3`, and it is the unit
  definition of the `o2`, `co2` and `n2` channels, so correcting it rescales every gas total.

## 11. Rebuild frost shattering from the phase boundary

`LAGeoRecords` has no `RM_DEFICIT_BELOW_THRESHOLD` record, no `FROST_*` constant survives, and the rate
model is declared in `ReactionDefs` and used by nothing. The mechanism is ice segregation, not expansion in
a sealed pore. Invert `LASubstances.melt_c_at`: the pressure ice exerts at undercooling dT is
`dH_fus * dT / (T_m * dv)` with `dv = 1/rho_ice - 1/rho_water`, every term already in the table, about
13.5 MPa per kelvin. Rock fractures where that passes its TENSILE strength, which is a measured property
`Substances.gd` should carry with its source. Bound the extent by the pore water available to freeze, and
let deep cold starve the mechanism out of the state rather than a cutoff. Observed damage peaks at -3 to
-10 C: if the law disagrees, that is the finding, not a thing to tune.

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
