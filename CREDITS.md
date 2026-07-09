# Credits — third-party attribution

Local Agents is a locally-simulated living world. It stands on a lot of freely-shared work — engines,
native libraries, art, voices, and open-weight AI models. This file is the single human-readable source
of **third-party** attribution. (The project's own authors live in [`AUTHORS`](AUTHORS); the exact
copyright notices and license texts required for redistribution live in
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md); the bundled 3D-asset notes live in
[`addons/local_agents/assets/models/ATTRIBUTION.md`](addons/local_agents/assets/models/ATTRIBUTION.md).)

## Engine & tools

- **Godot Engine** — the game engine. License: **MIT**. https://godotengine.org
- **godot-cpp** — the GDExtension C++ bindings the native `localagents` extension is built on. License:
  **MIT**. https://github.com/godotengine/godot-cpp
- **godot_voxel** by **Zylann / Marc Gilleron** — the voxel terrain engine the world is built on.
  License: **MIT**. https://github.com/Zylann/godot_voxel
- **llama.cpp** (the ggml authors / Georgi Gerganov) — runs the local language models that drive creature
  cognition and the streamer. License: **MIT**. https://github.com/ggml-org/llama.cpp
- **whisper.cpp** (the ggml authors / Georgi Gerganov) — local speech-to-text used by the native runtime.
  License: **MIT**. https://github.com/ggml-org/whisper.cpp

## Art

- **Kenney** — the "Cube Pets" creatures (bird, rabbit, vulture) and the Nature Kit props. License:
  **CC0** (public domain). https://kenney.nl
- **Quaternius** — the rigged creatures (fox, fish) and the humanoid character, reused as the streamer
  avatar. License: **CC0** (public domain). https://quaternius.com

Attribution is not legally required for CC0, but is provided here as good practice. Rigs that exported
facing +Z were rotated 180° at import so every model faces -Z.

## Voice

- **Piper TTS** (rhasspy/piper) — the neural text-to-speech engine that gives the streamer a voice.
  License: **MIT**. https://github.com/rhasspy/piper
- **rhasspy/piper-voices** — the voice models `en_US-ryan-medium` (male) and `en_US-hfc_female-medium`
  (female), auto-downloaded on first use. License: **MIT / CC0** per the piper-voices repository.
  https://huggingface.co/rhasspy/piper-voices

Voice models are downloaded at runtime into `user://local_agents/voices/` and are not bundled with the
build.

## AI models

Language models are **downloaded at runtime** from Hugging Face (they are not bundled with the build);
each is used under its own upstream license, linked below.

- **Qwen3** — 0.6B, 1.7B, 4B, 8B, and 14B instruction-tuned models (GGUF). License: **Apache-2.0**.
  https://huggingface.co/Qwen
- **Qwen2.5-3B-Instruct** (legacy, kept for compatibility). License: **Qwen Research License** (a custom
  license — not Apache-2.0 for this size). https://huggingface.co/Qwen/Qwen2.5-3B-Instruct/blob/main/LICENSE
- **FunctionGemma-270M** (Google, based on Gemma 3) — the on-device function-calling model. License:
  **Gemma Terms of Use** (a custom Google license; review before redistribution or commercial use).
  https://ai.google.dev/gemma/terms

GGUF quantizations are distributed by the Qwen team and by the **Unsloth** community
(https://huggingface.co/unsloth) and inherit the base model's license.

Made with Local Agents — a living world, simulated locally. See [`AUTHORS`](AUTHORS) for the project's
creators and [`LICENSE`](LICENSE) for the project's own MIT license.
