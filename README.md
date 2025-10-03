Local Agents is a Godot addon that exposes a native `AgentNode` (GDExtension) for offline agents. It ships with lightweight GDScript wrappers, configuration panels, demo scenes, and a native runtime backed by [`llama.cpp`](https://github.com/ggerganov/llama.cpp), [`whisper.cpp`](https://github.com/ggerganov/whisper.cpp), and [`piper`](https://github.com/rhasspy/piper).

# Highlights
- Drop the addon into any Godot 4 project and get an `Agent` node with chat history, action queues, and graph memory helpers.
- Configure the native backend via the included Model/Inference panels (set graph DB path, tick cadence, sampling knobs).
- Sample UIs (`ChatExample.tscn`, `Agent3D.tscn`, `GraphExample.tscn`) that show how to drive characters, wire chat inputs, and inspect graph heuristics.
- Ships with automation to fetch/build the native runtime and default models (Qwen3-4B-Instruct-2507 + Piper English voices).

# Getting Started

1. Fetch third-party libraries and the default models:
   ```bash
   cd addons/local_agents/gdextensions/localagents
   ./scripts/fetch_dependencies.sh
   ```
   This downloads shallow clones of `godot-cpp`, `llama.cpp`, `whisper.cpp`, the SQLite amalgamation, plus the default Qwen3-4B-Instruct-2507 GGUF and two English Piper voices.
2. Build the native GDExtension:
   ```bash
   ./scripts/build_extension.sh
   ```
   Binaries are emitted into `addons/local_agents/gdextensions/localagents/bin/` and picked up automatically when you enable the plugin.
3. Copy the `addons/local_agents` folder into your Godot project and enable the plugin (Project Settings → Plugins → Local Agents).
4. Ensure the autoload `AgentManager` is active; it spins up a singleton agent and keeps configs in `res://addons/local_agents/configuration/parameters/`.
5. Open any of the demo scenes under `addons/local_agents/examples/` to see the GDExtension in action.

# Download Manager
The configuration panel now exposes a Download Manager that can fetch additional models or voices. Under the hood it drives the Python helper in `addons/local_agents/gdextensions/localagents/scripts/fetch_dependencies.py`, so you can extend it with your own mirrors if needed.

# Architecture
The autoload `AgentManager` manages shared configuration (`LocalAgentsConfigList`) and pushes updates into whichever `Agent` nodes register with it. Each `Agent` wraps the native `AgentNode`, forwards graph queries (`memory_*`), and surfaces helper signals for chat output and action requests. The UI controllers are pure GDScript and can be dropped into other scenes or extended as needed.

# Version History
- 0.3-dev (GDExtension rewrite): switched entirely to GDScript + native AgentNode, removed LLaMASharp dependency, refreshed demos.
- 0.3.0-beta: vendored llama.cpp/whisper.cpp/piper runtimes, bundled downloader, defaulted to Qwen3-4B-Instruct-2507.

# Links
- Godot Asset Library listing (historic): https://godotengine.org/asset-library/asset/3025
- Backdrop Build v4 mini-accelerator feature: https://backdropbuild.com/builds/v4/mind-game
