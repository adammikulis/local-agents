# AGENTS.md

This file defines implementation rules for this repository. Higher sections are intentionally higher priority.

## Required Startup Reading (Mandatory)

- Read `GODOT_BEST_PRACTICES.md` at session startup before planning or implementation.
- Treat `GODOT_BEST_PRACTICES.md` as required process, not optional guidance.
- Godot operational/testing/validation and invocation rules are canonical in `GODOT_BEST_PRACTICES.md` and are fully enforceable.
- Both evidence classes are required for player-facing pass claims — a real launched-window run and headless harness sweeps — but their order is not mandated. A non-headless launch first is still a good habit for surfacing parser/runtime scene errors early.

## Execution Model

- Prefer planning before large changes: understand current state and risks before editing, and for big or ambiguous work start with a short investigation pass.
- The main thread MAY perform implementation edits directly when that makes sense by its own judgment — small, well-scoped tooling or documentation changes, or targeted fixes the user asked for directly. There is no hard rule that all implementation must be delegated.
- Prefer sub-agents for substantial or parallel work — parallelizable scope, contract-heavy or native-path changes, and larger refactors — and spawn worker/validation sub-agent lanes whenever they add value. Sub-agents are a tool to reach for, not a blanket mandate.
- Rule of thumb: keep small scoped edits on the main thread; split substantial, parallel, or high-risk (contract/native/GPU) work into sub-agent lanes with explicit acceptance criteria.
- Run/observe tooling: use `scripts/agent_harness.sh` (see `CLAUDE.md`) for tests, smoke, and live introspection.
- For substantial or breaking work, keep `ARCHITECTURE_PLAN.md` current: record the intended change, and note breaking API/schema changes there before merge.
- Close stale/finished sub-agents when they are no longer active to conserve slots.

### Validation Defaults

- "Does it work" checks require both a non-headless launch and headless harness suites; run them in whichever order is convenient (order is not mandated).
- Manual runtime proof is required for player-facing behavior claims: if a change affects in-game controls/interaction (for example FPS mode + left-click destruction), verification must include an actual launched Godot window run where the behavior is exercised directly.
- Do not mark player-facing work as `passing`/`ready`/`fixed` without that launched-window check. Automated/headless tests are necessary but not sufficient for player-facing pass claims.
- For changed native or simulation contract areas, give any validation pass explicit acceptance criteria and test commands.

## Current Repo Policy

- There are no downstream consumers to preserve in this repo right now.
- Prioritize rapid feature improvement and stronger simulation behavior over compatibility.
- Simplicity mandate (non-negotiable): implement the simplest behavior that works correctly for the target path.
- Anti-overengineering mandate (non-negotiable): do not introduce long, multi-stage, or speculative pipelines when a shorter direct path can satisfy the requirement.
- C++-first runtime mandate (non-negotiable): runtime gameplay/simulation/destruction behavior must be implemented in C++ by default.
- GPU-first simulation/render mandate (non-negotiable): move practical runtime compute/render work from CPU paths to GPU-backed execution.
- Shader-first execution mandate (non-negotiable): when behavior can be implemented in shader stages (`.gdshader`/native shader pipelines), shader paths are the default authority.
- Reduced cross-boundary interactions mandate (non-negotiable): minimize C++<->GDS and CPU<->GPU interaction hops on authoritative runtime paths.
- GPU-native handshake requirement (non-negotiable): startup/runtime must complete native-extension + GPU-capability + shader-pipeline handshake before enabling authoritative simulation/destruction flow.
- GDScript exception rule (non-negotiable): use GDScript for runtime behavior only when C++ is not practical for that specific boundary, and keep that GDScript limited to thin orchestration/adapters.
- Transitional-only exception mandate (non-negotiable): any remaining non-native or non-GPU runtime path is temporary shim surface only, never target architecture.
- GDS orchestration boundary (non-negotiable): gameplay-runtime GDS adapters are forwarding-only and must not own mutation outcome logic, mutation success/failure decisions, or mutation result interpretation.
- Projectile impact path mandate (non-negotiable): destruction flow is direct and authoritative only as `impact contact -> C++ mutation -> apply result`.
- Multi-hop GDS contract ban (non-negotiable): do not add or preserve multi-hop GDS flatten/interpret/rewrap layers on the projectile impact destruction path.
- Default to voxel-native simulation, collision, and destruction paths.
- Zero-fallback mandate (non-negotiable): do not add, preserve, or reintroduce fallback behavior for simulation, destruction, collision, or dispatch paths.
- If the native/GPU path cannot execute, fail fast with explicit typed errors (`GPU_REQUIRED`/`NATIVE_REQUIRED`) instead of routing to alternate logic.
- Tests and runtime flows must assert native-path execution for rigid-body voxel damage; skip/soft-pass fallback assertions are forbidden.
- Test integrity mandate (non-negotiable): never fabricate, synthesize, or infer execution success/results when native execution fails.
- Test integrity mandate (non-negotiable): do not add assertions or harness logic that converts hard runtime failures into soft passes.
- Test integrity mandate (non-negotiable): no fake tests, no mocked success for native destruction paths, and no synthetic payload/result generation to satisfy assertions.
- Pass-claim mandate (non-negotiable): for player-visible gameplay behavior, no pass claim is valid without explicit launched-window manual verification in Godot.
- GPU availability is a required runtime invariant for this program; unsupported/non-GPU environments are out of scope.
- If required GPU capabilities are unavailable, startup must hard-exit with an explicit `GPU_REQUIRED` warning/error.
- Do not implement or preserve degraded/non-GPU execution paths for simulation features.
- Transitional shim tracking (recommended hygiene): when a non-native/non-GPU shim is worth remembering, note it in `ARCHITECTURE_PLAN.md` with enough context to retire it later (owner/removal-trigger/target-wave are useful fields, not a mandatory grep-gated format).
- Transitional shim growth (guideline): avoid introducing net new transitional shims unless they unblock a higher-priority native/GPU migration cut; jot down retirement intent when you do.
- Keep `RigidBody3D` usage minimal and exception-based with explicit justification.
- Break APIs freely when it improves architecture or enables required capabilities.
- Remove old abstractions when replacing systems; convert compatibility/legacy paths to tracked transitional shims and delete them on the scheduled wave.

## File Size and Refactor Discipline

- `scripts/check_max_file_length.sh` reports first-party source/config files (`.gd`, `.gdshader`, `.tscn`, `.tres`, workflow YAML) over a `MAX_FILE_LINES=1000` **soft limit** as advisory warnings. It is warn-only and does not fail CI, and it is no longer bundled with any hard marker gate. It still runs `scripts/check_no_direct_refcounted_invocation.sh` (a genuine correctness gate) to ban direct `godot -s addons/local_agents/tests/test_*.gd` usage in automation files. The policy/plan marker check (`scripts/check_policy_plan_markers.sh`) is advisory-only and run separately.
- Treat 1000 lines as a smell, not a gate: prefer to split a file well before then, but do not block work solely on line count.
- When refactoring for size, extract helpers/business logic into focused modules first; keep hot-path files as call-site shims.
- For large files, split by responsibility:
  - orchestration/controller
  - domain systems
  - render adapters
  - input/interaction
  - HUD/presentation binding
- Typed `Resource` classes are preferred over shared dictionaries for reusable runtime state.
- App/root scenes are composition roots only; move behavior into focused controllers.
- Use incremental migration: add new module + tests, move call sites, then remove old inlined code.

## Godot Process and Validation Rules (Canonical Location)

- `GODOT_BEST_PRACTICES.md` is the canonical and enforceable source for Godot-specific design, runtime, testing, validation, harness invocation, and process guidance.
- Keep `AGENTS.md` focused on orchestration, lane ownership, and repository policy.
- If behavior or commands change, update `README` and `GODOT_BEST_PRACTICES.md` together.
- Record breaking changes and migrations in `ARCHITECTURE_PLAN.md`.
- When an avoidable Godot/runtime/parser/test-process error is found, append a dated entry to `GODOT_BEST_PRACTICES.md` under `Error Log / Preventative Patterns`.
- Commit scope policy remains: keep commits scoped by domain (runtime/editor/tests/docs) where practical.

## Skills Reference

The list below is the set of local instructions available in this session.

- gh-address-comments: Review/fix GitHub PR review comments via gh CLI.
  - `file: /Users/adammikulis/.codex/skills/gh-address-comments/SKILL.md`
- gh-fix-ci: Debug/fix GitHub Actions checks via gh.
  - `file: /Users/adammikulis/.codex/skills/gh-fix-ci/SKILL.md`
- skill-creator: Create or update Codex skills.
  - `file: /Users/adammikulis/.codex/skills/.system/skill-creator/SKILL.md`
- skill-installer: Install Codex skills.
  - `file: /Users/adammikulis/.codex/skills/.system/skill-installer/SKILL.md`
