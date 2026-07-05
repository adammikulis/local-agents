# CLAUDE.md

Operator quick-reference for Claude Code sessions in this repo (Godot 4.7, `godot` on PATH).
It summarizes the run/observe loop only. It does not define or override process rules.

## Authority note (read first)

- `AGENTS.md` and `GODOT_BEST_PRACTICES.md` are the canonical, enforceable process docs.
  Read them at session start before planning or implementing.
- This file is a convenience summary of the run/observe tooling. Where anything here appears
  to conflict with `AGENTS.md` or `GODOT_BEST_PRACTICES.md`, those documents win.

## Running tests & the sim

Preferred entrypoint: `scripts/agent_harness.sh <command>`. It wraps the canonical harnesses,
tees a full log, and prints one machine-parseable result line.

- `fast` — fast test sweep (`run_all_tests.gd --fast`).
- `all [args]` — full suite (`run_all_tests.gd --timeout=120`).
- `bounded [--suite=destruction|runtime|fast] [args]` — bounded runtime suite (`run_runtime_tests_bounded.gd`).
- `destruction` — `scripts/run_destruction_tests.sh`.
- `fps-fire [args]` — `scripts/run_fps_fire_destroy.sh` (e.g. `--timeout=60`).
- `single <test_*.gd> [args]` — one test via `scripts/run_single_test.sh`.
- `smoke` — boot the main scene headless briefly; fails on script/parse errors.
- `extension` — validate the GDExtension (`scripts/check_extension.gd`).
- `introspect [--ticks=N]` — run `introspection_probe.gd` and dump live sim state.
- `lint` — run the three CI lint checks in sequence.

Underlying canonical wrappers (call directly only when needed):
`scripts/run_single_test.sh`, `scripts/run_destruction_tests.sh`, `scripts/run_fps_fire_destroy.sh`,
and the SceneTree runners `addons/local_agents/tests/run_all_tests.gd` and
`addons/local_agents/tests/run_runtime_tests_bounded.gd`.

## Machine-parseable output markers (grep these)

- `AGENT_HARNESS_RESULT={json}` — one per harness run. Fields: `command`, `status`
  (`pass`|`fail`|`timeout`), `exit_code`, `duration_s`, `log`, `passed`, `failed`
  (plus `introspect_ok` for `introspect`).
- `AGENT_TEST_RESULT={json}` — printed by the SceneTree runners (`run_all_tests.gd`,
  `run_runtime_tests_bounded.gd`, `run_single_test.gd`) via `agent_result_reporter.gd`.
  Fields: `suite`, `status`, `passed`, `failed`, `duration_s`, `failures[]`.
- `AGENT_INTROSPECT={json}` — printed by `introspection_probe.gd`. Fields include `ok`,
  `debug_snapshot`, `voxel_orchestration_metrics`/`voxel_orchestration_state`,
  `physics_contacts`, `field_handles`, `runtime_health`, and `profiler`.
- Legacy (fps-fire path): `FPS_FIRE_DESTROY_RUNTIME={json}` and the plain line
  `fps_fire_destroy harness passed.`

## Live introspection & profiler

To snapshot a running sim without a full test suite:

```
scripts/agent_harness.sh introspect --ticks=30
# or directly:
godot --headless --no-window -s addons/local_agents/tests/introspection_probe.gd -- --ticks=30
```

The probe boots the sim, steps N ticks, and emits `AGENT_INTROSPECT={json}`. The `profiler`
section is surfaced there (native `LocalAgentsSimProfiler` `sim_profiler` + Godot `Performance`
monitors). Native introspection is gated by env `LOCAL_AGENTS_ENABLE_NATIVE_SIM_CORE=1`.

Native entry points (via `Engine.get_singleton(...)`):

- `LocalAgentsSimulationCore`: `get_debug_snapshot()`, `get_voxel_orchestration_metrics()`,
  `get_voxel_orchestration_state()`, `get_physics_contact_snapshot()`, `list_field_handles_snapshot()`.
- `AgentRuntime`: `get_runtime_health()`.
- `WorldSimulation.native_voxel_dispatch_runtime()`.

## Hard constraints (see AGENTS.md / GODOT_BEST_PRACTICES.md for the full, enforceable text)

- Never invoke `test_*.gd` directly — always go through `run_single_test.sh` (or the harness
  `single` command). Enforced by `scripts/check_no_direct_refcounted_invocation.sh`.
- 1000-line soft file limit (advisory): `MAX_FILE_LINES=1000 scripts/check_max_file_length.sh`.
  Warn-only — it reports files over the soft limit but does not fail CI. Treat 1000 lines as a
  smell to split before, not a hard gate.
- Native/GPU-only mandate: fail fast with typed errors (`GPU_REQUIRED`, `NATIVE_REQUIRED`,
  `CPU_FALLBACK_FORBIDDEN`). No fallback paths, no fallback-success, no soft passes.
- Validation evidence: player-facing pass claims need both a launched-window run and headless
  sweeps, run in either order (ordering is not mandated).
- Policy/plan markers (`scripts/check_policy_plan_markers.sh`) are advisory-only — they surface
  drift in the kept invariants but never gate.

## Required validation baseline (before any "works"/"ready"/"fixed" claim)

```
godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120
godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120
```

Plus a real non-headless (launched-window) run for any player-facing behavior. Automated/headless
tests are necessary but not sufficient for player-facing pass claims.
