# Local Agents Architecture Map

We now coordinate work across four collaborating agents: **Frontend Agent**, **Runtime Agent**, **Data Agent**, and **Quality Agent**. Everyone works in parallel—never rewrite or delete a teammate’s commits, avoid force pushes, and keep diffs scoped to your mission area.

---
## Collaboration Protocol

- Assume other agents are modifying adjacent files; make additive, minimally disruptive changes.
- Leave TODOs or notes rather than ripping out code you do not own.
- Announce breaking changes or schema updates here before merging them.
- Prefer feature branches and focused commits; do not force-push shared history.

---
## Frontend Agent

**Mission:** Deliver editor and in-game experiences that match or surpass prior releases.

### F.1 Editor Workspace
- Maintain the bottom-panel tool button labelled `Local Agents` (to the right of Shader Editor).
- Instantiate `addons/local_agents/editor/LocalAgentsPanel.tscn`, hosting:
  - **Chat** tab: runtime inspector, prompt input, agent status, quick actions.
  - **Download** tab: llama.cpp model manager with progress, presets, and custom URLs.
  - Reserve slots for **Memory** and **Graph** tabs to inspect embeddings later.
- All panel scripts must run in the editor (`@tool`) so UI loads without entering play mode.

### F.2 Game Parity
- Restore the first-release 3D agent scene: animated character, chat bubble, voice playback.
- Provide reusable GDScript components for 2D HUD chat, character attachments, and action cues.
- Ensure example scenes hook into the new runtime autoload and respect configuration resources.

### F.3 UX & Documentation
- Mirror CLI downloader capabilities inside the Download tab and show shell commands in logs.
- Surface runtime state (model/voice loaded, GPU/CPU hints) in the Chat tab.
- Update README, tooltips, and help overlays explaining the bottom-panel flow.

---
## Runtime Agent

**Mission:** Own the native GDExtension layer and inference pipeline.

### R.1 Layout & Tooling
- Directory: `addons/local_agents/gdextensions/localagents/`
  - `include/`: headers (`AgentRuntime.hpp`, `AgentNode.hpp`, `MemoryGraph.hpp`).
  - `src/`: implementations (`AgentRuntime.cpp`, `AgentNode.cpp`, `LocalAgentsRegister.cpp`, `MemoryGraph.cpp`).
  - `thirdparty/`: shallow clones (`godot-cpp`, `llama.cpp`, `whisper.cpp`/`faster-whisper`, SQLite amalgamation, optional graph libs).
  - `bin/`: compiled libraries per platform (ships `localagents.*` plus bundled `libllama`/`libggml*` siblings for editor discovery).
- Scripts: `scripts/fetch_dependencies.sh`, `scripts/build_extension.sh`, future `build_all.sh` and test harnesses.

### R.2 Shared Runtime
- `AgentRuntime` singleton responsibilities:
  - Load/manage a single llama.cpp model (default Qwen3-4B) with thread-safe job queue.
  - Handle sampler chains, batching, JSON-mode grammars, and seed control using current llama.cpp APIs.
  - Expose binding for llama.cpp’s download functionality so the Download tab can trigger it.
  - Mediate Piper (speech) and Whisper/Fast-Whisper (transcription) subprocesses, abstracted behind async helpers.
- `AgentNode` becomes a proxy: maintains per-agent metadata, forwards prompts/history to runtime, receives completions, dispatches signals.

### R.3 Extended Services
- **MemoryGraph module** (C++): wrap SQLite (JSON1 + FTS5) for memory storage, edges, embeddings. Provide ergonomic GDNative API.
- **Embedding Worker**: allow offline embedding generation via llama.cpp or fast-embed. Hook into MemoryGraph and chat context recall.
- **Speech / Transcription**: asynchronous Piper queue, caching, playback events; Whisper streaming for voice inputs.
- **Testing**: headless scenarios verifying runtime init, inference, downloads, and error handling.

---
## Data Agent

**Mission:** Manage assets, downloads, memory persistence, and configuration.

### D.1 Downloader & Assets
- Maintain `fetch_dependencies.sh` with pinned revisions and checksum verification.
- Integrate llama.cpp’s built-in download command (e.g. `main -m download ...`) so models can be pulled from official mirrors.
- Download tab should call into a shared helper to avoid duplicating CLI logic; log output for transparency.
- Metadata manifests (`models/config.json`, `voices/config.json`) enumerate installed assets, quantization, and hashes.

### D.2 Memory & Graph
- Schema: `memories`, `edges`, `episodes`, embedding tables with indexes for `agent_id`, timestamps, tags.
- Embedding pipeline triggered on write; similarity search (cosine) to retrieve context windows.
- Expose APIs: `store_memory`, `recall`, streaming iterators, plus admin endpoints (purge, export).
- Eventually surface graph visualisation in editor Memory/Graph tabs.

### D.3 Configuration & Persistence
- Keep configuration resources (config lists, presets) in GDScript; add adapters so runtime can read/write safely.
- Support per-project overrides and export-friendly paths for bundled models.
- Plan for LoRA/adapter packaging, voice packs, and scenario datasets.

---
## Quality Agent

**Mission:** Safeguard architecture coherence, documentation accuracy, and long-term maintainability.

### Q.1 Documentation & Knowledge
- Review `ARCHITECTURE_PLAN.md`, `README.md`, and developer docs every sprint; track divergences between the plan and implementation.
- Publish notes covering runtime/API changes, including new native symbols or script-facing properties.
- Maintain a migration log describing updates downstream projects must make.

### Q.2 Code Health & Testing
- Audit repositories for outdated patterns (deprecated Godot syntax, stale build flags) and schedule refactors.
- Propose test plans for GDExtension (unit + integration) and editor GDScript smoke tests.
- Track CI coverage gaps; introduce linting/static analysis configs without blocking other agents.

### Q.3 Refactor & Improvement Backlog
- Curate structural cleanups (module boundaries, dependency pruning, build scripts).
- Identify opportunities for shared utilities (error reporting, telemetry, logging) that help multiple agents.
- Monitor third-party updates (godot-cpp, llama.cpp, SQLite) and recommend upgrade windows, noting required code changes.

---
## Roadmap

1. **Runtime Stabilisation**
   - Expand `AgentRuntime` job queue, integrate llama.cpp downloader, and expose JSON grammar support.
   - Harden build tooling (multi-platform scripts, optional CI). Ensure macOS builds continue bundling dependent dylibs via `build_extension.sh` and replicate bundling on Linux/Windows.

2. **Memory Integration**
   - Implement SQLite MemoryGraph + embedding flow; surface seeds in Chat tab.

3. **Parity Sprint**
   - Re-enable in-engine 3D demo and ensure offline chatbot behaves like early Mind Game releases.

4. **Speech & Transcription**
   - Wrap Piper/Whisper in async jobs, add editor toggles, demo scenes with speech I/O.

5. **Scaling & Tooling**
   - Add performance instrumentation, batching controls, and expand editor tabs (Memory, Graph, Settings).
   - Quality Agent to define automation for packaging verification across platforms.

---
## Open Questions

- Do we rely solely on SQLite, or embed a specialised graph toolkit?
- `whisper.cpp` vs. `faster-whisper` for best cross-platform performance?
- Ship Piper/Whisper binaries or guide users to build locally?
- Autoload design: keep a single runtime autoload or allow per-scene overrides?
- Automated test strategy for native bindings and GDS integration.
- How do we version bundled native dependencies so downstream projects can opt into security patches without breaking compatibility?

---
## Immediate Next Steps

1. Validate the editor loads the rebuilt GDExtension with bundled `libllama`/`libggml` libraries on macOS; replicate packaging logic on Linux/Windows.
2. Finish typing fixes and modern Godot syntax updates across controllers (`ChatController.gd`, `SavedChatsController.gd`, etc.) so 4.3+ parsing succeeds.
3. Flesh out MemoryGraph persistence tests and wire them into CI once runtime stabilises.
4. Restore the 3D agent demo scene using the new runtime pipeline.
5. Update screenshots and user docs to reflect the Download tab status feedback and runtime health indicators.

This division clarifies ownership so multiple specialised agents can ship features in parallel while we converge on full GDScript/GDExtension parity with the original project.
