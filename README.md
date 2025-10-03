Local Agents is a Godot addon that exposes a native `AgentNode` (GDExtension) for offline agents. It ships with lightweight GDScript wrappers, configuration panels, demo scenes, and a native runtime backed by [`llama.cpp`](https://github.com/ggerganov/llama.cpp), [`whisper.cpp`](https://github.com/ggerganov/whisper.cpp), and [`piper`](https://github.com/rhasspy/piper).

# Highlights
- Drop the addon into any Godot 4 project and get an `Agent` node with chat history, action queues, and graph memory helpers.
- Configure the native backend via the included Model/Inference panels (set graph DB path, tick cadence, sampling knobs).
- Sample UIs (`ChatExample.tscn`, `Agent3D.tscn`, `GraphExample.tscn`) that show how to drive characters, wire chat inputs, and inspect graph heuristics.
- Ships with automation to fetch/build the native runtime and default models (Qwen2.5-3B-Instruct Q4_K_M + Piper English voices).

# Getting Started

1. Fetch third-party libraries and the default voices (models can also be installed from inside Godot):
   ```bash
   cd addons/local_agents/gdextensions/localagents
   ./scripts/fetch_dependencies.sh
   ```
   This downloads shallow clones of `godot-cpp`, `llama.cpp`, `whisper.cpp`, the SQLite amalgamation, plus two English Piper voices. Pass `--skip-voices` if you only need the libraries.
2. Build the native GDExtension:
   ```bash
   ./scripts/build_extension.sh
   ```
   Binaries are emitted into `addons/local_agents/gdextensions/localagents/bin/` and picked up automatically when you enable the plugin.
3. Copy the `addons/local_agents` folder into your Godot project and enable the plugin (Project Settings → Plugins → Local Agents).
4. Ensure the autoload `AgentManager` is active; it spins up a singleton agent and keeps configs in `res://addons/local_agents/configuration/parameters/`.
5. Open any of the demo scenes under `addons/local_agents/examples/` to see the GDExtension in action.

# Download Manager
The editor Download tab uses the native `AgentRuntime.download_model()` binding to stream GGUF models via llama.cpp's downloader (libcurl). When you press **Download Models** it saves Qwen2.5-3B-Instruct (Q4_K_M) into `res://addons/local_agents/models/` and shows progress directly in the panel. Voice downloads and cleanup still reuse `scripts/fetch_dependencies.sh` so you get the same CLI behaviour inside the editor. Update `ModelDownloadService.gd` if you want to add mirrors, headers, or extra models.

# Graph Memory & Embeddings
- Every runtime now mounts a persistent SQLite database at `user://local_agents/network.sqlite3` powered by the `NetworkGraph` GDExtension. Nodes, edges, and embeddings are stored in dedicated tables with JSON metadata for fast filtering.
- Conversation history automatically flows into the database through `LocalAgentsConversationStore`. Messages are linked to their conversation nodes, sequence edges are maintained, and—when a llama.cpp model is loaded—message content is embedded for ANN recall.
- `AgentRuntime` exposes `embed_text(text, options := {})` so GDScript can request normalized embedding vectors directly from the loaded llama.cpp model. The method reuses the existing context and supports editor/runtime usage.
- `NetworkGraph.search_embeddings()` performs logarithmic-time ANN lookup via an in-memory vantage-point index rebuilt on demand. You can call `LocalAgentsConversationStore.search_messages("query", top_k)` to retrieve the most similar chat messages, or use the `ProjectGraphService` helper described below for code snippets.
- The optional `addons/local_agents/graph/ProjectGraphService.gd` scans source folders, maps directory → file relationships as graph edges, and stores embeddings for each file chunk. This lays the groundwork for project-aware assistance and cross-referencing between code and conversation memories.

## Testing
Headless scripts cover the new data layer and helper services. After building the GDExtension you can run everything with:

```bash
scripts/run_tests.sh
```

Set `GODOT_BIN` if your Godot 4 binary is not on `PATH`. The helper iterates through:

```bash
godot --headless -s addons/local_agents/tests/test_network_graph.gd
godot --headless -s addons/local_agents/tests/test_conversation_store.gd
godot --headless -s addons/local_agents/tests/test_project_graph_service.gd
```

The tests use lightweight mock runtimes for embeddings, so no GGUF models are required. They create and clean up temporary data under `user://local_agents`.

# Architecture
The autoload `AgentManager` manages shared configuration (`LocalAgentsConfigList`) and pushes updates into whichever `Agent` nodes register with it. Each `Agent` wraps the native `AgentNode`, forwards graph queries (`memory_*`), and surfaces helper signals for chat output and action requests. The UI controllers are pure GDScript and can be dropped into other scenes or extended as needed.

# Version History
- 0.3-dev (GDExtension rewrite): switched entirely to GDScript + native AgentNode, removed LLaMASharp dependency, refreshed demos.
- 0.3.0-beta: vendored llama.cpp/whisper.cpp/piper runtimes, bundled downloader, defaulted to Qwen3-4B-Instruct-2507.

# Links
- Godot Asset Library listing (historic): https://godotengine.org/asset-library/asset/3025
- Backdrop Build v4 mini-accelerator feature: https://backdropbuild.com/builds/v4/mind-game
