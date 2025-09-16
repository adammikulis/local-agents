Local Agents is a Godot addon that exposes a native `AgentNode` (GDExtension) for offline agents. It ships with lightweight GDScript wrappers, configuration panels, and demo scenes for chat- and graph-driven gameplay.

# Highlights
- Drop the addon into any Godot 4 project and get an `Agent` node with chat history, action queues, and graph memory helpers.
- Configure the native backend via the included Model/Inference panels (set graph DB path, tick cadence, sampling knobs).
- Sample UIs (`ChatExample.tscn`, `Agent3D.tscn`, `GraphExample.tscn`) that show how to drive characters, wire chat inputs, and inspect graph heuristics.

# Getting Started

1. Build the `localagents` GDExtension from the Doctor-Robot repo (`doctor-robot-godot/gdextensions/localagents`). Copy the produced binaries into `addons/local_agents/gdextensions/localagents/bin/` (or keep the projects side-by-side and use the shipped files). When building, point `GODOT_CPP_DIR` at your `godot-cpp` checkout (Doctor-Robot keeps it under `extern/godot-cpp`).
2. Copy the `addons/local_agents` folder into your Godot project and enable the plugin (Project Settings → Plugins → Local Agents).
3. Ensure the autoload `AgentManager` is active; it spins up a singleton agent and keeps configs in `res://addons/local_agents/configuration/parameters/`.
4. Open any of the demo scenes under `addons/local_agents/examples/` to see the GDExtension in action.

# Architecture
The autoload `AgentManager` manages shared configuration (`LocalAgentsConfigList`) and pushes updates into whichever `Agent` nodes register with it. Each `Agent` wraps the native `AgentNode`, forwards graph queries (`memory_*`), and surfaces helper signals for chat output and action requests. The UI controllers are pure GDScript and can be dropped into other scenes or extended as needed.

# Version History
- 0.3-dev (GDExtension rewrite): switched entirely to GDScript + native AgentNode, removed LLaMASharp dependency, refreshed demos.

# Links
- Godot Asset Library listing (historic): https://godotengine.org/asset-library/asset/3025
- Backdrop Build v4 mini-accelerator feature: https://backdropbuild.com/builds/v4/mind-game
