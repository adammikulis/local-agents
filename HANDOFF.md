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

**WORK THE LADDER IN ORDER.** `scripts/agent_harness.sh ladder` names the first red rung; nothing above it
is measured, and no item about a higher rung is examined until the rungs below it are green.

---

## 2. THE WIND BLOWS PAST ITS OWN SOUND SPEED (rung 3, the first red rung)

`bash scripts/check_rung_acoustic.sh` reads a cell moving faster than its own sound speed; the peak stops
climbing and holds, far past the ~70 m/s of a real jet stream, on a world nothing drives but pressure and
gravity. **Reproduce:** `for n in 4 8 16; do scripts/sim_run.sh --rung 3 --frames $n --report wind_speed_max; done`
and `bash scripts/check_wind_subsonic.sh`. `bash scripts/check_atmosphere_at_rest.sh` is the rung's other
gate: its sealed column moves and its vented control reads differently.

The energy book weighs specific enthalpy where the first law wants internal energy, and no row publishes
the pV between them (`docs/PHYSICS_TODO.md` E carries it with its reproducer).

## 3. LINT FOLLOWS THE LADDER

`scripts/lint_capture.sh` records its shared arm at `--rung 8` while the ladder stops at rung 3, so lint
reads a world the ladder refuses to examine. The capture runs at the highest green rung
(`docs/PLAYABLE_RUNG`); a gate that needs a process above it is assigned to that rung in `LAProcessSet`
and exits 2 ("not examined") until the ladder reaches it; `docs/UNRUNNABLE_GATES_CEILING` then counts
the rungs the ladder has not reached, not defects. Reproduce: `rg -n "rung 8" scripts/lint_capture.sh`.

## 4. THE GRADED GRID — built, on tag `wip/graded-grid`, not landed

`scripts/new_worktree.sh feature/graded-grid wip/graded-grid`, merge the dev branch, then
`scripts/integrate.sh feature/graded-grid`. It refuses today because lint's rung-8 capture reads non-finite
cells on the refined grid and twelve gates exit 2 — item 3 is what lets it land. What it leaves: `check_finite_channels`/`check_stack_balance` read non-finite cells through the
shared capture and not on a direct run of the same world (`scripts/lint_capture.sh` five times: the
count varies run to run; a uniform box reproduces the non-finite cells deterministically) — that is the
wind, item 2. Two slice gates, `check_boundary_books.sh` and `check_boundary_momentum_book.sh`, exit 2 on
the transport substep budget for the slice.

## 5. NOT EXAMINED UNTIL RUNG 3 IS GREEN — the books above it

- The open-boundary books at run level: `scripts/sim_run.sh --frames 20 --slice-capture C` then
  `LA_RUN_TIMEOUT=900 scripts/sim_run.sh --slice --slice-state C --frames 650` fires
  CONSERVATION_VIOLATION on h2o, nitrogen, mineral, element_C and element_O.
- The h2o book on a shut box: with every wall shut, `scripts/agent_harness.sh sim --rung=8 --frames 20`
  ends with `h2o_total` below its sealed baseline while the element and mineral books close.

## 6. A --ui run with fauna never reports, and the terrain does not reach the eye inside a run

`LA_RUN_TIMEOUT=110 scripts/run_sim_offscreen.sh --path . addons/local_agents/game/VoxelWorld.tscn --
--sandbox --ui --run-frames=20` never prints a report and logs no error; the same arm with
`--planet-only --no-fauna` reports. `scripts/agent_harness.sh ground` exits 2: the terrain under the
camera is never built inside the run's frames, at any rung.

## 7. Reduce the rest on the device

`FieldPassAttribution3D._sums` walks the channels it downloads at a checkpoint; a reduce dispatch per
checkpoint replaces it. Three shapes refused a row and say why: `sea_surface_stats`, `lava_shell_diag`,
`rock_radial_profile`.

## 8. Move what the device cannot take into the GDExtension

Still GDScript on the seed path: `MaterialFieldSolidCache3D`'s SDF spot check and file hashing,
`MaterialFieldRegolith3D.compute`'s burial march, `LAFieldEnthalpySeed.seed`'s per-cell mixture loop.
Do not move `PhysicalConstants.gd`: godot-cpp binds only integer class constants.

## 9. Build the binding registry

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
