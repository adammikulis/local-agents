# CLAUDE.md

**`AGENTS.md` is the single source of truth for process in this repo — read it first.** It is the
canonical, enforceable process doc and applies to every agent (including Claude Code). `GODOT_BEST_PRACTICES.md`
is its companion for Godot/GDScript specifics. To avoid drift, process rules live ONLY in those files, not
here — do not duplicate them into this file.

This file exists only for Claude-Code-specific notes.

## Destructive-command safety (bulk delete/find)

Do **not** delete files with `find ... -name <dir> -exec rm -rf` or a bare recursive `rm` that walks
`scenes/simulation/`. The live `voxel/` subtree has `actors/`, `ui/`, and `shaders/` subdirectories
whose **names collide** with the old-stack siblings, so a name-based `find` silently matches the new
scene too (this already nuked `voxel/{actors,ui,shaders}` once — recovered only because it was committed).

When removing files:
- Prefer **explicit paths** or `git rm <path>` (it refuses to touch untracked files and stages the delete for review).
- If you must `find`, scope it: anchor with `-path '.../scenes/simulation/actors'` (full path, not `-name`),
  or add `-maxdepth 1`, and never combine `-name` with `-exec rm`/`-delete` over a shared parent.
- Commit before any bulk delete so a mistake is one `git checkout` away.

## Orientation (not process rules — those are in AGENTS.md)

- **Main scene / active work:** `addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn` — a
  from-scratch godot_voxel ecosystem sim. Current state, architecture, pending work, and the exact
  run/verify commands for it are in **`TODO.md`**. The guiding design principle is **emergent-everything**
  (see AGENTS.md → "Guiding Design Principle" and `.../voxel/EMERGENCE.md`).
- **Godot 4.7**, `godot` on PATH. Test/observe via `scripts/agent_harness.sh <command>` (see
  GODOT_BEST_PRACTICES.md → "Headless Harness Invocation" for the canonical list and output markers).
