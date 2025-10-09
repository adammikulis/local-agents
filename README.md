# Local Agents

Local Agents is a Godot addon backed by a native GDExtension runtime for running llama.cpp style language agents entirely offline. Everything ships as C++ and GDScript, keeping the plugin focused on editor/runtime workflows and the native downloader pipeline.

## Quick Demos

**Runtime chat loop (Qwen3 0.6B, offline agent response)**
![Local Agents chat demo](https://github.com/adammikulis/MindGame/assets/27887607/bb9da9c0-622d-4b6d-af08-40cf7f2bdba9)

**Editor configuration walkthrough (model setup + chat panel)**
![Local Agents configuration demo](https://github.com/adammikulis/MindGame/assets/27887607/3ecd86f9-cf92-473f-a667-76b62b7cfdb0)

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

## Tooling & Tests

- `scripts/fetch_runtimes.sh` – fetch optional Piper/Whisper bundles via the runtime downloader.
- `addons/local_agents/tests/run_all_tests.gd` – headless harness that runs the smoke/utility suites on every platform. Pass `--include-heavy` (or predefine `LOCAL_AGENTS_TEST_GGUF`) to opt into the runtime-heavy coverage, which uses the built-in download manager to fetch the 4-bit `ggml-org/Qwen3-0.6B-GGUF` model when it is not cached locally.

Run the cross-platform harness with:

```bash
godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd
```

By default the harness skips the heavy runtime pass and finishes in a few seconds. Adding `--include-heavy` triggers an end-to-end verification that will:

1. Use `LocalAgentsModelDownloadService` + `AgentRuntime.download_model()` (llama.cpp’s downloader) to pull `Qwen3-0.6B-Q4_K_M.gguf` into `user://local_agents/models/qwen3-0_6b-instruct/`.
2. Reuse any existing Hugging Face cache (e.g. `~/.cache/huggingface/hub/models--ggml-org--Qwen3-0.6B-GGUF`) before downloading.
3. Leave the model on disk so subsequent heavy runs are instant. The repo never tracks weights; the artifacts live under `user://` or your HF cache only.

These model-aware helpers also power the runtime heavy test (`test_agent_runtime_heavy.gd`), so optional end-to-end runs stay aligned with the same downloader that the editor UI uses. Additional GDScript scenarios (`test_conversation_store.gd`, `test_network_graph.gd`, etc.) remain available for manual runs once the native extension is built.

## Assets

Earlier releases bundled large cursor/icon/logo packs. Those files were removed to keep the repository lean; reference replacements from your own project if a scene references missing textures. The sample scenes and controllers now prefer plain text/buttons by default.

## Architecture Notes

- `addons/local_agents/gdextensions/localagents/` holds the native runtime (C++ headers, sources, and helper scripts).
- `addons/local_agents/agent_manager/` and `addons/local_agents/controllers/` contain the editor/runtime singletons and UI mediators.
- `addons/local_agents/graph/` implements the NetworkGraph helpers and Tree-sitter style services for project exploration.
- `ARCHITECTURE_PLAN.md` documents the multi-agent stewardship expectations for this branch.

For historical notes, see `docs/NETWORK_GRAPH.md` and comments in the GDScript controllers. Contributions should stick to C++ or GDScript, and update the plan doc before introducing additional toolchains.
