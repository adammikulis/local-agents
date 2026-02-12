# AGENTS.md

This file defines implementation rules for working in this Godot repository.

## Core Principles

- Prefer simple scene-first architecture over deep inheritance chains.
- Keep gameplay logic in GDScript unless native code is required for performance or platform APIs.
- Favor explicit data flow (signals, state objects, resources) over hidden singleton coupling.
- Build for deterministic behavior in headless tests.
- Default feature-design question: `Can this be implemented with graphs and/or custom Resource types first?` If yes, prefer that path before ad-hoc dictionaries or one-off node state.
- When graph-backed features are added, implement or extend Cypher playbook/query coverage as needed so the data model is inspectable and operable via graph queries.
- Decompose multi-concern work into scoped sub-agents when tasks can run independently.
- Do not add defensive fallback implementations for required systems; enforce required dependencies and fail fast with actionable errors.
- No local fallback path for required core libraries/runtime services: if a required dependency is unavailable, return explicit errors and stop the flow.

## Execution Model

- Default execution behavior is to spawn sub-agents as needed whenever concerns can be split safely.
- Default completion behavior is to proactively create feature-scoped commits and push them unless the user asks otherwise.
- Spawn sub-agents for distinct concerns (runtime, downloads, tests, docs, build scripts) when work can proceed in parallel.
- Give each sub-agent clear file ownership and expected outputs before starting.
- Merge sub-agent work back into a single concern-based architecture plan with checkbox state updates.
- Avoid cross-agent coordination layers in repo docs; track status in `ARCHITECTURE_PLAN.md` only.

## Project Structure

- Use `addons/local_agents/` as the plugin boundary.
- Default spatial partitioning uses a hex grid (`hex_pointy`) unless a feature explicitly requires otherwise.
- Grid settings should be standardized in a central config/resource and reused across systems; domain data (smell, danger, resources, influence) should be modeled as layers/filters on top of that shared grid.
- Keep editor-only code under `addons/local_agents/editor/` and mark scripts with `@tool` only when required.
- Keep runtime-only logic outside editor UI controllers.
- Store reusable data in `Resource` classes under `configuration/parameters/`.
- Prefer custom `Resource` classes whenever domain state is reused, serialized, edited, or passed across systems (inventories, villager state, economy snapshots, config bundles, event payload wrappers).
- Default to refactoring ad-hoc dictionaries into named `Resource` types unless the data is truly one-off/local temporary glue.

## Scenes and Nodes

- Keep scenes composable and shallow; avoid large monolithic scene trees.
- Use exported `NodePath` or `@onready` references for stable wiring, not fragile tree walks.
- Prefer one responsibility per controller node.
- Do not put business logic directly in `.tscn`-bound anonymous callables.

## GDScript Style

- Use explicit types where they improve correctness and tooling.
- Prefer custom class type annotations when they improve readability and correctness.
- For headless/bootstrap-sensitive paths, ensure stable script load order with explicit `preload` constants before relying on custom class annotations.
- If load-order stability cannot be guaranteed (for example plugin bootstrap chains), avoid brittle custom-class annotations there and use `preload` + runtime checks.
- Validate all external inputs (files, runtime calls, dictionaries) before use.
- Return structured error dictionaries for runtime/service APIs.

## Signals and State

- Prefer the communication rule: signal up, call down.
- Child/leaf nodes emit signals upward for intent and state changes.
- Parent manager/controller/mediator nodes orchestrate flow and call methods downward.
- Use direct peer-to-peer signals only for tightly scoped local relationships within one scene.
- Avoid cross-system signal meshes between sibling domains; route through a mediator.
- Use signals for cross-node communication; avoid polling loops.
- Connect signals in `_ready()` and disconnect on teardown when lifecycle is non-trivial.
- Keep signal names verb-based and payloads stable.
- Avoid emitting duplicate signals for the same state transition.

## Async and Threading

- Keep UI thread non-blocking; run long downloads/inference in worker threads or native async paths.
- Never mutate UI from worker threads; use deferred calls to marshal back to main thread.
- Always join/cleanup `Thread` instances on node exit.

## Files, Paths, and Assets

- Normalize `res://`, `user://`, and absolute paths before file operations.
- Use `RuntimePaths` helpers for platform-dependent executables and output directories.
- Ensure directory creation before writes and handle errors explicitly.
- Do not commit downloaded runtime artifacts, models, or caches.

## Native Extension Rules

- Treat required GDExtensions (for example graph/memory runtime) as mandatory for the features that depend on them.
- Never build parallel fallback code paths for required extensions just to avoid initialization failures.
- Initialize required extensions explicitly and fail fast with actionable errors when unavailable.
- Guard all runtime calls with singleton/method availability checks.
- Keep compatibility with current Godot stable and track llama.cpp API changes in focused commits.
- Prefer additive extension changes and preserve existing script contracts unless migration notes are provided.

## Testing Rules

- Keep a fast core suite that runs without heavy assets.
- Maintain a real-model runtime suite that verifies load, embed, and generation end-to-end.
- Auto-acquire required test models when runtime is available; fail loudly if acquisition fails.
- Ensure tests are headless-safe (`godot --headless --no-window`).

## Performance and Memory

- Avoid per-frame allocations in hot paths.
- Cap history/context sizes and truncate large payloads before embedding.
- Reuse resources and caches where practical.
- Add lightweight profiling logs around long-running runtime operations.

## Editor Plugin UX

- Keep plugin activation lazy when native runtime is expensive to initialize.
- Every long-running action must surface status and failure details in the UI.
- Disable conflicting controls while jobs are active.
- Prefer predictable defaults; for required dependencies, show explicit error states instead of fallback behavior.

## Dependency and Build Hygiene

- Pin and document third-party revisions when behavior changes.
- Make fetch/build scripts idempotent.
- Support clean rebuild from an empty `thirdparty/` and `bin/` state.
- Keep CI commands aligned with local scripts.

## Documentation and Change Discipline

- Update README/testing docs when behavior or commands change.
- Record breaking changes and migrations in `ARCHITECTURE_PLAN.md`.
- Keep commits scoped: runtime, editor UI, tests, docs should be separable where possible.
