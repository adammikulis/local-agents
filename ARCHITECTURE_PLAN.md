# Local Agents Architecture Map

We coordinate the rebuild across three collaborating agents: **Frontend Agent**, **Runtime Agent**, and **Data Agent**. Each agent owns a vertical slice so we can reach feature parity with the original Mind Game release (3D demo, in-engine agent) while completing the migration to pure GDScript + GDExtension.

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
  - `include/`: headers (`AgentRuntime.hpp`, `AgentNode.hpp`, upcoming memory wrappers).
  - `src/`: implementations (`AgentRuntime.cpp`, `AgentNode.cpp`, `LocalAgentsRegister.cpp`, future modules).
  - `thirdparty/`: shallow clones (`godot-cpp`, `llama.cpp`, `whisper.cpp` / `faster-whisper`, SQLite amalgamation, optional graph libs).
  - `bin/`: compiled libraries per platform.
- Scripts: `scripts/fetch_dependencies.sh`, `scripts/build_extension.sh`, future `build_all.sh` and test harnesses.

### R.2 Shared Runtime
- `AgentRuntime` singleton responsibilities:
  - Load/manage a single llama.cpp model (default Qwen3-4B) with thread-safe job queue.
  - Handle sampler profiles, batching, JSON-mode grammars, and seed control.
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
## Roadmap

1. **Runtime Stabilisation**
   - Expand `AgentRuntime` job queue, integrate llama.cpp downloader, and expose JSON grammar support.
   - Harden build tooling (multi-platform scripts, optional CI).

2. **Memory Integration**
   - Implement SQLite MemoryGraph + embedding flow; surface seeds in Chat tab.

3. **Parity Sprint**
   - Re-enable in-engine 3D demo and ensure offline chatbot behaves like early Mind Game releases.

4. **Speech & Transcription**
   - Wrap Piper/Whisper in async jobs, add editor toggles, demo scenes with speech I/O.

5. **Scaling & Tooling**
   - Add performance instrumentation, batching controls, and expand editor tabs (Memory, Graph, Settings).

---
## Open Questions

- Do we rely solely on SQLite, or embed a specialised graph toolkit?
- `whisper.cpp` vs. `faster-whisper` for best cross-platform performance?
- Ship Piper/Whisper binaries or guide users to build locally?
- Autoload design: keep a single runtime autoload or allow per-scene overrides?
- Automated test strategy for native bindings and GDS integration.

---
## Immediate Next Steps

1. Mark all editor-facing scripts (`LocalAgentsEditorPlugin.gd`, panel controllers, Chat/Download scripts) with `@tool` and verify the bottom panel loads without play mode.
2. Connect Download tab buttons to llama.cpp’s download routine via the runtime helper; provide progress + error messages.
3. Prototype MemoryGraph schema and storage adapter.
4. Restore the 3D agent demo scene using the new runtime pipeline.
5. Update documentation/screenshots to reflect the new editor workflow.

This division clarifies ownership so multiple specialised agents can ship features in parallel while we converge on full GDScript/GDExtension parity with the original project.
