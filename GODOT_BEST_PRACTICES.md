# GODOT_BEST_PRACTICES

Purpose: prevent repeated Godot parser/runtime/testing mistakes with short, enforceable rules.

## Core Rules

- This file is mandatory startup reading and required process for every session.
- Simplicity mandate (non-negotiable): choose the simplest implementation that works correctly for the required behavior.
- Anti-overengineering mandate (non-negotiable): reject long or complex runtime pipelines when a shorter direct path satisfies the same requirement.
- C++-first mandate (non-negotiable): implement runtime gameplay/simulation/destruction behavior in C++ unless absolutely necessary to use GDScript.
- GDScript exception rule (non-negotiable): when GDScript is unavoidable, keep it minimal and limited to orchestration, scene wiring, input/UI, or typed adapter boundaries.
- Use Godot 4 constants exactly as defined in docs/API. Do not guess names.
- Prefer explicit typing for locals that hold dynamic data (`Dictionary`, `Array`, `Object` checks).
- Keep command invocation patterns canonical and copied from repo harness docs.
- Always run SceneTree harness entrypoints with `-s`; otherwise Godot can fail with `doesn't inherit from SceneTree or MainLoop`.
- Do not claim "works" unless required validation steps have run on the current tree.
- Simulation-authoritative execution is native + GPU only; GDScript is orchestration/adapters only for simulation paths.
- Shader-first execution mandate (non-negotiable): simulation/render authority defaults to shader/native GPU stages when practical.
- Reduced cross-boundary interactions mandate (non-negotiable): minimize C++<->GDS and CPU<->GPU boundary hops; keep interaction paths single-hop unless an engine boundary is required.
- GPU-native handshake requirement (non-negotiable): startup must complete native-extension + GPU-capability + shader-pipeline handshake before enabling gameplay mutation/destruction paths.
- CPU/GDScript success fallbacks for simulation outcomes are forbidden; missing requirements must fail explicitly.
- GDS adapter authority rule: gameplay-runtime GDS layers are adapter-only and must not own mutation outcome logic or decide mutation success/failure.
- Projectile impact destruction rule: enforce a direct authoritative flow only as `impact contact -> C++ mutation -> apply result`.
- Ban multi-hop GDS contract layers on projectile destruction paths: no flatten/interpret/rewrap chains in GDS for mutation authority.
- Transitional tracking for remaining CPU/GDS pieces (recommended hygiene): note CPU/GDS transitional segments in `ARCHITECTURE_PLAN.md` when they are worth remembering, with enough context (owner / removal trigger / target wave / blocker are useful fields) to retire them later. This is guidance, not a grep-gated mandatory format.
- When a preventable error appears, add a dated entry to `Error Log / Preventative Patterns` in this file.

## Godot Design and Structure Process

- Keep simulation-authoritative gameplay logic (physics/destruction/voxel mutation/state evolution) in native code with GPU execution contracts.
- Prefer shader/native execution stages over CPU orchestration for simulation/render hot paths.
- Keep runtime execution paths short and direct; avoid multi-hop controller/stage chains unless required by a concrete engine or contract boundary.
- Reduce cross-boundary handoffs between runtime layers; avoid repeated GDS/native or CPU/GPU ping-pong in authoritative paths.
- Keep GDScript focused on orchestration, scene wiring, input/UI, and typed boundary adapters.
- Prefer explicit data flow (`signal up, call down`) over hidden singleton coupling.
- Decompose concerns with clear ownership; avoid deep inheritance chains.
- Use scenes/Resources/graphs before ad-hoc dictionary state.
- Plugin boundary is `addons/local_agents/`.
- Use `hex_pointy` grid defaults unless explicitly required otherwise.
- Centralize partitioning/grid configuration in shared resources.
- Keep editor code under `addons/local_agents/editor/`; use `@tool` only where required.
- Keep runtime logic outside editor UI controllers.
- Store reusable data in typed `Resource` classes under `configuration/parameters/`.

## GDScript, Nodes, and Runtime Safety

- **No inferred typing (`:=`).** Declare variables and constants with an explicit type —
  `var count: int = 0`, `var pos: Vector3 = ...`, `var nodes: Array = get_tree()...`. Use `: Variant`
  (or plain untyped `var x = ...`) only when the type genuinely can't be named. The type must be
  stated, never implied. Enforced by `scripts/check_no_inferred_typing.sh` (part of `lint`).
- Use explicit types where they improve correctness and tooling.
- Use custom class annotations when helpful, and `preload` for load-order sensitive paths.
- In unstable bootstrap chains, prefer runtime checks over brittle class annotations.
- Validate external inputs before use.
- Return structured error dictionaries for runtime/service APIs.
- Keep scenes composable and shallow with stable wiring via exported `NodePath` and `@onready` references.
- Use one responsibility per controller node.
- Avoid anonymous callables in `.tscn` files for business logic.
- Use signals for cross-node flow and controller-down calls for owned children.
- Connect signals in `_ready()` and disconnect on teardown for non-trivial lifecycles.
- Avoid duplicate signals for the same transition.

## Concurrency, Paths, and Native Dependency Rules

- Keep the UI thread non-blocking; use worker threads/native async for expensive work.
- Never mutate UI from worker threads; hand off with deferred calls.
- Join and clean up `Thread` instances on node exit.
- Normalize `res://`, `user://`, and absolute paths before file operations.
- Use `RuntimePaths` helpers for platform-specific outputs.
- Ensure directories exist before writes and handle write errors explicitly.
- Do not commit downloaded runtime artifacts, models, or caches.
- Required GDExtensions are mandatory dependencies; fail loudly and stop when missing.
- Do not ship local fallback paths for missing required extensions or GPU capabilities.
- Treat required GPU compute/fragment capabilities as mandatory for voxel simulation and fail fast when unavailable.
- Initialize required extensions explicitly and guard calls with singleton/method availability checks.
- Keep fetch/build scripts idempotent and aligned with CI/local command usage.

## Native/GPU-only Execution Mandate (Enforceable)

- This repository is native/GPU-authoritative for simulation behavior; CPU/GDScript fallback success paths are disallowed.
- Do not implement or preserve alternate simulation-authoritative execution in GDScript.
- If native extension contracts or required GPU capabilities are unavailable, stop execution with explicit failure; never degrade to CPU-success simulation.
- Required invariants:
  - `INV-NATIVE-001`: Voxel mutation/destruction/simulation hot stages execute through native contracts only.
  - `INV-GPU-001`: GPU capability requirement is mandatory; unavailable GPU emits hard failure (`GPU_REQUIRED` / `gpu_unavailable`).
  - `INV-FALLBACK-001`: No reachable CPU-success or GDScript-success fallback path for simulation-authoritative outcomes.
  - `INV-CONTRACT-001`: No silent success/no-op on contract failure; failures must be typed and explicit.
  - `INV-HANDSHAKE-001`: Required GPU-native handshake must complete before simulation-authoritative gameplay is enabled.
  - `INV-BOUNDARY-001`: Authoritative simulation/destruction paths must not include avoidable multi-hop cross-boundary interactions.
  - `INV-PROJECTILE-CPP-001`: Projectile impact -> voxel mutation authority is C++ native stage owned end-to-end; GDScript must not own queue/deadline mutation decisions for this path.
  - `INV-STAGE-SHIM-001`: Stage-shim/controller layers are adapter-only and cannot author/override projectile mutation success, deadline pass/fail, or mutation-applied outcomes.
  - `INV-GDS-ADAPTER-ONLY-001`: Gameplay-runtime GDS adapters are forwarding-only for mutation paths and cannot own or interpret mutation outcome authority.
  - `INV-PROJECTILE-DIRECT-001`: Projectile destruction authority executes only through the direct chain `impact contact -> C++ mutation -> apply result`.
  - `INV-NO-GDS-MULTIHOP-001`: Multi-hop GDS contract flatten/interpret/rewrap layers are forbidden on projectile impact destruction paths.
- Concrete migration checklist (for each touched simulation path):
  - [ ] Identify existing CPU/GDScript-success fallback branches.
  - [ ] Replace fallback-success branches with explicit fail-fast outcomes.
  - [ ] Route mutation/destruction authority through native interfaces only.
  - [ ] For projectile impacts, keep queue/deadline lifecycle and mutation pass/fail authority in C++ native stage contracts only (no GDScript queue ownership).
  - [ ] Remove or block stage-shim authority for projectile mutation outcomes; shims may only forward payloads and consume typed native outputs.
  - [ ] Add/adjust tests asserting native/GPU backend usage on primary path.
  - [ ] Verify GPU-native handshake evidence is emitted before enabling authoritative simulation paths.
  - [ ] Remove avoidable cross-boundary interaction hops from touched authoritative paths.
  - [ ] Add/adjust tests asserting typed failure when native/GPU requirements are unmet.
  - [ ] Re-run mandatory validation sequence before any status claim.
- Error policy (mandatory):
  - Startup/runtime must hard-fail on missing GPU requirement with explicit `GPU_REQUIRED`/`gpu_unavailable` diagnostics.
  - Missing required native extension/contract must hard-fail with explicit `NATIVE_REQUIRED`/`native_unavailable` diagnostics.
  - Attempts to take CPU/GDScript fallback-success simulation path must emit explicit failure (`CPU_FALLBACK_FORBIDDEN`/`fallback_blocked`) and stop that execution path.

## Validation and Status Claim Gates

- Maintain a fast headless-safe core suite and a higher-cost runtime suite.
- Auto-acquire required test assets/models when available; fail loudly when acquisition fails.
- Require `godot --headless --no-window` paths in CI-relevant flows.
- Avoid per-frame allocations in hot paths and profile long-running runtime work.
- Do not claim demo/runtime "works" without required validation evidence on the current tree.
- Required full-sweep baseline for any "demo is working" claim:
  - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
  - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`
- Any code edit after a passing sweep invalidates that result.
- Before reporting status, rerun the required full-sweep baseline on the latest tree.
- If a command fails, continue fixing and rerunning or report exact blockers and failing tests.
- Never infer green status from earlier runs, partial suites, or nearby commits.
- If gameplay/demo/input scripts were edited, run a headless scene-smoke harness before status claims.
- Any "works"/"ready" claim for player-facing behavior requires both evidence classes on the latest tree (run in either order — ordering is not mandated):
  - headless harness suite pass
  - non-headless run through an actual video/display path
- If non-headless launch is not possible in the environment, state that limitation explicitly and do not claim "works/ready".
- If a user reports an immediate parse/runtime error after a "works" claim, treat it as process failure: stop, acknowledge failed validation, rerun full validation, and do not re-claim status until all required checks pass.
- For native/GPU-authoritative simulation changes, validation evidence must also show:
  - primary-path execution uses native/GPU backend metadata (no CPU-success backend on authoritative simulation path),
  - missing native/GPU requirements fail with explicit typed reason codes,
  - no fallback-success branch remains reachable for simulation-authoritative outcomes.

## Headless Harness Invocation (Mandatory)

- Preferred entrypoint: `scripts/agent_harness.sh <fast|all|bounded|single|smoke|demo|extension|lint>`
  wraps the canonical runners, tees a log, and prints one `AGENT_HARNESS_RESULT={...}` line.
- Always run SceneTree harness scripts via `godot --headless --no-window -s <script>`.
- Canonical harness scripts:
  - `addons/local_agents/tests/run_all_tests.gd`
  - `addons/local_agents/tests/run_runtime_tests_bounded.gd`
  - `addons/local_agents/tests/run_single_test.gd`
- `addons/local_agents/tests/test_*.gd` modules are usually `RefCounted` test definitions, not SceneTree entrypoints; never launch directly with `godot -s test_x.gd`.
- Canonical helper for single-test execution: `scripts/run_single_test.sh test_agent_integration.gd` (defaults to `--timeout=120`).
- Execute `test_*.gd` modules through `addons/local_agents/tests/run_single_test.gd` and pass the test path with `-- --test=res://...` and explicit timeout.
- Correct example: `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
- Broken example: `godot --headless --no-window addons/local_agents/tests/run_all_tests.gd` (`doesn't inherit from SceneTree or MainLoop`)
- Correct example: `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_agent_integration.gd --timeout=120`
- Banned example: `godot --headless --no-window -s addons/local_agents/tests/test_agent_integration.gd`
- **Which scenes need a window, and which do not.** Measured 2026-07-28 on this tree. Re-measure rather
  than assume; getting this backwards taxes every verification in a session.
  - **Example scenes (`addons/local_agents/examples/`) do not need a window.** Run them with
    `scripts/run_demo.sh <name> [frames]`, or `scripts/agent_harness.sh demo --all` for the set — both
    are bare `godot --headless`. The whole set takes **3.8s**: BoxFieldDemo 0.79s, CoreCreatureSmoke
    0.59s, SimWorldPlanetDemo 1.11s, ThinkingCreatureDemo 0.58s, TutorialDemo 0.48s, all exit code 0.
    (Windowed, the same four measurable scenes take 1.0-1.9s, so the window buys nothing here.)
  - **`game/VoxelWorld.tscn` needs a window.** `scripts/run_sim_offscreen.sh --path .
    addons/local_agents/game/VoxelWorld.tscn -- --run-frames=40` takes 7-9s and exits 0. It also *boots*
    headless and exits 0 in 5.3s, but with no compute device the field never runs and `SIM_REPORT` comes
    back empty: `active_cells` 0, `biomass_total` 0, `heat_cells` 0, temperatures flat at the seed value,
    and no `field_*` gauges at all, where the same run windowed reports `active_cells` around 27.5k. That
    is a silent empty pass, not a loud failure, so never read a headless voxel `SIM_REPORT` as evidence
    the simulation ran.
- **`--run-frames` and `--shoot` are a scene contract, not engine flags.** They are implemented by
  `LocalAgentDemoHarness` (`addons/local_agents/runtime/DemoHarness.gd`). A scene without that node
  ignores them and runs until something kills it — which is why runs used to burn the wrapper's whole
  timeout. `scripts/run_demo.sh --list` reports which example scenes carry it (5 of 12 on 2026-07-28)
  and refuses to launch the others. For any scene that lacks it, use the engine's own
  `--quit-after <iterations>` instead.
- **Voxel scene self-harness** (the active `VoxelWorld.tscn`): pass args after `--`. `--run-frames=N`
  prints `SIM_REPORT={...}`, `--shoot=<png> --shoot-frames=N` screenshots, `--overview` frames a wide
  island vista, `--time=<0..1>` sets time of day, and `--auto-meteor`/`--auto-volcano`/`--auto-lightning`
  trigger disasters. Run all of them windowed through `scripts/run_sim_offscreen.sh` for the reason
  above. A NEW `class_name`/`.gdextension` needs one editor scan first
  (`godot --headless --editor --quit-after 400`).
- **`run_sim_offscreen.sh` names its failures instead of waiting them out.** The default
  `LA_RUN_TIMEOUT` is 60s (was 240s), and the script watches the child's output through godot's own
  `--log-file`, leaving stdout untouched. It exits **124** when the scene never printed a completion
  marker (`RUN_TIMEOUT` — usually a scene with no harness) and **125** when the marker printed but the
  process would not exit (`RUN_HUNG_AFTER_REPORT` — the exit path itself is broken), each with an
  explanatory message on stderr. `LA_EXIT_GRACE` (default 10s) sets the post-marker grace period.
- Never pass a harness `.gd` as a main scene path without `-s`.
- When forwarding arguments to harnesses, keep the `--` separator.
- Keep README command templates synchronized with this file.
- For scene/playability validation, do not rely only on editor/manual launch; use harness-driven headless execution to surface parse/runtime failures.
- Historical note: the native projectile-voxel-destruction path (and its `run_destruction_tests.sh` /
  `benchmark_voxel_pipeline.gd` / `test_native_voxel_op_*` harnesses) was removed with the C++ voxel/sim
  sources; the destruction-specific invariants and error-log entries below are retained as native/GPU
  policy and history, not as current commands.

## Plugin UX and Documentation Process

- Keep plugin activation lazy for expensive runtime initialization.
- Long actions must show status and clear failure details in UI.
- Disable conflicting controls while background work is active.
- For required dependencies, show explicit error states rather than silent fallback behavior.
- Update README/testing documentation when behavior or commands change.

## Error Log / Preventative Patterns

### 2026-02-15: `KEY_CONTROL` vs `KEY_CTRL` mismatch

- Failure: used `KEY_CONTROL`; parser/runtime expected `KEY_CTRL`.
- Preventative pattern: use engine-defined key constants from Godot 4 input enums only; verify constant names before commit.
- Quick check: if changing input maps/hotkeys, confirm constants in official Godot 4 docs or existing repo usage.

### 2026-02-15: Variant/Object `.get(key, default)` parser issue

- Failure: calling `.get(key, default)` on values typed as `Variant`/`Object` caused parser error (`Too many arguments for "get()" call`).
- Preventative pattern: narrow type first and use typed local dictionaries before `get`.
- Canonical pattern:

```gdscript
var payload_dict: Dictionary = payload if payload is Dictionary else {}
var value: Variant = payload_dict.get("key", fallback)
```

### 2026-02-15: incorrect harness invocation patterns

- Failure: launched `test_*.gd` directly or passed harness script without `-s`.
- Preventative pattern: run test modules only through SceneTree harness entrypoints and always include `-s`.
- Correct example: `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
- Broken example: `godot --headless --no-window addons/local_agents/tests/run_all_tests.gd` (`doesn't inherit from SceneTree or MainLoop`)
- Use:
  - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
  - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`
  - `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://... --timeout=120`
- Never use:
  - `godot --headless --no-window -s addons/local_agents/tests/test_*.gd`
  - `godot --headless --no-window addons/local_agents/tests/run_all_tests.gd`

### 2026-02-15: false "works" claim without full validation

- Failure: reported working status without required full sweeps and without a real non-headless launch check.
- Preventative pattern: treat status claims as gated by evidence on current tree only; both headless and non-headless evidence are mandatory.
- Required before any "works/ready to play" claim:
  - Full headless harness suite commands pass.
  - Scene-smoke harness (when gameplay/demo/input scripts changed) passes.
  - At least one real non-headless launch using an actual video/display path confirms startup/input viability, or explicitly state environment limitation and do not claim "works/ready".

### 2026-02-17: projectile queue deadline miss created false-pass risk

- Failure: projectile contact entered a deadline-driven queue path where mutation was missed, but wrapper/stage-shim interpretation allowed success-like reporting instead of hard failure.
- Preventative pattern: treat projectile impact -> mutation as C++-authoritative only; GDScript/stage-shim layers cannot own queue/deadline pass/fail decisions or synthesize success outcomes.
- Required safeguards:
  - Queue/deadline state transitions (`queued`, `dispatched`, `deadline_exceeded`) must be authored in native C++ stage output and consumed read-only by GDScript.
  - Success requires explicit native mutation evidence (`mutation_applied == true` or equivalent typed contract field); missing evidence must hard-fail with a typed code.
  - Deadline misses must emit explicit typed failure (`PROJECTILE_MUTATION_DEADLINE_EXCEEDED`) and must never be downgraded to no-op/success in wrappers.
  - Validation must include launched-window FPS fire verification plus headless contract tests asserting no success state is reachable when native mutation evidence is absent.

### 2026-07-08: new `.glsl` compute kernels break at a MERGE boundary (gitignored `.import`)

- Failure: `feature/sphere-spike` merged into `0.3-dev` cleanly and the *worktree* booted with 0 errors, but the *primary* checkout then threw ~23 `ERROR: No loader found for resource: …/kernels3d/*_sphere3d.glsl` + `Cannot call method 'get_spirv' on a null value`. The compute `.glsl` files are committed, but their generated `.glsl.import` resources are **gitignored** — so `load(<kernel>.glsl)` returns null (no `RDShaderFile`) in any checkout/worktree that has not run an editor import scan since the kernels arrived.
- Root cause: the "a NEW `.glsl`/`class_name` only registers after an editor scan" rule is not just a first-author gotcha — it recurs at EVERY boundary where the `.glsl` lands without its `.import`: a fresh clone, a **new worktree checkout**, and a **merge into another checkout**.
- Preventative pattern:
  - After merging (or checking out) a branch that ADDS or CHANGES `kernels3d/*.glsl`, run `godot --headless --editor --quit-after 600 --path .` ONCE in that checkout before any run/validation, then re-verify boot.
  - When a GPU kernel load returns null / `get_spirv on null`, suspect a missing `.import` (unscanned checkout) BEFORE suspecting the shader — check for the `.glsl.import` file first.
  - A green boot in the authoring worktree does NOT certify other checkouts; the merge target must be booted + scanned independently before claiming the merge is clean (done here — primary re-verified 0 errors post-scan).

### 2026-07-09: FIXED — `rc=134` SIGABRT at process exit under Metal/MoltenVK (clean exit via `LAAppExit` + `LAProcess.exit_now`)

- Symptom (was): a windowed Metal run (`scripts/run_sim_offscreen.sh … VoxelWorld.tscn -- --run-frames=N`) printed `SIM_REPORT={…}` normally, then aborted on the way out with `libc++abi: terminating due to uncaught exception … recursive_mutex lock failed: Invalid argument` and exited `rc=134`.
- Root cause: the ordinary `SceneTree.quit()` path on macOS runs through `-[NSApplication terminate:]`, which posts `NSApplicationWillTerminate` → a MoltenVK (`mvk…`) termination-observer locks an already-destroyed `std::recursive_mutex` and aborts. There are **no GDScript frames** in the stack — it fires during `NSApplication` teardown, AFTER `SceneTree`/`_exit_tree`/`dispose()` have returned. It is downstream of, and independent of, our resource management: freeing every RID + the local `RenderingDevice` (0 leaked RIDs) does NOT prevent it (verified `feature/gpu-teardown`).
- The fix (`feature/clean-quit`): we take ownership of the exit. All quit call sites (VoxelWorld `--shoot`, VoxelHarness `--run-frames`, VoxelPauseMenu, MainMenu, MenuShooter) route through the `AppExit` autoload (`scenes/AppExit.gd`, class `LAAppExit`) via `LAAppExit.request(node, code)`. On a real quit it lets saves/config (already written synchronously) and `SIM_REPORT` settle for one idle frame, then calls the native `LAProcess.exit_now(code)` (`gdextensions/localagents`, `std::_Exit`): flush stdio → terminate immediately, running NO C++ static destructors and firing NO AppKit termination notification, so MoltenVK's observer never runs. Windowed `--run-frames=150` now exits **rc 0** with SIM_REPORT intact and no `recursive_mutex`/abort. The kernel reclaims all memory/GPU on `_Exit`, so no data is lost and no RID leaks persist. `LAAppExit` also sets `auto_accept_quit(false)` and handles `NOTIFICATION_WM_CLOSE_REQUEST` so the window-`X` button takes the same clean path.
- Still-correct discipline (kept): free every RID + the local `RenderingDevice` while the tree is up (`MaterialField3D._exit_tree` → `_gpu.dispose()`, each sphere pass a `dispose(rd)`). That remains the right hygiene for the editor/headless teardown and any RID-ordering crash; the hard exit is layered on top for the windowed Metal case only.
- Gating: a windowed Metal run should now exit `rc 0` with `SIM_REPORT` (sane aggregates) as the last meaningful line. A returning `rc=134` with the `NSApplication terminate:` → `recursive_mutex` MoltenVK frame means the quit path bypassed `LAAppExit`/`LAProcess` (check the extension loaded + the autoload is registered); any `rc=134` with a GDScript frame in the stack IS a real regression to investigate.
- Still holding on 2026-07-28: instrumenting the chain end to end confirms `AppExit.quit` resumes past its
  `await`, `ClassDB.class_exists("LAProcess")` is true, and `exit_now` fires — windowed and headless alike.

### 2026-07-28: a "windowed runs never exit" diagnosis that was wrong, and the real cause

- Symptom (real): every `scripts/run_sim_offscreen.sh` run cost 2-4 minutes and ended with the child killed,
  which taxed every verification in the session.
- Diagnosis that was recorded and acted on (wrong): "the scene prints its report, calls its quit path, and
  the process does not exit", with `LAAppExit.quit()` being a coroutine (it contains `await
  tree.process_frame`) invoked through `Object.call()` as the prime suspect.
- What measurement showed instead. Every scene that carries a `LocalAgentDemoHarness` exits cleanly
  windowed: BoxFieldDemo 1.7s, ThinkingCreatureDemo 1.1s, SimWorldPlanetDemo 1.9s, CoreCreatureSmoke 1.0s,
  VoxelWorld 8.7s — all exit code 0. Temporary prints in `DemoHarness._quit` and `LAAppExit.quit` showed, in
  windowed *and* headless runs: `_quit` reached; `/root/AppExit` present with a `quit` method;
  `AppExit.quit` entered; **`AppExit.quit` resumed past its `await`**, so `.call()` on a coroutine does run
  to completion; `ClassDB.class_exists("LAProcess")` true; and nothing printed after, because `exit_now`
  fired. All four candidate causes were false.
- Real cause: `--run-frames` is a scene contract, not an engine flag. Seven of the twelve example scenes
  have no `LocalAgentDemoHarness`, so they ignore the flag and run forever until the watchdog kills them —
  at a 240s ceiling. The wrapper logged only "RUN_TIMEOUT: killed godot", which is exactly what a genuine
  hang looks like, so the log could not tell the two apart and the wrong story was the plausible one.
- Preventative pattern:
  - A wrapper that kills on timeout must say **which** failure it saw. `run_sim_offscreen.sh` now watches
    the child through godot's `--log-file` (stdout untouched) and separates "never reached a report"
    (exit 124) from "reported, then would not exit" (exit 125).
  - Before adopting a stated root cause — including one from a reviewer, a handoff, or a previous session —
    run the experiment that would falsify it. Here that was one instrumented run.
  - Do not use the windowed wrapper to discover whether a scene self-terminates. Ask
    `scripts/run_demo.sh --list` first.
- Tail: the first version of that marker watchdog matched a bare `^[A-Z][A-Z0-9_]*=\{`, and **killed a
  healthy 40-frame VoxelWorld run at 12.7s, before its `SIM_REPORT`**. VoxelWorld prints a dozen startup
  status lines of exactly that shape — `PROGRESSION={mode:sandbox…}`, `GAME_HUD={ready:true}`,
  `MUSIC_SEED={value:…}` — so the grace clock armed on line 4. The discriminator is the quote: a harness
  report body is always JSON (`={"…`), while Godot's `Dictionary` printing leaves keys unquoted. When a
  watchdog can kill a good run, its trigger must be validated against a real log of the run it is meant to
  protect, not just against the string it is meant to catch.

### 2026-07-28: a background `sleep` watchdog stalls any caller reading the script through a pipe

- Failure: `scripts/agent_harness.sh demo --all` took **64s** to run five demos that finish in **3.8s**
  when run directly.
- Cause: the per-demo guard was `( sleep 60; kill -KILL $child ) &`. Killing `$guard` reaps the subshell but
  not the `sleep` it is blocked in, and the orphaned `sleep` inherits the script's stdout — so it holds the
  write end of the pipe into `tee` open for the full 60s, and the harness cannot finish. The same shape cost
  a piped `run_sim_offscreen.sh` caller 1.4s through its `( sleep 3.5; osascript … ) &` focus helpers.
- Preventative pattern: a background watchdog must poll in short slices and exit as soon as the child is
  gone, and/or have its stdout and stderr redirected to `/dev/null` so it cannot hold a caller's pipe. Both
  are applied now (`run_demo.sh` guard loop, `run_sim_offscreen.sh` focus subshells).
- Quick check: if a script is fast when redirected to a file and slow through a pipe, look for a background
  child still holding fd 1.

### 2026-07-29: an `@export` that nothing reads is indistinguishable from one that works

- Failure: `LocalAgent.system_prompt` was exported, documented with a `##` comment, assigned in scenes, and
  read by nothing. The native runtime never looks at `options["system_prompt"]`, so the property round-tripped
  through the inspector and the `.tscn` and then fell on the floor. Separately, `LocalAgentModelProfile` was
  entirely inert: `_apply_model_profile()` wrote its values into `inference_options`, and `configure()`
  replaces that dictionary wholesale, so the profile was overwritten before it ever reached the model.
- Why it survived review: every static signal was green. The property parsed, the editor showed it, the
  scene saved it, `_ready()` read it, and it was passed to a `call()` that returned success. Nothing short of
  observing the model's behaviour distinguishes "wired" from "assigned and discarded".
- Detection that worked: run the model and ask a question whose answer the export would change. Set the
  system prompt to "always answer BANANA", ask for the capital of France, and read the reply. It said Paris.
- Preventative pattern: for every export you add, name the one run whose output differs if the property were
  deleted, and do that run before calling it done. If you cannot name such a run, the export is decoration.
  Fixed by injecting the prompt as a system message at `history[0]` and mirroring it into the native node,
  and by splitting load-time knobs into `load_options` so `configure()` cannot clobber them.
- Quick check: `grep` the property name across the repo. One hit at its declaration and one in `_ready()`
  with nothing in between is the shape of a dead export.

### 2026-07-29: three GDScript parse rules the editor scan does not report

- Failure: three separate parse-level mistakes, none of which `godot --headless --editor` surfaced.
  - `@icon("res://…")` placed *after* `extends` fails with `Annotation "@icon" must be at the top of the
    class`. Six files declared `extends` first and broke. Annotations must precede both `extends` and
    `class_name`; the order of those two relative to each other does not matter.
  - `const SPECS: Array = [ PackedStringArray([...]) ]` fails with "Not a constant expression". A `const`
    cannot hold a constructor call, so a default that needs a typed array must be a plain `Array` converted
    on read (`runtime/Settings.gd:41` carries the note).
  - `@export_enum("", "in_process", "llama_server")` rejects the empty option string. Give the empty case a
    real label and map it in code.
- Root cause of the miss: an editor scan reports *class registration* problems, not every script that fails
  to load. A scan can print `editor_scan: OK (0 errors)` while a script in the tree does not parse.
- Preventative pattern: a scan is necessary and not sufficient. Prove a changed script actually loads by
  running something that instantiates it (`scripts/run_demo.sh <Name>`, `scripts/check_library_only.sh`),
  and treat `check_library_only.sh` as the parse gate it is: it caught the `const` case when the scan did not.

### 2026-07-29: a `@tool` script that writes a serialized property edits the user's scene file

- Failure: two independently written nodes ran setter logic under `Engine.is_editor_hint()` that assigned to
  an `@export`ed property. In the editor that marks the scene dirty and, on the next save, writes a value the
  user never typed into their `.tscn`. Both authors reported the node as working, because at runtime it is.
- Preventative pattern: `_get_configuration_warnings()` requires `@tool`, and `@tool` means every lifecycle
  callback also runs in the editor. Guard `_ready`/`_process`/`_physics_process`/`_enter_tree` with
  `if Engine.is_editor_hint(): return`, and never assign to a serialized property on an editor path.
  `scripts/check_tool_safety.sh` gates this now and runs from `scripts/agent_harness.sh lint`.
- Scope rule that follows: apply `@tool` only to small scripts you have read end to end. `Creature.gd` is
  1300+ lines across 26 modules and carries `@tool` solely for its configuration warning, with every
  lifecycle callback guarded, which is the maximum that is safe to do to a file that size.

### 2026-07-29: concurrent editor scans segfault Godot

- Failure: a string of `EXC_BAD_ACCESS` crash reports, faulting inside
  `libvoxel.macos.editor.universal`. The user saw macOS crash dialogs, not a test failure.
- Cause: every sub-agent contract in the session told the agent to run `godot --headless --editor
  --quit-after 400` after its edits. With a dozen agents in flight that is a dozen processes writing the same
  `.godot/` import cache and resource UID database at once. The crash is a symptom of the concurrency, not of
  the voxel module.
- Preventative pattern: an editor scan mutates shared project state, so it must be serialized.
  `scripts/editor_scan.sh` takes an `mkdir`-based lock per project, reclaims a lock left by a dead PID, and
  queues callers. Every contract now says to use it, and never to call `godot --headless --editor` directly.
- Quick check: if Godot crashes inside a GDExtension during a scan and the same scan passes when run alone,
  count how many godot processes are alive (`pgrep -fl godot`) before blaming the extension.

### 2026-07-29: a threshold's doc comment and its configuration warning were both backwards

- Failure: `LocalAgent.tick_interval` defaulted to `0.0`, its `##` comment described `0` as "tick every
  frame", and the configuration warning fired on the wrong side of the comparison. The native
  `AgentNode::_process` returns early when `tick_interval <= 0`, so `0` means *never ticks*. Enabling
  `tick_enabled` on a default agent produced nothing, with the inspector affirming the setup was correct.
- Preventative pattern: when you write a doc comment or a configuration warning about a threshold, open the
  branch that implements it and read the comparison. Cite it: `AgentWarnings.gd:45` now names
  `AgentNode.cpp:56` in a comment, so the next person can re-check the claim in one jump instead of
  re-deriving it. Default is `1.0` now.

### 2026-07-29: a smoke target pointing at a deleted scene passes by loading nothing

- Failure: `scripts/agent_harness.sh smoke` pointed at `scenes/simulation/WorldSimulation.tscn`, deleted with
  the old stack. Godot cannot load a missing main scene, prints a resource error, and exits 0. The harness
  classified that as `pass` for an unknown number of runs.
- Preventative pattern: a smoke test must assert it loaded *something*, not merely that the process exited 0.
  The smoke path now greps the log for `SCRIPT ERROR|Parse Error|dependency error|Failed loading resource`
  and downgrades a 0 exit to `fail` on a hit. Any check whose pass condition is "nothing bad printed" needs a
  positive assertion alongside it.
- Quick check: after moving or deleting a scene, `grep -rn "<old scene name>" scripts/` before anything else.

### 2026-07-29: three gates were written, tested, and wired into nothing

- Failure: `check_library_only.sh`, `check_tool_safety.sh` and `check_demo_catalog.sh` were each authored by
  a different agent, each verified by its author against a deliberately broken input, and each reported as
  delivered. None of them was called by `scripts/agent_harness.sh lint`, or by CI, or by anything else. A
  gate that runs nowhere is indistinguishable from no gate, and all three had been "delivered" for days.
- Preventative pattern: a new check is not done when it works. It is done when (1) it is invoked from
  `scripts/agent_harness.sh lint` and you have traced that call, and (2) you have watched it fail on purpose
  and print a useful message. Any contract that asks for a gate must make both of those the acceptance
  criteria, because writing the check *feels* like finishing and is roughly half the work.
- Quick check: `grep -n "check_" scripts/agent_harness.sh` and compare against `ls scripts/check_*.sh`.

### 2026-07-29: a `PackedScene` export in a catalogue resource loads every scene to paint a menu

- Failure: `LocalAgentDemoEntry.scene` was typed `PackedScene`, so it was a real dependency. Loading the
  twelve catalogue entries to draw the demo launcher's list also loaded twelve demo scenes and their entire
  script graphs. Measured at 563 ms of blocking work in `_ready()` on the addon's front door, against 92 us
  for the `@export_file("*.tscn")` path check that replaced it.
- The reasoning that produced the bug, recorded because it was plausible: a `PackedScene` was chosen so a
  renamed demo would "fail loudly at edit time". Measurement showed the opposite. A missing target makes the
  whole `.tres` fail to load, and the launcher logged a warning and silently dropped the row, which is the
  quietest possible failure.
- Preventative pattern: a resource that exists to be *listed* holds paths, not references. Godot loads a
  `Resource`'s sub-resources eagerly, so any typed reference in a catalogue record is paid for at list time.
  Enforce the corresponding drift check at build time instead (`scripts/check_demo_catalog.sh`).
- Quick check: if a menu or list is slow to appear, look at what its records reference before profiling the
  drawing code.

### 2026-07-29: `set -e` plus a legitimately empty `grep` kills the script before its error path

- Failure: `scripts/run_demo.sh` could not report a failing demo. Its error path began with a `grep` for a
  completion marker that, on a failed run, correctly matches nothing. `grep` exits 1, `set -e` terminates the
  script, and the code that would have printed the failure never ran. The same shape truncated the `--all`
  loop at the first failure instead of running the remaining demos.
- Preventative pattern: under `set -e`, any command whose empty result is a normal outcome needs `|| true`,
  and any command whose non-zero exit you intend to inspect needs the capture idiom:

```bash
marker="$(grep -aE '^LA_RUN_COMPLETE=' "$log" | tail -n 1 || true)"

rc=0
run_one "$name" "$frames" || rc=$?
```

- Quick check: if a script's failure branch has never printed, check whether `set -e` is reaching it.

### 2026-07-29: a staged tool binary carried an absolute rpath into a worktree that no longer exists

- Failure: the `llama-server` and `llama-cli` binaries staged into
  `addons/local_agents/gdextensions/localagents/bin/` had an `LC_RPATH` pointing at an absolute path inside a
  build worktree (`…/local-agents-followups/…`). That directory had since been removed, so the shipped
  binaries could not resolve their dylibs on the build machine, let alone anyone else's.
- Preventative pattern: normalize link paths at the point where a binary is copied into the shipped tree, not
  as a later step someone can skip. `build_extension.sh` now calls `normalize_tool_linkage()` from inside
  `stage_tools()`, rewriting absolute rpaths to `@loader_path`.
- Quick check: `otool -l <binary> | grep -A2 LC_RPATH` on anything staged for distribution. Any absolute path
  under a developer's home directory is a bug.

### 2026-07-29: acting on a reviewer's claim without running the experiment

- Failure: an adversarial review agent reported that Godot cannot export a typed `Dictionary[String, int]`.
  Two working typed exports were reverted to untyped `Dictionary` on that claim alone. The claim was false:
  typed dictionary exports work, and only `set()` with an untyped literal fails against one. Two further
  claims from the same review were also wrong, and a separate diagnosis about run slowness ("focus-return
  retries") was asserted without measurement and was likewise wrong.
- Root cause: an adversarial verifier is built to be believed, so its output arrives with the authority of a
  check having been run. It is still a model's assertion, and reviewing is exactly as prone to a confident
  wrong answer as implementing is.
- Preventative pattern: a review finding is a hypothesis, not a result. Before acting on one, run the
  experiment that would falsify it, and prefer an experiment that takes seconds. This applies to findings
  from a reviewer, a handoff document, a previous session, and your own earlier reasoning.
- Quick check: before reverting working code on a claim about engine behaviour, write the four-line scene
  that demonstrates the behaviour and run it.
