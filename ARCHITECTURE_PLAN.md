# Local Agents Architecture Plan

This plan is organized by engineering concern so work can be split into focused sub-agents.

## Operating Rules

- [x] Use concern-based workstreams instead of role roster ownership.
- [x] Keep `AGENTS.md` as the canonical engineering rules file.
- [x] Prefer additive changes and small, reviewable diffs.
- [x] Signal up and call down (mediator orchestration) for cross-system flows.
- [x] Record breaking API/schema changes in this file before merge.
- [x] Keep memory/graph implementation out of this execution stream when separately owned.

## Concern A: Runtime and GDExtension Stability

Scope: `addons/local_agents/gdextensions/localagents/`, `addons/local_agents/runtime/`, `addons/local_agents/agents/`

- [x] Lazy extension initialization path exists (`LocalAgentsExtensionLoader`, placeholder panel activation flow).
- [x] Preflight binary existence checks added before extension initialization to avoid hard crashes when dylib/so/dll is missing.
- [x] `Agent` now guards extension availability and instantiates `AgentNode` safely at runtime.
- [x] Complete end-to-end runtime initialization validation on fresh machines after dependency/build scripts run.
- [x] Add structured runtime health endpoint/API for editor and tests (extension loaded, model loaded, runtime binaries found).
- [x] Add JSON grammar/options coverage in `AgentRuntime` generation path.

Sub-agent split:
- Runtime-Core: extension lifecycle, `AgentRuntime`, `AgentNode` contracts.
- Runtime-API: GDScript bridge consistency and backward-compatible error payloads.

## Concern B: Model Download and Asset Pipeline

Scope: `controllers/ModelDownloadService.gd`, `controllers/DownloadController.gd`, `api/DownloadClient.gd`, `src/ModelDownloadManager.cpp`, `scripts/fetch_dependencies.sh`, `scripts/fetch_runtimes.sh`

- [x] Runtime-side model downloading via `ModelDownloadManager` is present.
- [x] GDScript download client bridge exists (`LocalAgentsDownloadClient`).
- [x] Download tab receives runtime progress/log/finished signals.
- [x] Fixed dependency fetch path resolution bug (`fetch_dependencies.sh` repo root).
- [x] Fix stale Piper voice URLs and add fallback/continue behavior for unavailable voice artifacts.
- [x] Consolidate UI and headless download orchestration behind shared helper(s) to avoid duplicate logic.
- [x] Add checksum and manifest verification for downloaded model/voice artifacts.

Sub-agent split:
- Download-Runtime: native downloader behavior, split GGUF handling, cache behavior.
- Download-GDS: editor/service orchestration, logs, retries, UI status integration.

## Concern C: Chat, Controller Boundaries, and Scene Architecture

Scope: `controllers/ChatController.gd`, `agent_manager/AgentManager.gd`, `editor/*`, `configuration/ui/*`

- [x] Chat + Download + Configuration panel composition is present.
- [x] Null-guard fixes landed for model load and config apply flows when runtime/agent is unavailable.
- [x] Continue decomposition of oversized controllers into mediator + focused services (conversation/session/history).
- [x] Add explicit runtime state badges in Chat tab (runtime loaded/model loaded/speech ready).
- [x] Ensure editor-only and runtime-only responsibilities are separated cleanly.

Sub-agent split:
- UI-Orchestration: mediator/controller boundaries and tab interactions.
- UX-State: status visibility, recoverable error flows, disable/enable behavior.

## Concern D: Memory and Graph Capabilities

Scope: `controllers/ConversationStore.gd`, `docs/NETWORK_GRAPH.md`, future graph/memory tabs

- [x] Conversation persistence and search scaffolding exist via `NetworkGraph`.
- [ ] Finalize schema for memories/edges/episodes/embeddings and indices.
- [ ] Add embedding write pipeline and robust recall APIs (query, top-k, pagination/streaming).
- [ ] Add migration/maintenance tools (purge/export/repair).
- [ ] Implement editor Memory and Graph inspection tabs.

Sub-agent split:
- Graph-Core: schema, persistence contracts, migration safety.
- Graph-UX: memory/graph visualization and inspection workflows.

## Concern E: Speech and Transcription

Scope: `runtime/audio/SpeechService.gd`, `agents/Agent.gd`, native speech/transcription runtime hooks

- [x] Async speech/transcription service and runtime hooks are integrated.
- [x] Agent-level speech playback pipeline exists with async job callbacks.
- [x] Add deterministic smoke tests with small fixtures for speech/transcription success/failure paths.
- [x] Improve voice asset resolution/reporting in UI when assets are missing or mismatched.

Sub-agent split:
- Speech-Runtime: native process lifecycle and payload contracts.
- Speech-GDS: service orchestration, playback, and UX errors.

## Concern F: Test Strategy and CI Gating

Scope: `addons/local_agents/tests/*`, CI pipeline setup

- [x] Headless harness exists (`run_all_tests.gd`).
- [x] Heavy/runtime model helper exists (`test_model_helper.gd`).
- [x] Runtime test harness now includes explicit runtime suite paths and auto-model acquisition logic.
- [x] Finalize policy: runtime suite should fail loudly on model acquisition/inference failure unless explicitly opted out.
- [x] Wire headless tests into CI with separate jobs for core-only and runtime-heavy suites.
- [x] Add CI artifacts/log collection for failed runtime/download checks.

Sub-agent split:
- Test-Harness: harness behavior, skip/fail policy, deterministic outputs.
- CI-Infra: matrix jobs, caching, artifacts, merge gates.

## Concern G: Cross-Platform Build and Packaging

Scope: build scripts, release packaging, binary layout

- [x] macOS build script bundles local extension dependencies and llama tools.
- [x] Provide Linux/Windows parity for bundled binaries and runtime tools.
- [x] Add `build_all.sh` and reproducible packaging outputs per platform.
- [x] Add binary size/performance regression checks per release.

Sub-agent split:
- Build-Systems: platform-specific build scripts and binary staging.
- Release-Quality: packaging verification and regression tracking.

## Concern H: Demos, Docs, and Onboarding

Scope: `README.md`, examples, docs, screenshots/tutorials

- [x] Core docs and examples exist.
- [x] Update README to match current runtime-heavy test behavior and flags.
- [x] Restore/polish 3D demo parity and HUD components.
- [x] Refresh docs/screenshots/tutorials around download/runtime health workflows.

Sub-agent split:
- Demo-Scenes: examples and in-engine demo parity.
- Docs-Onboarding: quickstart accuracy and release-facing docs.

## Immediate Queue (Ready to Spawn)

- [x] Fix Piper voice fetch URLs and make dependency fetch resilient to missing optional voice assets.
- [x] Finish native build verification and confirm `scripts/check_extension.gd` passes with produced binaries.
- [x] Run full runtime-heavy tests with real model load/embed/generate and capture pass/fail baseline.
- [x] Add CI split jobs: `core-headless` and `runtime-heavy`.
- [x] Update README test section to align with current harness behavior.

## Breaking Changes

- [x] February 12, 2026: Migrated active ecology smell/wind runtime from hex-grid path to shared sparse voxel grid system (`VoxelGridSystem`, `SmellFieldSystem`, `WindFieldSystem`).
- [x] Legacy hex/grid config contracts are no longer part of the active ecology runtime path.
- [x] February 12, 2026: Path/flow traversal now keys routes by voxel coordinates via `SpatialFlowNetworkSystem` + `VoxelGridSystem`.
- [x] February 12, 2026: Environment generation now includes `voxel_world` terrain payload (`block_rows`, `columns`, block/resource type counts) generated via Godot `FastNoiseLite` and rendered by `EnvironmentController` as Minecraft-style block terrain.
- [x] February 12, 2026: Environment generation now bakes deterministic `flow_map` payloads (downhill links, accumulation, channel strength) and hydrology consumes baked flowmap rows directly for water network construction.

## Deferred / Decision Log

- [ ] Decide whether to keep SQLite-only graph architecture or introduce specialized graph backend.
- [x] Decide whisper backend policy (`whisper.cpp` vs `faster-whisper`) per platform tier.
- [x] Decide long-term packaging/versioning strategy for bundled native dependencies.

Policy decisions (recorded February 12, 2026):
- Whisper backend policy: default to `whisper.cpp` CLI/runtime integration for all supported desktop tiers (macOS/Linux/Windows) to preserve single-toolchain native distribution and headless determinism. Treat `faster-whisper` as optional future experimentation only, not a required runtime/backend path.
- Bundled dependency versioning strategy: keep build/runtime dependencies pinned in scripts/manifests, update them via focused additive commits, and validate each bump with headless core + runtime-heavy suites before merge. Runtime artifacts remain out of git history; only scripts/metadata and reproducible fetch/build logic are committed.
