# Installing Local Agents

You need two things that are not in the repo: the native extension, and a model file. The plugin will
tell you which one is missing and what to do, so if you are not sure where you are, enable the plugin
and open the Local Agents panel in the bottom bar.

## 1. The native extension

This is the compiled C++ library that actually runs the model. `bin/` is a build artifact, so it is
not committed.

Either download a prebuilt one or build it. To download, go to the Build Extension workflow in GitHub
Actions, open a successful run, and grab the artifact named localagents-<platform>-bin for your
platform. Unzip it into:

```
addons/local_agents/gdextensions/localagents/bin/
```

To build it instead:

```bash
cd addons/local_agents/gdextensions/localagents
./scripts/fetch_dependencies.sh                  # godot-cpp, llama.cpp, whisper.cpp, sqlite
./scripts/build_extension.sh --platform macos    # or: linux | windows
```

Godot loads the library by an exact filename per platform:

```
macOS     addons/local_agents/gdextensions/localagents/bin/localagents.macos.dylib
Linux     addons/local_agents/gdextensions/localagents/bin/localagents.linux.so
Windows   addons/local_agents/gdextensions/localagents/bin/localagents.windows.dll
```

The Setup tab shows the exact path it is looking for and will copy it to your clipboard.

## 2. Enable the plugin

Click Project > Project Settings > Plugins > Enable (Local Agents). This registers the AgentManager
autoload for you, and adds the Local Agents settings under Project Settings > General. You do not
need to add any autoload by hand.

If you are consuming the library in your own project and have deleted the game, register only
AgentManager. GameMode and AppExit are game-only.

## 3. A model

Any .gguf file works. The default is Qwen3-4B-Instruct-2507-Q4_K_M, which wants about 4GB free. If
you have less to spare, Qwen3-0.6B runs on far less at the cost of answer quality.

The easy way is the Downloads tab in the Local Agents panel. It fetches into
`user://local_agents/models/` and the plugin picks it up from there with no further setup.

If you already have a .gguf somewhere else, point Project Settings >
`local_agents/model/default_path` at it. Failing that, the plugin walks
`local_agents/model/search_paths` in order and uses the first file that exists.

## Settings

All of these live under Project Settings > General > Local Agents, and each one also honours an
environment variable so CI and scripts can override it.

```
local_agents/model/default_path                     the .gguf to use, blank to search
local_agents/model/search_paths                     ordered fallback candidates
local_agents/llm/server_url                         llama-server base URL      (FUNCTIONGEMMA_URL)
local_agents/llm/backend                            llama_server or in_process
local_agents/llm/auto_enable_when_model_present     start the shared service automatically
local_agents/runtime/fail_fast                      error instead of warn when something is missing
local_agents/editor/enabled                         auto-open the bottom panel
```

`auto_enable_when_model_present` is off by default on purpose. Having a model on disk should not
silently start a server process behind the player's back, so you opt in.

## When something does not work

**"native runtime unavailable"** means Godot could not load the library. Check the file is at the
exact path above and matches your platform and architecture. On macOS an arm64 build will not load
in an x86_64 Godot.

**"no model installed"** means nothing was found. The Setup tab lists every path it checked.

**"model found, not loaded yet"** is normal before the first request. Turn on Preload Model on the
LocalAgent node if you want it loaded during startup instead of on the first think().

**A llama-server that starts and then times out** usually means the server binary cannot find its
sibling libraries. Run it directly to see the real error:

```bash
addons/local_agents/gdextensions/localagents/bin/llama-server --version
```

Builds before 2026-07 had an absolute rpath baked in and only ran on the machine that built them.
Rebuild, or re-download the artifact.

## Optional: the voxel planet

The planet demo uses [godot_voxel](https://github.com/Zylann/godot_voxel) for terrain. Everything
else, including the agent nodes and the flat-world simulation, works without it. If it is not
installed, `LocalAgentSimWorld` in SPHERE mode says so and stops rather than building half a world.
Set `world_type` to FLAT if you want a world without it.
