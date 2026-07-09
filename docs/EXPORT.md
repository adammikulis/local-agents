# Building the itch.io release

This is the shipper's checklist for producing the native (downloadable) LocalAgents build
for itch.io. It covers all three desktop targets — Windows (x86_64), macOS (universal),
and Linux/X11 (x86_64) — from the Godot 4.7 export presets in `export_presets.cfg`.

The exported build boots straight to the **main menu**. It does **not** bundle any LLM model
weights: the player downloads a model in-game on first run (the catalog + downloader live in
the app; see `runtime/RuntimePaths.gd` and `controllers/ModelDownloadService.gd`). So a fresh
build is small (tens of MB), and a working model is fetched to `user://local_agents/models`
the first time the player asks for one.

## Prerequisites

- **Godot 4.7** on `PATH` (`godot --version` → `4.7.stable...`).
- **Godot 4.7 export templates installed.** Install from the editor
  (`Editor > Manage Export Templates > Download and Install`) or drop the `.tpz` contents into
  `~/Library/Application Support/Godot/export_templates/4.7.stable/` (macOS),
  `~/.local/share/godot/export_templates/4.7.stable/` (Linux), or
  `%APPDATA%\Godot\export_templates\4.7.stable\` (Windows). Without templates the export fails
  with `No export template found`.
- **The native GDExtension binaries present** under
  `addons/local_agents/gdextensions/localagents/bin/` for the target platform (see next section).
- Run one editor scan first so new `class_name`s / the `.gdextension` register and assets import:
  `godot --headless --editor --quit-after 400 --path .`

## Get the platform native binaries (the cross-platform bin reality)

The `.gdextension` (`addons/local_agents/gdextensions/localagents/localagents.gdextension`)
declares one library per platform:

| Platform | Library file in `bin/` |
| --- | --- |
| macOS (universal) | `localagents.macos.dylib` |
| Windows (x86_64) | `localagents.windows.dll` |
| Linux (x86_64) | `localagents.linux.so` |

The extension links a set of **runtime dependency libraries** (`libllama.*`, `libggml*.*`,
`libmtmd.*`) via `@loader_path`/`$ORIGIN`, so they must sit in the **same directory** as the
library at runtime. The `.gdextension`'s `[dependencies]` section lists them, and Godot copies
both the declared library **and** its listed dependencies next to the app binary on export
(into `Contents/Frameworks/` for a macOS `.app`, next to the `.exe`/`.x86_64` on Windows/Linux).
That is what makes the exported extension actually load — the raw `bin/` dir is **not** packed
into the `.pck` (a `.dylib`/`.dll` cannot be `dlopen`'d from inside a `.pck`).

The macOS dependency list in the `.gdextension` is verified against the produced `bin/`. The
Windows/Linux lists follow the llama.cpp/ggml build outputs collected by
`scripts/build_extension.sh`; if a CI artifact names a library differently, Godot's export error
names the missing file — update the matching entry in the `[dependencies]` section.

The `llama-cli` / `llama-server` executables and the `bin/runtimes/` tree are **not** bundled;
those are fetched at runtime alongside the model (the runtime download path), same as the weights.

**Only the macOS `.dylib` is produced on the dev host** (via
`addons/local_agents/gdextensions/localagents/scripts/build_extension.sh`). The Windows `.dll`
and Linux `.so` (plus their runtime libs) are built by CI and must be dropped into `bin/`
before exporting those targets:

1. Trigger / open the **Build Extension (Cross-Platform)** workflow
   (`.github/workflows/build-extension.yml`) — it builds all three platforms.
2. Download the artifact for your target:
   - `localagents-windows-bin` → contains `localagents.windows.dll` + its runtime libs
   - `localagents-linux-bin` → contains `localagents.linux.so` + its runtime libs
   - `localagents-macos-bin` → the macOS `.dylib` + libs (or just build locally)
3. Extract the artifact's contents into
   `addons/local_agents/gdextensions/localagents/bin/` so the platform library sits next to the
   `.gdextension`'s expected path.

> The `bin/` directory is a **gitignored build artifact** — it is absent from a fresh checkout.
> In a worktree, symlink it from the primary checkout:
> `ln -s <primary>/addons/local_agents/gdextensions/localagents/bin <worktree>/addons/local_agents/gdextensions/localagents/bin`

## Export

Use the helper script (creates the output dir, runs the headless export):

```sh
scripts/export_game.sh macos     # -> build/macos/LocalAgents.app
scripts/export_game.sh windows   # -> build/windows/LocalAgents.exe
scripts/export_game.sh linux     # -> build/linux/LocalAgents.x86_64
```

Optionally pass an output path as the second argument. Under the hood each is just:

```sh
godot --headless --export-release "<preset name>" <output path>
```

with preset names `macOS`, `Windows Desktop`, and `Linux/X11` (from `export_presets.cfg`).
Presets are **release**, with an **embedded pck** (the `.pck` is baked into the binary; for macOS
it lives inside the `.app` bundle). A clean export prints `[ DONE ] export` and reports **0 errors**.

You can only export a target from any host **as long as that target's native libs are in `bin/`**
— Godot's export itself is cross-platform, but the shipped extension only works if its platform
library (and runtime libs) were present at export time.

## What is (and isn't) bundled

Included in every preset:

- All project resources (scenes, the glTF creature/plant models, textures, audio).
- The `MainMenu.tscn` main scene.
- Both GDExtensions placed next to the app binary (macOS `Frameworks/`): `localagents`
  (its library + the `libllama`/`libggml*`/`libmtmd` runtime dylibs from the `[dependencies]`
  section) and the `zylann.voxel` voxel extension.
- `addons/local_agents/models/catalog.json` (the in-game model download catalog).
- `CREDITS.md`, `THIRD_PARTY_LICENSES.md`, `LICENSE` (bundle the attribution).

Excluded:

- `addons/local_agents/tests/*` (dev-only).
- `bin/runtimes/*` and the `llama-cli`/`llama-server` executables — fetched at runtime, not shipped.
- `*.gguf`, `*.onnx`, `*.safetensors` — **no model weights or voices are ever bundled**; the
  player downloads them in-game on first run.

## First-run sanity

The exported build must boot to the **main menu with no model present** — the main menu is pure
UI and has zero model dependency, and the in-game model downloader reads `catalog.json` (shipped)
to fetch a model to `user://local_agents/models` on demand. Verify a fresh build:

```sh
# macOS: launch the exported .app; it should reach the LocalAgents main menu.
build/macos/LocalAgents.app/Contents/MacOS/LocalAgents
```

(For non-interactive/off-screen verification on macOS, launch with
`--position 30000,30000 --resolution 640x400`, mirroring `scripts/run_sim_offscreen.sh`, so the
window does not steal focus.)

## Uploading to itch.io (optional / manual)

Uploading is a separate manual step via itch's `butler` CLI (not automated here):

```sh
butler push build/macos/LocalAgents.app   <user>/<game>:osx
butler push build/windows                 <user>/<game>:windows
butler push build/linux                   <user>/<game>:linux
```

Set each channel's launch executable in the itch project settings (the `.app` for macOS, the
`.exe` for Windows, the `.x86_64` for Linux). Mark the uploads as "This file will be played in
the browser" **off** — these are native downloads.
