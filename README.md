# Local Agents

Local Agents is a Godot addon backed by a native GDExtension runtime for running llama.cpp style language agents entirely offline. Everything ships as C++ and GDScript: there is no Python tooling in this branch, keeping the plugin focused on editor/runtime workflows and the native downloader pipeline.

## Highlights

- Native `AgentNode` (GDExtension) with queue-backed inference, graph memory helpers, and Piper/Whisper hooks.
- Editor plugin (`addons/local_agents/`) that exposes chat, download, and configuration panels while remaining `@tool` friendly.
- Reusable controllers/services for chat, conversation storage, and project graph helpers written in idiomatic GDScript.
- Shell helpers for fetching third-party dependencies, running headless editor checks, and executing the addon’s GDScript test suites.
- Demo scenes (`ChatExample.tscn`, `Agent3D.tscn`, `GraphExample.tscn`) that wire everything together without bundled art packs (bring your own textures or drop-in themes as needed).

## Quick Start

1. Enable the addon inside Godot:
   ```bash
   godot --path . --editor
   ```
   Then open Project Settings → Plugins and toggle **Local Agents**.
2. (Optional) Fetch third-party dependencies for the native runtime:
   ```bash
   cd addons/local_agents/gdextensions/localagents
   ./scripts/fetch_dependencies.sh
   ./scripts/build_extension.sh
   ```
3. Stage speech/transcription runtimes when you need Piper or Whisper:
   ```bash
   ./scripts/fetch_runtimes.sh --all
   ```
4. Open the editor bottom panel → **Local Agents** to configure model/inference settings and explore the Chat or Download tabs.
5. Run demo scenes under `addons/local_agents/examples/` to validate integration (`ChatExample.tscn`, `GraphExample.tscn`, or `Agent3D.tscn`).

## Tooling Scripts

- `scripts/fetch_runtimes.sh` – fetch optional Piper/Whisper bundles via the runtime downloader.
- `scripts/run_godot_check.sh` – run Godot parser checks in headless mode.
- `scripts/run_tests.sh` – execute the included GDScript smoke/unit/integration tests headlessly.

All scripts are POSIX shell friendly and avoid Python runtimes. Set `GODOT_BIN` or `GODOT4_BIN` if your editor binary is not on `PATH`.

## Testing

Headless GDScript suites live under `addons/local_agents/tests/`. Execute everything with:

```bash
scripts/run_tests.sh
```

`LOCAL_AGENTS_TEST_GGUF` can point at a small llama.cpp GGUF artifact when you want the heavier runtime test to perform a real load; otherwise it skips gracefully.

## Assets

Earlier releases bundled large cursor/icon/logo packs. Those files were removed to keep the repository lean; reference replacements from your own project if a scene references missing textures. The sample scenes and controllers now prefer plain text/buttons by default.

## Architecture Notes

- `addons/local_agents/gdextensions/localagents/` holds the native runtime (C++ headers, sources, and helper scripts).
- `addons/local_agents/agent_manager/` and `addons/local_agents/controllers/` contain the editor/runtime singletons and UI mediators.
- `addons/local_agents/graph/` implements the NetworkGraph helpers and Tree-sitter style services for project exploration.
- `ARCHITECTURE_PLAN.md` documents the multi-agent stewardship expectations for this branch.

For historical notes, see `docs/NETWORK_GRAPH.md` and comments in the GDScript controllers. Contributions should stick to C++ or GDScript and avoid reintroducing Python unless the plan doc has been updated in advance.
