# AGENTS.md

This file defines implementation rules for this repository. Higher sections are intentionally higher priority.

## Current Repo Policy

- There are no downstream consumers to preserve in this repo right now.
- Prioritize rapid feature improvement and stronger simulation behavior over compatibility.
- Break APIs freely when it improves architecture or enables required capabilities.
- Remove old abstractions when replacing systems; avoid compatibility shims and legacy paths.

## Execution Model (Highest Priority)

- Main-thread role is executive only: planning, user interaction, architecture decisions, sub-agent orchestration, integration/deconflict, verification, and commit/push flow.
- Default to sub-agent-first implementation. Keep main-thread direct edits for glue/integration and cross-cutting fixes.
- Before each wave, close stale or finished sub-agents to avoid stale references and thread/session pressure.
- Proactively close agents as soon as they finish assigned work.
- Workflow loop:
  1. Update `ARCHITECTURE_PLAN.md` first with checkbox state.
  2. Spawn as many scoped sub-agents as can safely execute in parallel.
  3. Integrate and deconflict outputs as they complete; do not wait for perfect synchronization.
  4. Run targeted verification.
  5. Create feature-scoped commits and push.
  6. Repeat.
- Ask user questions only when an architectural or requirement decision is ambiguous.

## File Size and Refactor Discipline

- `scripts/check_max_file_length.sh` enforces a hard `MAX_FILE_LINES=600` limit for first-party source/config (`.gd`, `.gdshader`, `.tscn`, `.tres`, workflow YAML).
- Never increase limits or add exceptions; split and refactor immediately when a file exceeds the cap.
- For large files, split by responsibility:
  - orchestration/controller
  - domain systems
  - render adapters
  - input/interaction
  - HUD/presentation binding
- Typed `Resource` classes are preferred over shared dictionaries for reusable runtime state.
- App/root scenes are composition roots only; move behavior into focused controllers.
- Use incremental migration: add new module + tests, move call sites, then remove old inlined code.

## Core Design Rules

- Keep gameplay logic in GDScript unless native is required for performance or platform APIs.
- Prefer explicit data flow (`signal up, call down`) instead of hidden singleton coupling.
- Decompose concerns with clear ownership; avoid deep inheritance chains.
- If a feature can be done with scenes/Resources/graphs first, do so before ad-hoc dictionary state.
- Deterministic behavior in headless tests is mandatory.
- Do not add defensive fallback behavior for required systems. Required dependencies must fail fast with actionable errors.

## Project Structure

- Plugin boundary is `addons/local_agents/`.
- Use `hex_pointy` grid defaults unless explicitly required otherwise.
- Centralize partitioning/grid config in shared configuration resources.
- Keep editor code under `addons/local_agents/editor/`; mark scripts with `@tool` only where required.
- Keep runtime logic outside editor UI controllers.
- Store reusable data under `configuration/parameters/` as `Resource` classes.
- If domain state is reused, serialized, edited, or shared, use typed resources instead of one-off dictionaries.

## GDScript, Nodes, and Communication

- Use explicit types where they improve correctness and tooling.
- Use custom class annotations when helpful, and `preload` for load-order sensitive paths.
- In unstable bootstrap chains, avoid brittle class annotations and use runtime checks.
- Validate external inputs before use.
- Return structured error dictionaries for runtime/service APIs.
- Scenes should stay composable and shallow with stable wiring via exported `NodePath`/`@onready` references.
- One responsibility per controller node.
- Avoid anonymous callables in `.tscn` containing business logic.
- Communication rule: signals for cross-node flow, calls downward from controllers.
- Use one-way local intent via child/leaf signals upward.
- Connect signals in `_ready()` and disconnect on teardown for non-trivial lifecycles.
- Avoid duplicate signals for the same transition.

## Concurrency, Paths, and Assets

- Keep UI thread non-blocking; use worker threads/native async for expensive work.
- Never mutate UI from worker threads; use deferred calls for handoff.
- Join and clean up `Thread` instances on node exit.
- Normalize `res://`, `user://`, and absolute paths before file operations.
- Use `RuntimePaths` helpers for platform-specific outputs.
- Ensure directories exist before writes and handle write errors explicitly.
- Do not commit downloaded runtime artifacts, models, or caches.

## Native Extensions and Build Hygiene

- Required GDExtensions are mandatory dependencies for features that need them.
- Do not ship local fallback code paths for missing required extensions; fail loudly and stop.
- Initialize required extensions explicitly and guard calls with singleton/method availability checks.
- Keep compatibility with current Godot stable and track third-party API changes in focused commits.
- Pin and document third-party revisions on behavior change.
- Keep fetch/build scripts idempotent and support clean rebuilds from empty `thirdparty/` and `bin/`.
- Align CI commands with local scripts.

## Testing and Performance

- Maintain a fast headless-safe core suite and a higher-cost runtime suite.
- Auto-acquire required test assets/models when available; fail loudly when acquisition fails.
- Require `godot --headless --no-window` paths in CI-relevant flows.
- Avoid per-frame allocations in hot paths.
- Profile long-running runtime work and log lightweight telemetry.

## Plugin UX and Documentation

- Keep plugin activation lazy for expensive runtime initialization.
- Long actions must show status and clear failure details in UI.
- Disable conflicting controls while background work is active.
- For required dependencies, show explicit error states rather than silent fallback behavior.
- Update README/testing docs when behavior or commands change.
- Record breaking changes and migrations in `ARCHITECTURE_PLAN.md`.
- Keep commits scoped by domain (runtime/editor/tests/docs) where practical.

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
