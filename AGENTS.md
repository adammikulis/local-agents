# AGENTS.md

This file defines implementation rules for this repository. Higher sections are intentionally higher priority.

## Required Startup Reading (Mandatory)

- Read `GODOT_BEST_PRACTICES.md` at session startup before planning or implementation.
- Treat `GODOT_BEST_PRACTICES.md` as required process, not optional guidance.
- Godot operational/testing/validation and invocation rules are canonical in `GODOT_BEST_PRACTICES.md` and are fully enforceable.
- Validation order default is mandatory: run a real non-headless launch first to surface parser/runtime scene errors early, then run headless harness sweeps.

## Sub-Agent-First Execution Model (Highest Priority)

- Planning-first, impact-first execution: each wave starts with a concrete target and explicit priority order.
- Initial investigation is mandatory: launch a planning sub-agent to scan current state and risks before any implementation edits.
- The main thread is executive only: coordination of user communication, architecture decisions, and lane orchestration.
- **Main-thread hard rule**: The main thread MUST NOT perform implementation edits. That means no `apply_patch`, no file edits, no config rewrites, and no direct code edits in source/config docs (except this instruction file when updating process).
- **Main-thread hard rule**: The main thread MUST NOT perform planning, merge/review coordination, validation planning, or verification tasks if a sub-agent can do them.
- **User override rule**: If the user explicitly requests main-thread execution (for example, “do this yourself without spawning a sub-agent”), that request overrides main-thread behavior rules in this file for the scoped task, as long as higher-priority system/developer safety constraints are still respected.
- **Allowed on main thread only**: user-facing communication, high-level escalation, and explicit lane orchestration only.
- **Allowed to read on main thread**: repository state checks and agent outputs for context.
- **Implementation rule**: all source/config/behavior edits are executed by spawned `worker` lanes.
- **Verification rule**: all verification for contract/native changes is executed by spawned `validation`/`Test-Infrastructure` lanes.
- Use sub-agents for both planning and execution (mandatory):
  - validation and verification should also be assigned explicitly to validation lanes for contract-heavy or native-path changes.
  - planning must always be done by a planning sub-agent that maps scope, owners, acceptance criteria, and risk calls before implementation starts.
  - spawn implementation/validation sub-agents whenever responsibilities can be split safely.
- Workflow loop:
  0. Before any implementation edit, estimate final file size impact and enforce file-size preconditions.
  - If any in-scope edit targets a source/config file at or above 900 lines, execution must be split before code changes begin.
  - If predicted delta pushes a file over 1000 lines, create or reuse a dedicated helper/source split lane immediately and move non-call-site logic there.
  1. Update `ARCHITECTURE_PLAN.md` first with priority band (P0/P1/P2), owners, and acceptance criteria.
  2. Launch one or more planning sub-agents for decomposition + coupling-risk assessment.
  3. Launch scoped implementation and validation sub-agents in parallel.
  4. Keep main-thread focus on coordination and escalation while agents own execution, integration/deconflict, verification, and commit/push flow.
  5. Proactively close stale or completed sub-agents immediately when they finish; do not defer. This is mandatory to preserve agent slots and prevent forced context resets in future turns.
  6. Track active agent slots; if only 4 or fewer slots remain, notify the user immediately and proceed conservatively with spawn decisions.
  7. Deconflict overlaps immediately and merge outputs as soon as they land.
  8. Run targeted verification on the highest-impact wave via validation lanes.
  9. Keep plan/status updates synchronized as scoped changes are committed via sub-agent lanes.
- Ask user questions only when an architectural or requirement decision is truly ambiguous, through the coordinating sub-agent.
- If a main-thread implementation edit is accidentally initiated, stop, report the violation immediately, and do not continue until explicit user confirmation to resume via lanes.
- If a main-thread planning, merge/review coordination, or validation activity is accidentally initiated when a sub-agent can execute it, stop and reassign to sub-agent lanes immediately.
- **Agent lifecycle rule (critical)**: The main thread must close completed/stale agents (`close_agent`) as soon as possible after they are no longer active. Delayed closure is a coordination failure with direct operational impact (slot pressure and workflow fragmentation).

### Additional Sub-Agent Lanes (including but not limited to)

- GitHub-Operations lane: manage branch hygiene, PR lifecycle (`gh` status/labels/reviewers/checks), commit/push flow, and PR synchronization; owns status/error triage and merge blockers.
- Code-Review lane: perform independent review of each wave output (logic correctness, API changes, coupling risks, contracts, and file-size/type constraints); owns prioritized findings with file:line references.
- Test-Infrastructure lane: own CI + test harness changes (`.github`, `tests`, local bootstrap scripts, headless/runtime suites, flake handling, performance budgets); owns deterministic command matrix and pass/fail expectations.
- Merge-Conflict lane: resolve rebase/cherry-pick/patch conflicts with intent-preserving merges and minimal semantic drift; owns conflict-resolution notes and post-resolution verification.
- Release-Versioning lane: drive version strategy, changelog/release notes, migration notes, and release gating checks (including final verification and tag prep).
- Documentation lane: update `README`, `ARCHITECTURE_PLAN.md`, and maintainer/user docs when behavior or workflows change; owns consistency checks and migration wording.

Lane trigger rule: if a wave touches any domain, spawn the corresponding lane(s) with explicit ownership and complete sub-agent outputs before merge.

### Validation Defaults

- For any changed native or simulation contract area, spawn a validation sub-agent unless the change is docs-only.
- Give validation agents explicit acceptance criteria and test commands before they start.
- Merge findings as structured pass/fail artifacts with notable failures.
- Reassign/redeploy immediately if an agent becomes blocked or stale.
- Required sequence for \"does it work\" checks: non-headless launch first, then full headless harness suites.

## Current Repo Policy

- There are no downstream consumers to preserve in this repo right now.
- Prioritize rapid feature improvement and stronger simulation behavior over compatibility.
- Default to voxel-native simulation, collision, and destruction paths.
- Zero-fallback mandate (non-negotiable): do not add, preserve, or reintroduce fallback behavior for simulation, destruction, collision, or dispatch paths.
- If the native/GPU path cannot execute, fail fast with explicit typed errors (`GPU_REQUIRED`/`NATIVE_REQUIRED`) instead of routing to alternate logic.
- Tests and runtime flows must assert native-path execution for rigid-body voxel damage; skip/soft-pass fallback assertions are forbidden.
- Test integrity mandate (non-negotiable): never fabricate, synthesize, or infer execution success/results when native execution fails.
- Test integrity mandate (non-negotiable): do not add assertions or harness logic that converts hard runtime failures into soft passes.
- Test integrity mandate (non-negotiable): no fake tests, no mocked success for native destruction paths, and no synthetic payload/result generation to satisfy assertions.
- GPU availability is a required runtime invariant for this program; unsupported/non-GPU environments are out of scope.
- If required GPU capabilities are unavailable, startup must hard-exit with an explicit `GPU_REQUIRED` warning/error.
- Do not implement or preserve degraded/non-GPU execution paths for simulation features.
- Keep `RigidBody3D` usage minimal and exception-based with explicit justification.
- Break APIs freely when it improves architecture or enables required capabilities.
- Remove old abstractions when replacing systems; avoid compatibility shims and legacy paths.

## File Size and Refactor Discipline

- `scripts/check_max_file_length.sh` enforces a hard `MAX_FILE_LINES=1000` limit for first-party source/config (`.gd`, `.gdshader`, `.tscn`, `.tres`, workflow YAML), and also runs `scripts/check_no_direct_refcounted_invocation.sh` to ban direct `godot -s addons/local_agents/tests/test_*.gd` usage in automation files.
- Never increase limits or add exceptions; split and refactor immediately when a file exceeds the cap.
- Never allow an implementation to proceed that can push a file over 1000 lines; enforce a local hard stop at 900 lines and split before changes.
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
