# Local Agents Contributing Guide

Thanks for checking out Local Agents! This addon wraps the Doctor-Robot native agent runtime for Godot and provides GDScript demos you can build on.

## Goals
- Keep the Godot integration lightweight: GDScript glue + the `AgentNode` GDExtension only.
- Showcase agentic behaviours (graph memory, action queues) that games can re-use.
- Stay friendly to offline workflows—no cloud dependencies required.

## How to Help
1. Build the native extension (`doctor-robot-godot/gdextensions/localagents`) and run the sample scenes to verify changes.
2. File issues or PRs that improve the GDScript layer, docs, or demo scenes.
3. When adding new features, keep everything GDScript or native—no .NET/C# layers.

## Testing
- Load the `ChatExample.tscn` scene and confirm the agent echoes back prompts and emits actions.
- Open `GraphExample.tscn` to ensure graph heuristics still execute.
- If you tweak the GDExtension build, rebuild the binaries for each target platform you need.

Happy hacking!
