# Local Agents Contributing Guide

Thanks for checking out Local Agents! It is two things at once: a reusable Godot addon for running
local LLMs in-engine (the `LocalAgent` node and friends), and the flagship game that demonstrates
it — a cubed-sphere planet whose creatures and streamer are driven by those models, fully offline.

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
- Keep the Godot integration lightweight: GDScript glue plus the `localagents` GDExtension only.
- Showcase agentic behaviours (graph memory, action queues) that games can re-use.
- Stay friendly to offline workflows — no cloud dependencies required.

## How to Help
1. Build the native extension and run the demos to verify changes:
   ```bash
   cd addons/local_agents/gdextensions/localagents
   ./scripts/fetch_dependencies.sh
   ./scripts/build_extension.sh --platform macos    # or: linux | windows
   ```
   Prebuilt binaries also come off the `build-extension.yml` workflow as
   `localagents-<platform>-bin`; unzip into `addons/local_agents/gdextensions/localagents/bin/`.
2. File issues or PRs that improve the GDScript layer, docs, or demo scenes.
3. When adding new features, keep everything GDScript or native — no .NET/C# layers.
4. Do non-trivial work in a git worktree off the current dev branch, not the shared checkout:
   `scripts/new_worktree.sh feature/<name>` sets one up ready to build (it symlinks the compiled
   `bin/` and imports the `.glsl` kernels, without which the GPU field is silently dead).

## Testing
Run the gates rather than opening scenes by hand — CI runs the same `lint` command:

```bash
scripts/agent_harness.sh lint       # all eight gates, ~40s (file length, typing, @tool safety, …)
scripts/agent_harness.sh fast       # deterministic + integration suites
scripts/run_demo.sh <Demo>          # any examples/*.tscn, headless, ~1s each
```

The planet itself needs a real window, because the GPU field has no compute device headless. Run it
off-screen so it never steals focus:

```bash
scripts/run_sim_offscreen.sh --path . --fixed-fps 60 \
  addons/local_agents/game/VoxelWorld.tscn -- --run-frames=600 --seed=4242
```

It prints one `SIM_REPORT={…}` line. Two things to know before you compare any two runs: pass
`--fixed-fps 60` (before the `--`) or the field numbers do not reproduce, and quote the
`phenomenon` / `phenomenon/impact` / `phenomenon/eruption` counts alongside any scalar — ambient
disasters draw from Godot's global RNG, so two runs at the same seed can differ several-fold and
temperature tracks that draw.

If you tweak the GDExtension build, rebuild the binaries for each target platform you need.

Happy hacking!
