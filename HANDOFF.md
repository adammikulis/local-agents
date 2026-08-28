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

**WORK THE LADDER IN ORDER.** `scripts/agent_harness.sh ladder` names the first red rung; nothing above it
is measured, and no item about a higher rung is examined until the rungs below it are green.

---

## 1. RUNG 3 DOES NOT COMPLETE ON THE GRADED PLANET (the first red rung; the slab's gate is green both arms)

`scripts/sim_run.sh --rung 3 --frames 2` exits 4: after one frame the run logs `FluxPass: the h2o
record's own cells carry a signal speed at or past light`, and the same run's first frame ends with
open cells under the surface at the ladder's top temperature and at no pressure, gas amounts below
zero and velocities past any signal. The first frame alone completes; `--frames 1` reports.

## 2. NOT EXAMINED UNTIL RUNG 3 IS GREEN — the books above it

- The open-boundary books at run level: `scripts/sim_run.sh --frames 20 --slice-capture C` then
  `LA_RUN_TIMEOUT=900 scripts/sim_run.sh --slice --slice-state C --frames 650` fires
  CONSERVATION_VIOLATION on h2o, nitrogen, mineral, element_C and element_O.
- The h2o book on a shut box: with every wall shut, `scripts/agent_harness.sh sim --rung=8 --frames 20`
  ends with `h2o_total` below its sealed baseline while the element and mineral books close.

## 3. A --ui run with fauna never reports, and the terrain does not reach the eye inside a run

`LA_RUN_TIMEOUT=110 scripts/run_sim_offscreen.sh --path . addons/local_agents/game/VoxelWorld.tscn --
--sandbox --ui --run-frames=20` never prints a report and logs no error; the same arm with
`--planet-only --no-fauna` reports. `scripts/agent_harness.sh ground` exits 2: the terrain under the
camera is never built inside the run's frames, at any rung.

## 4. Reduce the rest on the device

`FieldPassAttribution3D._sums` walks the channels it downloads at a checkpoint; a reduce dispatch per
checkpoint replaces it. Three shapes refused a row and say why: `sea_surface_stats`, `lava_shell_diag`,
`rock_radial_profile`.

## 5. Move what the device cannot take into the GDExtension

Still GDScript on the seed path: `MaterialFieldSolidCache3D`'s SDF spot check and file hashing,
`MaterialFieldRegolith3D.compute`'s burial march, `LAFieldEnthalpySeed.seed`'s per-cell mixture loop.
Do not move `PhysicalConstants.gd`: godot-cpp binds only integer class constants.

## 6. Build the binding registry

SSBO binding numbers are a bare integer in GLSL and a second bare integer in each uniform-set builder.
Build `addons/local_agents/sim/material/Bindings.gd` on `Channels.gd`'s shape and one gate absorbing the
hand-written binding stanzas; mutation-test both ways. Delete the claim below with this item.

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
