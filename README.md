# Local Agents

Local Agents ships a Godot 4 addon plus companion Python helpers for running local llama.cpp models without cloud dependencies. The repository now blends the latest `main` tooling updates with the mature `0.3-dev` GDExtension runtime while trimming legacy art packs and demo assets.

## What’s inside

- **GDExtension runtime (`addons/local_agents/`)**: native `AgentNode`, async job queues, graph-backed memory services, editor panels, and CLI download bridges. Scenes and controllers remain, but large cursor/icon/logo packs were removed to keep the history lean—feel free to restore your own assets under `addons/local_agents/assets/` if needed.
- **Godot editor plugin**: enable `Local Agents` in Project Settings to surface the Chat, Download, and Configuration tabs. Autoloads (`LocalAgentsEditorPlugin`, `AgentManager`, `LocalAgentManagerNode`) expose tooling in both editor and runtime.
- **Python + llama.cpp helpers (`scripts/`, `local_agents/`)**: command line download/inference helpers, packaged llama.cpp catalog, reusable download API, and pytest coverage for Qwen3-0.6B-Instruct.
- **Automation**: scripts for fetching/building native deps, running headless Godot checks, and executing the full test suite.

## Quick start (Python tooling)

1. Install Python dependencies:
   ```bash
   pip install -e .
   ```
2. Download and run a quick llama.cpp prompt (downloads into `.models/` by default):
   ```bash
   python scripts/run_inference.py --download --prompt "Say hi in one short sentence."
   ```
3. Explore the packaged catalog:
   ```python
   from local_agents import list_llama_cpp_model_families
   print(list_llama_cpp_model_families())
   ```

## Quick start (Godot addon)

1. Open `project.godot` in Godot 4.3 and enable the **Local Agents** plugin.
2. Set the `LocalAgentManager` autoload `model_path` to your `.gguf` file (for example `res://.models/Qwen3-0.6B-Instruct-Q4_K_M.gguf`).
3. Use the editor Download tab (`addons/local_agents/editor/DownloadTab.tscn`) to stream GGUF artifacts via the bundled llama.cpp downloader, or run `scripts/download_llama_cpp_model.py` from the CLI.
4. Load `addons/local_agents/examples/chat_example.tscn` or `GraphExample.tscn` to poke at the chat and memory UX. Scenes no longer depend on the trimmed cursor/icon packs; wire up your own art or reuse standard Godot themes as desired.

## Native runtime helpers

- Build the GDExtension binaries:
  ```bash
  cd addons/local_agents/gdextensions/localagents
  ./scripts/fetch_dependencies.sh
  ./scripts/build_extension.sh
  ```
- Optional speech/transcription runtimes:
  ```bash
  ./scripts/fetch_runtimes.sh --all
  ```
- Graph + conversation services live under `addons/local_agents/graph/` and `addons/local_agents/controllers/` and are designed for `@tool` usage in editor panels.

## Testing and validation

- Godot parser + smoke checks:
  ```bash
  scripts/run_godot_check.sh
  scripts/run_tests.sh
  ```
- Python integration test (downloads Qwen3-0.6B-Instruct on first run):
  ```bash
  pytest -k qwen3
  ```

## Notes

- Assets removed from `addons/local_agents/assets/` to honor the current repository size target; add replacements locally if your scenes expect them.
- Environment overrides: `LOCAL_AGENTS_MODEL_DIR` to relocate the `.models/` cache, `LOCAL_AGENTS_PYTHON` to control the binary invoked from Godot.
- See `ARCHITECTURE_PLAN.md` for agent charters and `docs/NETWORK_GRAPH.md` for the graph schema and helper APIs.
