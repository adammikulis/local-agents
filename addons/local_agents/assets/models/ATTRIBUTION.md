# Asset Attribution

> This file covers the bundled art + voice assets only. The full third-party attribution (engine, native
> libraries, AI models) lives in the top-level [`CREDITS.md`](/CREDITS.md); required license texts are in
> [`THIRD_PARTY_LICENSES.md`](/THIRD_PARTY_LICENSES.md); the project's own authors are in [`AUTHORS`](/AUTHORS).

All bundled 3D models and the streamer voice are CC0 / public-domain-equivalent. Attribution is not
legally required for CC0, but is provided here as good practice.

## 3D models (`fauna/`, `nature/`, `people/`)

- **Quaternius** — rigged creatures and the humanoid character (`fauna/fox.glb`, `fauna/fish.glb`,
  `people/villager.glb`, reused as the streamer avatar). License: **CC0**. https://quaternius.com
- **Kenney** — the "Cube Pets" (`fauna/bird.glb`, `fauna/rabbit.glb`, `fauna/vulture.glb`) and the
  Nature Kit props (`nature/*.glb`). License: **CC0**. https://kenney.nl

Rigs that exported facing +Z were rotated 180° via `scripts/bake_model_forward.py` so every model
faces -Z (see `data/ActorModels.gd`).

## Streamer voice (Piper TTS)

- **rhasspy/piper-voices** — `en_US-hfc_female-medium` (and any other auto-downloaded voice). License:
  **CC0 / MIT** per the piper-voices repository. Downloaded at runtime into
  `user://local_agents/voices/` by `streamer/StreamerVoice.gd`; not committed to the repo.
  https://huggingface.co/rhasspy/piper-voices
