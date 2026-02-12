# Local Agents

Local Agents is a Godot addon backed by a native GDExtension runtime for running llama.cpp style language agents entirely offline. Everything ships as C++ and GDScript, keeping the plugin focused on editor/runtime workflows and the native downloader pipeline.

## Quick Demos

**Runtime chat loop (locally-run LLM response)**
![Local Agents chat demo](https://github.com/adammikulis/MindGame/assets/27887607/bb9da9c0-622d-4b6d-af08-40cf7f2bdba9)

**Editor configuration walkthrough (locally-run LLM setup)**
![Local Agents configuration demo](https://github.com/adammikulis/MindGame/assets/27887607/3ecd86f9-cf92-473f-a667-76b62b7cfdb0)

## Highlights

- Native `AgentNode` (GDExtension) with queue-backed inference, graph memory helpers, and Piper/Whisper hooks backed by the new runtime speech helpers.
- Threaded `LocalAgentsSpeechService` + `AgentRuntime.synthesize_speech` / `transcribe_audio` pipeline that streams Piper input and parses Whisper JSON off the main thread.
- Editor plugin (`addons/local_agents/`) that exposes chat, download, and configuration panels while remaining `@tool` friendly.
- Reusable controllers/services for chat, conversation storage, and project graph helpers written in idiomatic GDScript.
- Shell helpers for fetching third-party dependencies, running headless editor checks, and executing the addon’s GDScript test suites.
- Demo scenes (`ChatExample.tscn`, `Agent3DExample.tscn`, `GraphExample.tscn`) that wire everything together without bundled art packs (bring your own textures or drop-in themes as needed).

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
   # or build host-supported macos/linux/windows targets in one pass
   ./scripts/build_all.sh
   ```
3. Stage speech/transcription runtimes when you need Piper or Whisper:
   ```bash
   ./scripts/fetch_runtimes.sh --all
   ```
4. Open the editor bottom panel → **Local Agents** to configure model/inference settings and explore the Chat or Download tabs.
5. Run demo scenes under `addons/local_agents/examples/` to validate integration (`ChatExample.tscn`, `GraphExample.tscn`, or `Agent3DExample.tscn`).

### Runtime Health (Demo-First)

Use `addons/local_agents/examples/ChatExample.tscn` as the fastest health check:

1. Open the scene and run it.
2. Confirm the left HUD says `Runtime: Ready`.
3. If runtime is unavailable, use the HUD error text to verify binary/build issues first.
4. Confirm model status shows a GGUF file detected under `user://local_agents/models`.
5. Click `Refresh Status` after building binaries or downloading models.

### Agent3D Demo Flow (HUD Parity)

Use `addons/local_agents/examples/Agent3DExample.tscn` for the in-world Agent3D + HUD walkthrough:

1. Run the scene and check the HUD checklist in order.
2. Confirm `Runtime` status is healthy (`Runtime: loaded`/ready). If not, build binaries and refresh.
3. Confirm a default GGUF is detected (`Model file: ...`) under `user://local_agents/models`.
4. Click `Load Default Model` and wait for `Runtime model: Loaded`.
5. Enter a prompt in `PromptInput`, press Enter (or `Send`), and watch the 3D label + HUD transcript update.

The HUD is intentionally explicit about next actions:

- Runtime missing: fix extension/runtime binaries first.
- Model missing: download via `Local Agents -> Downloads`.
- Model not loaded: load into runtime before prompting.
- Ready: send prompts directly to `LocalAgentsAgent3D`.

### Download Workflow

1. Open Godot bottom panel → **Local Agents** → **Downloads**.
2. Download a model from the catalog (defaults to the recommended Qwen GGUF).
3. Downloaded artifacts are written under `user://local_agents/models/...` (not committed to git).
4. Return to chat and click `Load Model` before sending prompts.

### Speech + Transcription

- Configure a Piper voice under **Configuration → Model** or via `LocalAgentsModelParams.voice`. The helper `LocalAgentsRuntimePaths.resolve_voice_assets` now normalizes both `res://` and absolute voice bundles.
- The chat panel and `LocalAgentsAgent` delegate speech to `LocalAgentsSpeechService`, which spins up worker threads and calls the native `AgentRuntime.synthesize_speech`/`transcribe_audio` APIs so the editor no longer blocks at 80%.
- Results surface through `speech_synthesized`/`job_failed` signals; raw dictionaries mirror `AgentRuntime` responses (`ok`, `output_path`, optional `text`).
- Direct GDS access is also available:
  ```gdscript
  var service := LocalAgentsSpeechService.get_singleton()
  var result := service.synthesize({
      "text": "Hello agents!",
      "voice_path": RuntimePaths.resolve_voice_assets("en_US-amy-high").get("model", "")
  })
  ```

### llama.cpp HTTP Server Provider

`AgentRuntime.generate()` now supports a remote llama.cpp server provider through inference options:

- Set `backend` to `llama_server` (also accepts `llama-server`, `llama.cpp_server`, `llama_cpp_http`).
- Configure `server_base_url` (default: `http://127.0.0.1:8080`).
- Optional: `server_chat_endpoint` (defaults to `/v1/chat/completions`), `server_api_key`, `server_model`, `server_timeout_sec`.
- Optional slot/cache controls for high-concurrency agent workloads: `id_slot`, `cache_prompt`.
- Optional server-native body passthrough: `server_extra_body` (merged directly into the HTTP JSON body).

The provider path supports:

- OpenAI-compatible chat completions route (`/v1/chat/completions`).
- JSON response formatting via `output_json`, `response_format`, and `json_schema`.
- Tool/function-calling request fields (`tools`, `tool_choice`, `parallel_tool_calls`, `parse_tool_calls`).
- Multimodal messages when `messages` are supplied as OpenAI content blocks (including `image_url` parts).
- Additional llama.cpp server generation knobs via standard fields (`mirostat`, `top_k`, `min_p`, `repeat_penalty`, etc.) or `server_extra_body`.

Example `LocalAgentsInferenceParams` usage:

```gdscript
var cfg := LocalAgentsInferenceParams.new()
cfg.backend = "llama_server"
cfg.server_base_url = "http://127.0.0.1:8080"
cfg.server_model = "gpt-oss-20b"
cfg.output_json = true
cfg.server_slot = 0
cfg.server_cache_prompt = true
cfg.server_extra_body = {
    "n_predict": 256,
    "cache_prompt": true,
    "return_tokens": false
}
```

## Tooling & Tests

- `scripts/fetch_runtimes.sh` – fetch optional Piper/Whisper bundles via the runtime downloader.
- `addons/local_agents/gdextensions/localagents/scripts/build_all.sh` – host-aware multi-target release build wrapper (skips unavailable toolchains with warnings).
- `addons/local_agents/gdextensions/localagents/scripts/report_release_sizes.sh` – deterministic artifact size/hash report for release regression checks.
- `addons/local_agents/runtime/RuntimePaths.gd` – shared lookup helpers for runtime binaries, default models, platform subdirs, and per-platform voice assets.
- `addons/local_agents/tests/run_all_tests.gd` – headless harness that always runs core tests, then runs runtime/heavy coverage by default. It auto-resolves `LOCAL_AGENTS_TEST_GGUF` (or downloads `Qwen3-0.6B-Q4_K_M.gguf`) before runtime tests, unless `--skip-heavy` is passed.

Run the cross-platform harness with:

```bash
godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd
```

By default the harness runs runtime/heavy tests. Pass `--skip-heavy` to run only the fast core suite. The runtime path will:

1. Reuse `LOCAL_AGENTS_TEST_GGUF` or any cached local/Hugging Face copy of `Qwen3-0.6B-Q4_K_M.gguf`.
2. If missing, use `LocalAgentsModelDownloadService` + `AgentRuntime.download_model()` (with a direct HF fallback) to fetch the model into `user://local_agents/models/qwen3-0_6b-instruct/`.
3. Leave the model on disk so later runs are typically instant. The repo never tracks weights; artifacts stay under `user://` or your Hugging Face cache.

If the runtime extension cannot initialize, or model acquisition still fails, the harness exits non-zero and reports the runtime-heavy test as failed. (`--include-heavy` is still accepted but no longer required.) Additional GDScript scenarios (`test_conversation_store.gd`, `test_network_graph.gd`, etc.) remain available for manual runs once the native extension is built.

## Assets

Earlier releases bundled large cursor/icon/logo packs. Those files were removed to keep the repository lean; reference replacements from your own project if a scene references missing textures. The sample scenes and controllers now prefer plain text/buttons by default.

## Architecture Notes

- `addons/local_agents/gdextensions/localagents/` holds the native runtime (C++ headers, sources, and helper scripts).
- `addons/local_agents/agent_manager/` and `addons/local_agents/controllers/` contain the editor/runtime singletons and UI mediators.
- `addons/local_agents/graph/` implements the NetworkGraph helpers and Tree-sitter style services for project exploration.
- `ARCHITECTURE_PLAN.md` documents concern-based workstreams and sub-agent execution expectations for this branch.

For historical notes, see `docs/NETWORK_GRAPH.md` and comments in the GDScript controllers. Contributions should stick to C++ or GDScript, and update the plan doc before introducing additional toolchains.
