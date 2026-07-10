# Third-party licenses

Local Agents redistributes or depends on the third-party software below. The MIT-licensed components
require that their copyright notice and permission text be included with any distribution — those full
notices are reproduced here so the shipped build is license-compliant. AI model weights and voice models
are **downloaded at runtime** and are not bundled; their licenses are listed for reference and linked to
the upstream source.

See [`CREDITS.md`](CREDITS.md) for the human-readable attribution summary.

---

## MIT-licensed components (bundled / linked into the build)

The following components are all under the MIT License. Each is listed with its own copyright line,
followed by the single shared MIT permission text that applies to every one of them.

- **Godot Engine** — Copyright (c) 2014-present Godot Engine contributors; Copyright (c) 2007-2014 Juan
  Linietsky, Ariel Manzur. https://godotengine.org
- **godot-cpp** — Copyright (c) 2017-present Godot Engine contributors.
  https://github.com/godotengine/godot-cpp
- **godot_voxel** — Copyright (c) 2016-present Marc Gilleron (Zylann) and godot_voxel contributors.
  https://github.com/Zylann/godot_voxel
- **llama.cpp** — Copyright (c) 2023-present The ggml authors. https://github.com/ggml-org/llama.cpp
- **whisper.cpp** — Copyright (c) 2023-present The ggml authors. https://github.com/ggml-org/whisper.cpp
- **Piper (rhasspy/piper)** — Copyright (c) 2022 Michael Hansen. https://github.com/rhasspy/piper

### MIT License

```
MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## CC0 / public-domain components (bundled art & voices)

These are released under the Creative Commons CC0 1.0 Universal public-domain dedication. Attribution is
not legally required, but is provided as good practice.

- **Kenney** — "Cube Pets" creatures and Nature Kit props. https://kenney.nl —
  https://creativecommons.org/publicdomain/zero/1.0/
- **Quaternius** — rigged creatures and the humanoid/streamer character. https://quaternius.com —
  https://creativecommons.org/publicdomain/zero/1.0/
- **rhasspy/piper-voices** — the `en_US-ryan-medium` and `en_US-hfc_female-medium` voice models are
  distributed as MIT / CC0 per the piper-voices repository (downloaded at runtime).
  https://huggingface.co/rhasspy/piper-voices

---

## AI models (downloaded at runtime — not bundled)

Language models are fetched from Hugging Face on demand and used under their own upstream licenses.
Because the weights are not redistributed in this build, only the license reference and source link are
provided.

- **Qwen3** (0.6B, 1.7B, 4B, 8B, 14B; GGUF) — **Apache-2.0**.
  https://www.apache.org/licenses/LICENSE-2.0 — https://huggingface.co/Qwen
- **Qwen2.5-3B-Instruct** — **Qwen Research License** (a custom, non-Apache license specific to this model
  size). https://huggingface.co/Qwen/Qwen2.5-3B-Instruct/blob/main/LICENSE
- **FunctionGemma-270M** (Google, Gemma 3) — **Gemma Terms of Use** (a custom Google license; review its
  use restrictions before redistribution or commercial use). https://ai.google.dev/gemma/terms

GGUF quantizations for several of the above are provided by the **Unsloth** community
(https://huggingface.co/unsloth) and inherit the base model's license.

### Apache License 2.0 (summary)

The Qwen3 models are licensed under the Apache License, Version 2.0. The full text is available at
https://www.apache.org/licenses/LICENSE-2.0. In brief, it grants a royalty-free copyright and patent
license to use, modify, and distribute the work, provided that: you include a copy of the license; you
state significant changes; you retain notices; and you include any `NOTICE` file contents from the
upstream distribution. The work is provided "AS IS", without warranties or conditions of any kind.
