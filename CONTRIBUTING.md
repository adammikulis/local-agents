# Local Agents Contributing Guide

Thanks for checking out Local Agents! This addon wraps the Doctor-Robot native agent runtime for Godot and provides GDScript demos you can build on.

## ⚑ Read these first — the canonical rules (humans AND AI agents)

Before contributing to the simulation, read **[`CLAUDE.md`](CLAUDE.md)** (the enforceable process + architecture
doc) and its companion **[`GODOT_BEST_PRACTICES.md`](GODOT_BEST_PRACTICES.md)** (Godot-specific design/runtime/
validation rules). They are checked into the repo on purpose and apply to *everyone* — they encode how this
project is built: emergent-everything / dissolve-don't-patch (a chemistry substrate of conserved substances +
data-driven reactions; named phenomena have zero dedicated code), GPU/native-first, perf- and parallelizability-
first refactoring (the composition-root hubs `VoxelWorld`/`MaterialField3D` are extract-only), iterate-fast, and
the worktree workflow. `AGENTS.md` points here too. If you change behaviour or commands, update `README`,
`GODOT_BEST_PRACTICES.md`, and record breaking changes in `ARCHITECTURE_PLAN.md`.

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
