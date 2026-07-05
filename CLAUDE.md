# CLAUDE.md

**`AGENTS.md` is the single source of truth for process in this repo — read it first.** It is the
canonical, enforceable process doc and applies to every agent (including Claude Code). `GODOT_BEST_PRACTICES.md`
is its companion for Godot/GDScript specifics. To avoid drift, process rules live ONLY in those files, not
here — do not duplicate them into this file.

This file exists only for Claude-Code-specific notes. There are currently none beyond the orientation below.

## Orientation (not process rules — those are in AGENTS.md)

- **Main scene / active work:** `addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn` — a
  from-scratch godot_voxel ecosystem sim. Current state, architecture, pending work, and the exact
  run/verify commands for it are in **`TODO.md`**. The guiding design principle is **emergent-everything**
  (see AGENTS.md → "Guiding Design Principle" and `.../voxel/EMERGENCE.md`).
- **Godot 4.7**, `godot` on PATH. Test/observe via `scripts/agent_harness.sh <command>` (see
  GODOT_BEST_PRACTICES.md → "Headless Harness Invocation" for the canonical list and output markers).
