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
- CPU/GDScript success fallbacks for simulation outcomes are forbidden; missing requirements must fail explicitly.
- GDS adapter authority rule: gameplay-runtime GDS layers are adapter-only and must not own mutation outcome logic or decide mutation success/failure.
- Projectile impact destruction rule: enforce a direct authoritative flow only as `impact contact -> C++ mutation -> apply result`.
- Ban multi-hop GDS contract layers on projectile destruction paths: no flatten/interpret/rewrap chains in GDS for mutation authority.
- When a preventable error appears, add a dated entry to `Error Log / Preventative Patterns` in this file.

## Godot Design and Structure Process

- Keep simulation-authoritative gameplay logic (physics/destruction/voxel mutation/state evolution) in native code with GPU execution contracts.
- Keep runtime execution paths short and direct; avoid multi-hop controller/stage chains unless required by a concrete engine or contract boundary.
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
- Any "works"/"ready" claim requires both evidence classes on the current tree:
  - headless harness suite pass
  - non-headless run through an actual video/display path
- If non-headless launch is not possible in the environment, state that limitation explicitly and do not claim "works/ready".
- If a user reports an immediate parse/runtime error after a "works" claim, treat it as process failure: stop, acknowledge failed validation, rerun full validation, and do not re-claim status until all required checks pass.
- For native/GPU-authoritative simulation changes, validation evidence must also show:
  - primary-path execution uses native/GPU backend metadata (no CPU-success backend on authoritative simulation path),
  - missing native/GPU requirements fail with explicit typed reason codes,
  - no fallback-success branch remains reachable for simulation-authoritative outcomes.

## Headless Harness Invocation (Mandatory)

- Always run SceneTree harness scripts via `godot --headless --no-window -s <script>`.
- Canonical harness scripts:
  - `addons/local_agents/tests/run_all_tests.gd`
  - `addons/local_agents/tests/run_runtime_tests_bounded.gd`
  - `addons/local_agents/tests/run_single_test.gd`
  - `addons/local_agents/tests/benchmark_voxel_pipeline.gd`
- `addons/local_agents/tests/test_*.gd` modules are usually `RefCounted` test definitions, not SceneTree entrypoints; never launch directly with `godot -s test_x.gd`.
- Canonical helper for single-test execution: `scripts/run_single_test.sh test_native_voxel_op_contracts.gd` (defaults to `--timeout=120`).
- Execute `test_*.gd` modules through `addons/local_agents/tests/run_single_test.gd` and pass the test path with `-- --test=res://...` and explicit timeout.
- Correct example: `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
- Broken example: `godot --headless --no-window addons/local_agents/tests/run_all_tests.gd` (`doesn't inherit from SceneTree or MainLoop`)
- Correct example: `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_voxel_op_contracts.gd --timeout=120`
- Banned example: `godot --headless --no-window -s addons/local_agents/tests/test_native_voxel_op_contracts.gd`
- Never pass a harness `.gd` as a main scene path without `-s`.
- When forwarding arguments to harnesses, keep the `--` separator.
- Keep README command templates synchronized with this file.
- For scene/playability validation, do not rely only on editor/manual launch; use harness-driven headless execution to surface parse/runtime failures.

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
