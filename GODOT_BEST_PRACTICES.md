# GODOT_BEST_PRACTICES

Purpose: prevent repeated Godot parser/runtime/testing mistakes with short, enforceable rules.

## Core Rules

- This file is mandatory startup reading and required process for every session.
- Use Godot 4 constants exactly as defined in docs/API. Do not guess names.
- Prefer explicit typing for locals that hold dynamic data (`Dictionary`, `Array`, `Object` checks).
- Keep command invocation patterns canonical and copied from repo harness docs.
- Always run SceneTree harness entrypoints with `-s`; otherwise Godot can fail with `doesn't inherit from SceneTree or MainLoop`.
- Do not claim "works" unless required validation steps have run on the current tree.
- When a preventable error appears, add a dated entry to `Error Log / Preventative Patterns` in this file.

## Godot Design and Structure Process

- Keep gameplay logic in GDScript unless native is required for performance or platform APIs.
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
