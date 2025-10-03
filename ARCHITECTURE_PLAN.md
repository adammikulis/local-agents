# Local Agents Native Architecture Plan

This document outlines the refactor required to ship Local Agents as a fully native (GDExtension) Godot addon with reusable download/build tooling, shared inference backends, and scalable agent orchestration. It breaks the work into themed tracks so we can parallelize across contributors or automations.

---
## 1. Native Runtime Foundation

**Goal:** provide a reusable C++ layer that exposes Godot-facing nodes for inference, speech, and memory without any C# dependencies.

### 1.1 Runtime Layout
- `addons/local_agents/gdextensions/localagents/`
  - `include/` headers for the Godot bindings (`AgentNode.hpp`, future helpers).
  - `src/` implementation files (currently `AgentRuntime.cpp`, `AgentNode.cpp`, `LocalAgentsRegister.cpp`).
  - `thirdparty/` vendored sources (`godot-cpp`, `llama.cpp`, `whisper.cpp`, `fast-whisper`, `sqlite`, potential graph libs).
  - `models/`, `voices/` (ignored by git, populated by downloader).
  - `bin/` platform builds (`*.so/.dll/.dylib`).
- Provide `scripts/fetch_dependencies.sh` to shallow-clone third-parties, download default models, Piper voices.
- Provide `scripts/build_extension.sh` to configure and build the shared library with CMake.

### 1.2 Singleton Inference Manager
- New `AgentRuntime` singleton node (autoload) responsible for:
  - Loading a single llama.cpp model (Qwen3-4B by default) once per project.
  - Exposing thread-safe request API for `AgentNode` instances (fan-in/fan-out queue).
  - Managing shared resources: tokenizer, kv-cache pooling, sampler configs.
  - Owning references to Whisper/Piper executables.
- Agents no longer keep their own llama contexts; they submit prompts to `AgentRuntime` along with conversation fragments.
- Provide GDScript-friendly wrapper to access runtime (e.g. `LocalAgentsRuntime.gd` autoload using `AgentRuntime`).

### 1.3 Agent Node Responsibilities
- Keep per-agent metadata: IDs, voice preference, graph DB shard refs, conversation history pointer.
- Prepare inference payloads (recent message window + retrieved memory snippets).
- Call into runtime queue; emit `message_emitted` signal on completion.
- Maintain placeholders for future function-calling / tool invocation results.
- Provide JSON-mode inference option (e.g. `llama_sampler_params` with grammar), ensuring design leaves room for function signature registry.

### 1.4 Additional Native Components
- **MemoryGraph** wrapper around SQLite:
  - Vendored sqlite3; expose methods to read/write nodes, edges, embeddings.
  - Provide high-level API (`store_memory`, `query_memories`, `attach_embedding`).
  - Consider bundling a lightweight graph library if available (e.g. `ogdf` is heavy; prefer simple adjacency via SQLite + FTS/JSON1).
- **Embedding Worker** using `fastembed` or llama.cpp embeddings for scoring.
- **Speech**: integrate Piper invocation more robustly; design async audio generation queue.
- **Transcription**: vendor faster whisper (fast-whisper C++ or whisper.cpp). Provide streaming option down the line.


---
## 2. Dependency & Build Management

### 2.1 Vendored Projects
- Extend `fetch_dependencies.sh` to grab:
  - `whisper.cpp` (or replace with `faster-whisper` C++ if preferred).
  - SQLite amalgamation (`sqlite-amalgamation-X` from https://www.sqlite.org/amalgamation.html).
  - Investigate suitable lightweight C++ graph library (optional; otherwise leverage SQLite graph schema).
- Manage pinned commits (lock file) to ensure deterministic builds.
- Add hash verification for downloaded models/voices (SHA256).

### 2.2 CMake Integration
- Update `CMakeLists.txt` to build static libs for sqlite, whisper, optional graph.
- Provide build options (`LOCAL_AGENTS_ENABLE_WHISPER`, `LOCAL_AGENTS_ENABLE_PIPER`) for platforms lacking toolchains.
- Ensure position-independent builds for dynamic linking.
- Generate export wrappers for Godot (register classes, singletons).

### 2.3 CI & Tooling
- Add `scripts/build_all.sh` to produce macOS/Linux/Windows binaries (cross compilation later).
- Provide `scripts/test_extension.sh` hooking into Godot headless test scenes (future).
- Document environment prerequisites (cmake, ninja, clang/gcc, bash-compatible shell).


---
## 3. Memory & Graph System

### 3.1 Graph Schema
- Table layout in SQLite (single file per project or per agent cluster):
  - `memories(id INTEGER PRIMARY KEY, agent_id TEXT, created_at REAL, content TEXT, embedding BLOB, tags TEXT)`
  - `edges(from_id INTEGER, to_id INTEGER, weight REAL, relation TEXT)`
  - `chunks` / `episodes` for hierarchical recall.
  - Indices on `agent_id`, `created_at`, `tags` (JSON1), with `FTS5` virtual table for semantic search fallback.

### 3.2 Embedding Workflow
- Use llama.cpp embedding mode or integrate separate embedding model (download via downloader).
- `AgentNode` or `AgentRuntime` triggers embedding on new memories; persists vector in SQLite.
- Query pipeline: gather recent messages + top-N similar memories (cosine similarity) + action cues.

### 3.3 API Surface
- Expose GDScript methods to manage graph:
  - `AgentRuntime.store_memory(agent_id, text, metadata)`
  - `AgentRuntime.recall(agent_id, query_text, limit)` returning ordered dict of memory snippets.
  - Provide streaming variant for large recall sets.
- Include JSON struct output for compatibility with future function calling.


---
## 4. Downloader & Model Assets

### 4.1 Download Manager Node
- Create `DownloadManager` scene/node to surface downloads inside Godot editor.
- Mirror CLI helper instructions (shell script) inside the editor so users can run downloads externally; add optional progress integration via async jobs once we have a native downloader.
- Provide CLI interface (`./scripts/fetch_dependencies.sh --skip-voices`, etc.).

### 4.2 Default Assets
- Bundle metadata files for shipped defaults:
  - `models/config.json` describing installed models (name, size, quantization, hash).
  - `voices/config.json` listing Piper voices + sample rate.
- Provide environment variable overrides to point at custom asset directories (for large deployments).

### 4.3 Future Expansion
- Plan for adding LoRA/adapter downloads.
- Hook into scenario-specific asset packs (graph seeds).


---
## 5. Roadmap & Milestones

1. **Bootstrapping (now)**
   - Finalize C++ scaffold, register `AgentRuntime` singleton, migrate `AgentNode` to queue-based inference.
   - Vendored dependencies: llama.cpp, whisper.cpp, sqlite.
   - Update build scripts and documentation.

2. **Memory Integration**
   - Implement SQLite-backed graph store with embedding recall.
   - Provide GDScript UI hooks for browsing memories.

3. **Speech & Transcription**
   - Wire Piper + Whisper into async pipeline with caching and queueing.
   - Provide sample scene demonstrating speech loop.

4. **Scalability Enhancements**
   - Thread pool / batching for inference (BatchedExecutor-like).
   - Async job system for memory retrieval and embedding.

5. **Function Calling & Tool Use (future)**
   - Extend `AgentNode` API to register callable signatures.
   - Provide JSON schema enforcement via llama.cpp grammar support.

---
## 6. Open Questions

- **Graph library**: do we rely solely on SQLite or embed a specialized C++ graph toolkit? (Evaluate `lemon`, `boost::graph`, or implement custom adjacency queries.)
- **Fast Whisper choice**: integrate `faster-whisper` C++ vs. `whisper.cpp` for simplicity/perf.
- **Cross-platform audio pipeline**: ship Piper binaries or require users to build? Consider shipping optional prebuilt archives.
- **Model selection UI**: autoload node vs. editor dock? We likely need both (runtime autoload + editor panel for downloads/settings).
- **Testing**: design headless tests for inference and graph retrieval once runtime is stable.

---
## 7. Immediate Next Steps (Implementation Order)
1. Harden `AgentRuntime` singleton (job queue, batching, JSON grammar support) now that the basic shared context is in place.
2. Build SQLite-backed memory graph module and wire it into the runtime for recall APIs.
3. Extend downloader tooling (`fetch_dependencies.sh`) to pin commit hashes and provide checksum verification; consider native Godot download worker.
4. Update CMake to optionally build whisper/sqlite static libraries and expose embeddings interface.
5. Add editor UI panels for runtime configuration, download management, and memory graph inspection.

This plan should keep the project focused as we migrate off the legacy Doctor-Robot setup and deliver a self-contained, scalable Local Agents release.
