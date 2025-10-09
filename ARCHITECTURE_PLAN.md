# Local Agents Architecture Map

We coordinate work across six collaborating agents: **Frontend**, **Runtime**, **Data**, **Quality**, **DevOps**, and **Experience**. Everyone works in parallel—never rewrite a teammate’s commits, avoid force pushes, and keep diffs scoped to your mission area.

---
## Collaboration Protocol

- [x] Assume other agents may be modifying adjacent files; make additive, minimally disruptive changes.
- [x] Leave TODOs or notes rather than ripping out code you do not own.
- [ ] Announce breaking changes or schema updates here before merging them.
- [x] Prefer feature branches and focused commits; do not force-push shared history.
- [ ] Record cross-agent blockers in `agents.md` so owners can react quickly.
- [ ] Update the “Agent Assigned” checkboxes in `agents.md` whenever responsibilities shift.

---
## 2025-10-09 Hotfix

- [x] Added a lazy `LocalAgentsExtensionLoader` plus a placeholder bottom panel so the editor opens instantly; activate the plugin from the panel when you actually need the runtime (see `logs/godot_startup_lazy_success.log`).
- [x] Dropped a headless sanity script (`scripts/check_extension.gd`) to assert the native extension initializes cleanly in CI or troubleshooting sessions.

---
## Active Refactor (Download & Chat Boundaries)

- Runtime is introducing a dedicated `ModelDownloadManager` helper that wraps cURL/HTTP, split-path resolution, and filesystem writes so `AgentRuntime` can focus on lifecycle/state management.
- Data is extracting shared GDScript helpers (`DownloadJobService`, `AgentDownloadBridge`) that encapsulate worker threads and runtime signal relay outside of the editor UI scene.
- Frontend is slimming the bottom-panel controllers by moving conversation persistence, agent session coordination, and log formatting into reusable services (`ConversationSessionService`, `ChatHistoryPresenter`).
- Quality should audit the new helpers once landed and flag additional oversized scripts (>400 LOC) for follow-up decompositions.

---
## Frontend Agent

**Mission:** Deliver editor and in-game experiences that match or surpass prior releases.

- [x] Maintain the bottom-panel tool button labelled `Local Agents` (to the right of Shader Editor).
- [x] Instantiate `addons/local_agents/editor/LocalAgentsPanel.tscn` with required tabs.
  - [x] **Chat** tab: runtime inspector, prompt input, agent status, quick actions.
  - [x] **Download** tab: llama.cpp model manager with log output and status label.
  - [ ] Reserve slots for future **Memory** and **Graph** tabs to inspect embeddings.
- [x] Ensure panel/controller scripts run in the editor (`@tool`) so UI loads without play mode.
- [ ] Split chat panel responsibilities across lightweight UI controller, conversation service, and runtime session mediator to limit cross-agent conflicts.
- [ ] Restore the first-release 3D agent scene: animated character, chat bubble, voice playback.
- [ ] Provide reusable GDScript components for 2D HUD chat, character attachments, and action cues.
- [ ] Ensure example scenes hook into the runtime autoload and respect configuration resources.
- [ ] Mirror CLI downloader capabilities inside the Download tab and surface streaming progress (currently log-only).
- [ ] Surface runtime state (model/voice loaded, GPU/CPU hints) in the Chat tab.
- [ ] Update README/tooltips/help overlays explaining the bottom-panel workflow.

---
## Runtime Agent

**Mission:** Own the native GDExtension layer and inference pipeline.

- [x] Maintain extension layout (`include/`, `src/`, `thirdparty/`, `bin/`).
- [x] Bundle `libllama`/`libggml*` beside `localagents.*` via `scripts/build_extension.sh` for macOS.
- [x] Align sampler/tokenisation/embedding internals with current llama.cpp APIs.
- [x] Keep `AgentNode` acting as proxy for per-agent metadata, forwarding prompts/history and dispatching signals.
- [ ] Move Hugging Face download + split-file orchestration into `ModelDownloadManager`, delegating to bundled `llama-cli` so runtime picks up upstream fixes while exposing a clear API to `AgentRuntime` (`download_model_hf` + GDS `LocalAgentsDownloadClient`).
- [ ] Add multi-platform build automation (`build_all.sh`) and native test harnesses.
- [ ] Expand `AgentRuntime` job queue, expose JSON grammars, and integrate llama.cpp downloader bindings fully.
- [x] Mediate Piper (speech) and Whisper/Fast-Whisper (transcription) subprocesses behind async helpers (see `AgentRuntime::synthesize_speech`, `LocalAgentsSpeechService`).
- [ ] Finalise **NetworkGraph** module (SQLite JSON1 + FTS5 wrapper) and expose ergonomic bindings.
- [ ] Implement **Embedding Worker** for offline embedding generation wired into NetworkGraph recall.
- [ ] Provide headless tests validating runtime init, inference, downloads, and error handling.

---
## Data Agent

**Mission:** Manage assets, downloads, memory persistence, and configuration.

- [x] Maintain `scripts/fetch_dependencies.sh` with pinned revisions and checksum verification.
- [x] Integrate llama.cpp’s built-in download command (e.g. `main -m download ...`) via runtime helper.
- [x] Publish shared `RuntimePaths` helpers so agents/tests resolve runtimes, voices, and default models consistently.
- [ ] Route Download tab actions through shared helpers to avoid duplicated CLI logic while logging output.
- [ ] Provide a reusable `DownloadJobService` (threaded worker + runtime bridge) consumed by editor panels and headless flows.
- [ ] Maintain metadata manifests (`models/config.json`, `voices/config.json`) for installed assets.
- [ ] Define schema for `memories`, `edges`, `episodes`, and embedding tables with indices.
- [ ] Trigger embedding pipeline on writes and expose cosine similarity search APIs.
- [ ] Surface APIs for `store_memory`, `recall`, streaming iterators, and maintenance tasks (purge/export).
- [ ] Visualise graph/memory data inside future editor tabs.
- [ ] Keep configuration resources (config lists, presets) in GDScript with runtime-safe adapters.
- [ ] Support per-project overrides and export-friendly paths for bundled models.
- [ ] Plan packaging for LoRA/adapters, voice packs, and scenario datasets.

---
## Quality Agent

**Mission:** Safeguard architecture coherence, documentation accuracy, and long-term maintainability.

- [x] Define agent responsibilities in `ARCHITECTURE_PLAN.md` and `agents.md`.
- [ ] Review `README.md`, developer docs, and tutorials each sprint; log divergences between plan and implementation.
- [ ] Publish changelog entries whenever runtime/API surfaces move.
- [ ] Audit repositories for deprecated Godot syntax/build flags and schedule refactors.
- [ ] Draft test strategy (GDExtension unit/integration, editor smoke tests) and integrate with CI.
- [ ] Introduce linting/static analysis configs without blocking other agents.
- [ ] Curate structural cleanup backlog (module boundaries, dependency pruning, build scripts).
- [ ] Identify opportunities for shared utilities (telemetry, logging, error reporting) across agents.
- [ ] Track third-party updates (godot-cpp, llama.cpp, SQLite) and recommend upgrade windows with migration notes.

---
## DevOps Agent

**Mission:** Own build infrastructure, continuous integration, packaging, and release automation.

- [ ] Extend dependency bundling logic to Linux and Windows targets; produce reproducible archives.
- [ ] Configure CI pipelines for macOS/Linux/Windows builds, unit tests, and editor smoke tests.
- [ ] Wire `addons/local_agents/tests/run_all_tests.gd` into CI once build runners are ready so headless Godot tests gate merges.
- [ ] Automate asset/version stamping for releases and nightly builds.
- [ ] Maintain export templates and Godot-compatible installers (editor plugin + demo project).
- [ ] Monitor build tooling (CMake and shell scripts) for drift and keep third-party pins updated.
- [ ] Maintain monitoring for binary size/performance regressions.

---
## Experience Agent

**Mission:** Deliver documentation, tutorials, demos, and overall user onboarding experience.

- [ ] Restore and polish demo scenes (3D agent, HUD chat, voice walkthroughs) with up-to-date scripts.
- [ ] Produce quickstart tutorials (written + video) covering setup, model downloads, and runtime usage.
- [ ] Update screenshots, release notes, and marketing copy for each milestone.
- [ ] Collect user feedback and feed UX improvements back to Frontend/Data agents.
- [ ] Coordinate localisation/content strategy for documentation.

---
## Roadmap

1. **Runtime Stabilisation**
   - [ ] Expand `AgentRuntime` job queue, integrate llama.cpp downloader, and expose JSON grammar support.
   - [x] Harden macOS build tooling (bundle dependent dylibs); [ ] replicate bundling logic on Linux/Windows (DevOps).
2. **Memory Integration**
   - [ ] Implement SQLite NetworkGraph + embedding flow; surface seeds in Chat tab.
3. **Parity Sprint**
  - [ ] Re-enable the in-engine 3D demo and ensure the offline chatbot matches the early Local Agents releases.
4. **Speech & Transcription**
   - [ ] Wrap Piper/Whisper in async jobs, add editor toggles, demo scenes with speech I/O.
5. **Scaling & Tooling**
   - [ ] Add performance instrumentation, batching controls, and expand editor tabs (Memory, Graph, Settings).
   - [ ] Define automation for packaging verification across platforms (DevOps + Quality).

---
## Open Questions

- [ ] Do we rely solely on SQLite, or embed a specialised graph toolkit?
- [ ] `whisper.cpp` vs. `faster-whisper` for best cross-platform performance?
- [ ] Ship Piper/Whisper binaries or guide users to build locally?
- [ ] Autoload design: keep a single runtime autoload or allow per-scene overrides?
- [ ] Automated test strategy for native bindings and GDS integration.
- [ ] Versioning strategy for bundled native dependencies so downstream projects can adopt security patches without breakage.
- [ ] How should demo assets and sample data be packaged for minimal download size?

---
## Immediate Next Steps

- [ ] Validate the editor loads the rebuilt GDExtension with bundled `libllama`/`libggml` libraries and run smoke tests in Godot 4.3+ (Runtime + DevOps).
- [ ] Replicate dependency bundling logic for Linux and Windows outputs; ensure `llama-cli`/`llama-server` ship beside the extension on every platform (DevOps).
- [ ] Complete typing/modern syntax fixes across remaining controllers and configs (Frontend + Quality).
- [ ] Build out NetworkGraph persistence tests and wire them into CI once runtime stabilises (Runtime + DevOps + Quality).
- [ ] Restore the 3D agent demo scene using the new runtime pipeline (Frontend + Experience).
- [ ] Update screenshots, tutorials, and user docs to reflect Download tab status feedback and runtime health indicators (Experience).
- [ ] Wire the new GDS download helpers into the Download tab (`DownloadJobService` extraction) so editor UI exercises the same path as gameplay scripts (Data + Frontend).
- [ ] Expose `llama-server` lifecycle controls (start/stop, config) from `AgentRuntime`/GDS so projects can stand up OpenAI-compatible endpoints easily (Runtime + Data).
- [ ] Add speech/transcription smoke coverage once lightweight Piper/Whisper fixtures are bundled (Runtime + Quality).

This checklist ensures specialised agents can ship features in parallel while tracking progress toward full GDScript/GDExtension parity with the original project.
