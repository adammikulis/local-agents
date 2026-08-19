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
- There is no "transitional CPU/GDS" tracking list, and there must not be one. `CLAUDE.md`'s no-transitional-shims rule is the policy: either it is built native/GPU-first, or it is ordinary code improved directly, or it is a permanent CPU fallback that is first-class by design. A debt list is how a stopgap becomes furniture.

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
- **Which scenes need a window, and which do not.** Measure rather than assume.
  - **Example scenes (`addons/local_agents/examples/`) do not need a window.** Run them with
    `scripts/run_demo.sh <name> [frames]`, or `scripts/agent_harness.sh demo --all` for the set — both
    are bare `godot --headless`. The whole set takes **3.8s**: BoxFieldDemo 0.79s, CoreCreatureSmoke
    0.59s, SimWorldPlanetDemo 1.11s, ThinkingCreatureDemo 0.58s, TutorialDemo 0.48s, all exit code 0.
    (Windowed, the same four measurable scenes take 1.0-1.9s, so the window buys nothing here.)
  - **`game/VoxelWorld.tscn` needs a window.** `scripts/run_sim_offscreen.sh --path .
    addons/local_agents/game/VoxelWorld.tscn -- --run-frames=40` takes 7-9s and exits 0. It also *boots*
    headless and exits 0 in 5.3s, but with no compute device the field never runs and `SIM_REPORT` comes
    back empty: `biomass_total` 0, `heat_cells` 0, `sediment_total` 0.00, temperatures flat at the seed
    value, and no `field_*` gauges at all, where the same run windowed reports `sediment_total` ~980. That
    is a silent empty pass, not a loud failure, so never read a headless voxel `SIM_REPORT` as evidence
    the simulation ran.
- **`--run-frames` and `--shoot` are a scene contract, not engine flags.** They are implemented by
  `LocalAgentDemoHarness` (`addons/local_agents/runtime/DemoHarness.gd`). A scene without that node
  ignores them and runs until something kills it. `scripts/run_demo.sh --list` reports which example
  scenes carry it and refuses to launch the others. For any scene that lacks it, use the engine's own
  `--quit-after <iterations>` instead.
- **Voxel scene self-harness** (the active `VoxelWorld.tscn`): pass args after `--`. `--run-frames=N`
  prints `SIM_REPORT={...}`, `--shoot=<png> --shoot-frames=N` screenshots, `--overview` frames a wide
  island vista, `--time=<0..1>` sets time of day, and `--auto-meteor`/`--auto-barrage` aim an impact
  (the only cause the player has). Run all of them windowed through `scripts/run_sim_offscreen.sh` for the reason
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

## Live engine constraints — do not re-derive

- **`buffer_get_data_async` returns STALE data** for compute-written buffers on Godot 4.4+ (engine bug
  [#105256](https://github.com/godotengine/godot/issues/105256)). Forking was considered and rejected.
- **Reading the device from the REPORT path CORRUPTS THE SIM.** With a `step()` submit in flight,
  `buffer_get_data` flushes outside the driver's one-submit-per-sync discipline: `h2o_total` 5062 → 9803,
  `temp_mean` 39.8 → 44.6. Defer the sample into `_drain_pending()`, after `_rd.sync()`.
- **`request_channel()` is NOT read-only.** It decides which channels get mirrored, and the field's *write*
  paths read those mirrors. This is how impact winter was found to be alive only because a diagnostic
  happened to request `dust`.
- **CPU writes to `_f._o2` / `_f._co2` / `_f._detritus` are silently discarded** —
  `MaterialFieldSphereStep3D.gd:282-306` overwrites them wholesale from the GPU readback every drain. Park
  transactions on the device injection queue instead. Every breath an animal took once debited nothing.
- **No GPU-side execution timer in this build.** `gpu_dispatch_ms` reads 0.00 on Metal.
- **Where the field's time goes: RE-MEASURE IT, the old split is void.** It read "readback 77%, core pin 13%,
  dispatch 4%", and the core pin no longer exists — `MaterialSphereGPU3D.gd:327-330` records that the
  geothermal core stopped writing `_temp` on the CPU every step and became a flux boundary inside
  `heat_sphere3d.glsl`. So 13% is attributed to work that does not run, and the rest cannot be trusted to
  add up. Readback is still the thing to optimise. A
  camera-relevance LOD was deleted for optimising the 4% while costing 4.5 °C of climate error.
- **The neighbour table and the tangent frame are SEPARATE tables** — the discrete hairy-ball theorem, proved
  in `GODOT_BEST_PRACTICES.md`. Anything reading a vector across a seam uses the per-link rotation.
- **A wrapper run reads the tree AT LAUNCH** — editing a worktree mid-batch silently mixes code versions.
- **`FOO="${FOO:-}"` arms anything gating on `OS.has_environment`** — true for an empty value. Gate on
  `get_environment(name) != ""` instead.

---


## The CLI godot is an ACCESSORY APP, and that is deliberate

`/opt/homebrew/bin/godot` points at `/Applications/GodotQuiet.app`, a copy of the editor bundle whose
`Info.plist` carries `LSUIElement`. An accessory app never activates, never takes focus and never appears
in the Dock, whatever script it runs — which is the only way to cover every path that opens a window: the
sim, the importer, the editor scan, and the bare `SceneTree` probes four gates launch for themselves.
Setting a window flag inside our own harness covered the sim alone and left the gate probes stealing focus.

`/Applications/Godot.app` is untouched, so launching the editor by hand behaves normally.

`brew upgrade godot` restores the original symlink. Repoint it:
`ln -sf /Applications/GodotQuiet.app/Contents/MacOS/Godot /opt/homebrew/bin/godot`

Rebuild the bundle after a Godot upgrade: copy the app, add the `LSUIElement` key, then
`codesign --force --deep --sign -` it, because editing `Info.plist` invalidates the signature.
