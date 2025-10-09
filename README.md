# Local Agents

This repository contains a lightweight Godot plug-in and Python tooling that integrate [llama.cpp](https://github.com/ggerganov/llama.cpp) through the [llama-cpp-python](https://github.com/abetlen/llama-cpp-python) bindings. The focus of this update is to remove all C# dependencies and provide an end-to-end path for running inference against the **Qwen3-0.6B-Instruct** model.

The project ships with:

- A Godot 4 plug-in that exposes a `MindManager` autoload and `MindAgent` node written entirely in GDScript.
- A reusable Python CLI (`scripts/run_inference.py`) that executes llama.cpp inference via the Python bindings.
- An automated test that downloads the Qwen3-0.6B-Instruct model, performs a short chat completion, and asserts that text is produced.

## Requirements

- Godot 4.3 (standard build).
- Python 3.10 or newer.
- CMake toolchain build dependencies required by `llama-cpp-python`.

## Quick start

1. Install Python dependencies:
   ```bash
   pip install -e .
   ```
2. Download and cache the Qwen3-0.6B-Instruct model and run a single prompt:
   ```bash
   python scripts/run_inference.py --download --prompt "Say hi in one short sentence."
   ```
   The script stores models inside `.models/` by default; use `--model` to target a specific `.gguf` file if you already have one locally.
3. Open the Godot project (`project.godot`) and enable the **LocalAgents** plug-in.
4. Configure the `MindManager` autoload with the path to your `.gguf` file (for example `res://.models/Qwen3-0.6B-Instruct-Q4_K_M.gguf`).
5. Run the bundled `chat_example.tscn` scene to exchange prompts with the locally hosted model.

## Running the tests

The repository includes an end-to-end test that verifies llama.cpp inference using the Qwen3-0.6B-Instruct model. Execute the suite with:

```bash
pytest -k qwen3
```

The test harness automatically downloads and caches the model in `.models/` using the Hugging Face Hub API. Subsequent runs reuse the local cache.

## Environment variables

- `LOCAL_AGENTS_PYTHON`: Override the Python executable used by the Godot scripts when invoking the CLI.
- `LOCAL_AGENTS_MODEL_DIR`: Override the default `.models/` cache directory used by the Python utilities and tests.

## Notes

- The runtime no longer includes any C# scripts, project files, or dependencies. Everything is authored in GDScript and Python.
- The Python CLI produces plain-text responses so that Godot scenes can consume them with minimal parsing.
