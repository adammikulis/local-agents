Local Agents is a Godot addon that exposes a native `AgentNode` (GDExtension) for offline agents. It ships with lightweight GDScript wrappers, configuration panels, demo scenes, and a native runtime backed by [`llama.cpp`](https://github.com/ggerganov/llama.cpp), [`whisper.cpp`](https://github.com/ggerganov/whisper.cpp), and [`piper`](https://github.com/rhasspy/piper).

# Highlights
- Drop the addon into any Godot 4 project and get an `Agent` node with chat history, action queues, and graph memory helpers.
- Configure the native backend via the included Model/Inference panels (set graph DB path, tick cadence, sampling knobs).
- Sample UIs (`ChatExample.tscn`, `Agent3D.tscn`, `GraphExample.tscn`) that show how to drive characters, wire chat inputs, and inspect graph heuristics.
- Ships with automation to fetch/build the native runtime and default models (Qwen3-4B-Instruct-2507 Q4_K_M + Piper English voices).

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
3. Stage the speech/transcription runtimes (Piper + Whisper) for your platform:
   ```bash
   ./scripts/fetch_runtimes.sh
   ```
   Add `--all` to download every supported Piper bundle (macOS, Linux, Windows). Run the script on each target OS if you need native `whisper` binaries there. Assets are copied into `addons/local_agents/gdextensions/localagents/bin/runtimes/<platform>/` so export templates can bundle them directly.
4. Copy the `addons/local_agents` folder into your Godot project and enable the plugin (Project Settings → Plugins → Local Agents).
5. Ensure the autoload `AgentManager` is active; it spins up a singleton agent and keeps configs in `res://addons/local_agents/configuration/parameters/`.
6. Open any of the demo scenes under `addons/local_agents/examples/` to see the GDExtension in action.

### Speech Output (Piper)
- Download voices with `addons/local_agents/gdextensions/localagents/scripts/fetch_dependencies.sh` (runs automatically in step 1) or add your own `.onnx` voices under `addons/local_agents/voices/`.
- Open the **Model Configuration** window, set `Voice (ID or path)` to either a relative voice folder (for example `en_US-ryan/en_US-ryan-high.onnx`) or an absolute path, and toggle **Enable Piper TTS** when you want replies to speak aloud.
- Generated audio is stored under `user://local_agents/tts/` and played back via an `AudioStreamPlayer` on the agent.

# Download Manager
The editor Download tab now lists the latest Qwen3 GGUF drops by family and parameter size, using metadata from `addons/local_agents/models/catalog.json`. Pick a row and press **Download Selected** to stream that model via llama.cpp's downloader (libcurl); the default is Qwen3-4B-Instruct-2507 (Q4_K_M). Voice downloads and cleanup still reuse `scripts/fetch_dependencies.sh` so you get the same CLI behaviour inside the editor. Update `ModelDownloadService.gd` or the catalog if you want to add mirrors, headers, or extra models.

# Graph Memory & Embeddings
- Every runtime now mounts a persistent SQLite database at `user://local_agents/network.sqlite3` powered by the `NetworkGraph` GDExtension. Nodes, edges, and embeddings are stored in dedicated tables with JSON metadata for fast filtering.
- Conversation history automatically flows into the database through `LocalAgentsConversationStore`. Messages are linked to their conversation nodes, sequence edges are maintained, and—when a llama.cpp model is loaded—message content is embedded for ANN recall.
- `AgentRuntime` exposes `embed_text(text, options := {})` so GDScript can request normalized embedding vectors directly from the loaded llama.cpp model. The method reuses the existing context and supports editor/runtime usage.
- `NetworkGraph.search_embeddings()` performs logarithmic-time ANN lookup via an in-memory vantage-point index rebuilt on demand. You can call `LocalAgentsConversationStore.search_messages("query", top_k)` to retrieve the most similar chat messages, or use the `ProjectGraphService` helper described below for code snippets.
- The optional `addons/local_agents/graph/ProjectGraphService.gd` scans source folders, maps directory → file relationships as graph edges, and stores embeddings for each file chunk. This lays the groundwork for project-aware assistance and cross-referencing between code and conversation memories.

## Testing
Headless scripts cover the data layer, agent utilities, integration points, and optional runtime smoke tests. After building the GDExtension you can run everything with:

```bash
scripts/run_tests.sh
```

Set `GODOT_BIN` if your Godot 4 binary is not on `PATH`. The helper iterates through:

```bash
godot --headless -s addons/local_agents/tests/test_smoke_agent.gd
godot --headless -s addons/local_agents/tests/test_agent_utilities.gd
godot --headless -s addons/local_agents/tests/test_agent_integration.gd
godot --headless -s addons/local_agents/tests/test_conversation_store.gd
godot --headless -s addons/local_agents/tests/test_project_graph_service.gd
godot --headless -s addons/local_agents/tests/test_network_graph.gd
godot --headless -s addons/local_agents/tests/test_agent_e2e.gd
godot --headless -s addons/local_agents/tests/test_agent_runtime_heavy.gd
```

The smoke/unit/integration/e2e suites rely on lightweight mock runtimes for embeddings, so no GGUF models are required. The heavy runtime script is skipped unless you export `LOCAL_AGENTS_TEST_GGUF` to point at a small llama.cpp-compatible model, in which case it attempts a real load + inference cycle. All tests create and clean up temporary data under `user://local_agents`. Before running the suites the helper calls `scripts/run_godot_check.sh` to ensure all plugin scripts parse.

## Editor Check
Before opening Godot (or after tweaking any `.gd` scripts), run the quick headless validation to catch parse/type issues and plugin wiring errors:

```bash
scripts/run_godot_check.sh
```

Set `GODOT_CHECK_ARGS="--path /alternate/project"` if you need to target a different project file. The helper simply wraps `godot --headless --check-only project.godot`, mirroring what CI will use once it’s wired up.

# Architecture
The autoload `AgentManager` manages shared configuration (`LocalAgentsConfigList`) and pushes updates into whichever `Agent` nodes register with it. Each `Agent` wraps the native `AgentNode`, forwards graph queries (`memory_*`), and surfaces helper signals for chat output and action requests. The UI controllers are pure GDScript and can be dropped into other scenes or extended as needed.

# Version History
- 0.3-dev (GDExtension rewrite): switched entirely to GDScript + native AgentNode, removed LLaMASharp dependency, refreshed demos.
- 0.3.0-beta: vendored llama.cpp/whisper.cpp/piper runtimes, bundled downloader, defaulted to Qwen3-4B-Instruct-2507.

# Links
- Godot Asset Library listing (historic): https://godotengine.org/asset-library/asset/3025
- Backdrop Build v4 mini-accelerator feature: https://backdropbuild.com/builds/v4/mind-game
