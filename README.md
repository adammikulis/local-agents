# Local Agents

**An AI that runs on your own computer, inside a video game.**

When you use most AI assistants, your words travel to a company's servers, get answered there, and
come back. Local Agents doesn't do that. The AI model runs on the player's own machine — no internet
connection, no accounts, no data leaving the computer. It keeps working on a plane.

This is a plugin for [Godot](https://godotengine.org), a free game engine. It gives a game two
things that usually require a cloud service:

- **Characters that talk.** Dialogue written as the game is played, not chosen from a script.
- **Characters that decide.** The model doesn't just produce words — it chooses what a character
  should *do*, and the game carries it out.

![A voxel planet with weather, terrain and animals](addons/local_agents/docs/img/planet.png)

## The demo world

The largest example is a small planet that runs itself.

It has one shared physical layer underneath everything — heat, water, air, fire, rock — and the rest
follows from it. Rain falls because water evaporated and cooled. A volcano erupts because pressure
built up under rock. Nothing is a scripted special effect; there is no "make a storm" button in the
code. The weather and the disasters are consequences.

Animals live on it. They eat, drink, flee, hunt, form herds and raise young. Most of the time they
use fast built-in instincts. When something unfamiliar happens, the animal asks the language model
what to do — and that answer becomes an action in the world.

There's also an optional commentator: a second model instance that watches the simulation and talks
about it out loud, in a generated voice, as it happens.

All of it runs offline on one machine.

## How it works

Three pieces, in plain terms:

| Piece | What it is |
| --- | --- |
| The model | A file, a few gigabytes, containing a trained language model. You download one once. |
| The engine | A C++ component built on [llama.cpp](https://github.com/ggml-org/llama.cpp) that runs that file efficiently on your CPU or graphics card. Speech recognition and text-to-speech are built in too. |
| The plugin | The Godot side: drop an "agent" into a scene, point it at the model, and it starts answering and acting. |

The interesting engineering problem is speed. A language model takes a moment to think, and a game
draws sixty frames a second — so the model can't be asked about everything. Characters run on cheap
instinctive rules almost all the time, and the model is called only for genuinely novel situations,
on a background thread, within a strict budget. The simulation itself runs on the graphics card.

---

The rest of this page is for developers.

## Using it in code

Add a `LocalAgent` node to a scene, then:

```gdscript
@onready var agent: LocalAgent = $LocalAgent

func _ready() -> void:
    agent.think_completed.connect(_on_reply)
    agent.think_async("Say hello in one short sentence.")

func _on_reply(result: Dictionary) -> void:
    if result.get("ok", false):
        print(result["text"])
    else:
        push_warning(result.get("error", "agent unavailable"))
```

`think_async()` runs the model on a worker thread and delivers the result on the main thread, so the
game keeps rendering while it generates. There is a blocking `think()` as well, but it stalls the
frame for as long as generation takes — use it in tools and tests, not in gameplay.

For speech, call `say(text)` and `listen()`. To let the model drive behaviour instead of producing
text, connect its `action_requested(action, params)` signal and decide in your own code what each
action means.

## Getting set up

Two things aren't in the repository, and you need both.

**1. The native extension.** It's compiled C++, so `bin/` is a build artifact. Either download a
prebuilt one — the [Build Extension](.github/workflows/build-extension.yml) workflow publishes an
artifact named `localagents-<platform>-bin` for Linux, Windows and macOS; unzip it into
`addons/local_agents/gdextensions/localagents/bin/` — or build it:

```bash
cd addons/local_agents/gdextensions/localagents
./scripts/fetch_dependencies.sh                  # godot-cpp, llama.cpp, whisper.cpp, sqlite
./scripts/build_extension.sh --platform macos    # or: linux | windows
```

**2. A model.** Any GGUF file works; the default is `Qwen3-4B-Instruct-2507-Q4_K_M.gguf`. The easiest
route is from inside the editor: enable the Local Agents plugin, open the Local Agents panel at the
bottom of the window, and use the Downloads tab.

If either is missing, the plugin says which one and what to do about it rather than failing quietly.

## Examples

Open `addons/local_agents/examples/DemoLauncher.tscn` and press play — it lists every example with an
Open button. They build on each other, so it's worth going in order.

![The quickstart scene answering a prompt](addons/local_agents/docs/img/quickstart.png)

| | Scene | What it covers |
| --- | --- | --- |
| 1 | `AgentQuickstart.tscn` | One agent, a prompt box, a reply. The smallest thing that works. |
| 2 | `AgentActionsDemo.tscn` | The model's reply becomes game actions instead of text. Buttons fire the same actions, so it works with no model installed. |
| 3 | `AgentConversationDemo.tscn` | Two agents take turns; each line is stored in a shared memory graph. |
| 4 | `ChatExample.tscn` | A full chat interface with model settings, sampling settings and saved conversations. |
| 5 | `Agent3DExample.tscn` | A talking agent in a 3D scene. |
| 6 | `GraphExample.tscn` | The memory graph resource on its own. Runs without a model. |

All of them live in `addons/local_agents/examples/`.

The planet is `addons/local_agents/game/VoxelWorld.tscn`. It can run itself for testing:

```bash
# run 300 frames, print one SIM_REPORT={...} telemetry line, quit
scripts/run_sim_offscreen.sh --path . addons/local_agents/game/VoxelWorld.tscn -- --run-frames=300

# take a screenshot
godot addons/local_agents/game/VoxelWorld.tscn -- --shoot=/tmp/shot.png --overview
```

If you want the agent library without the game, delete `addons/local_agents/game/` —
[docs/USAGE.md](docs/USAGE.md) covers what's reusable and what isn't.

## Tests

```bash
scripts/agent_harness.sh fast        # quick sweep
scripts/agent_harness.sh all         # everything
scripts/agent_harness.sh extension   # check the GDExtension loads
scripts/agent_harness.sh lint        # typing and process gates
```

A useful gotcha: a new `class_name` or `.gdextension` only registers after an editor scan. If Godot
reports a class as missing, run `godot --headless --editor --quit-after 400` once.

## Learning more

- [docs/USAGE.md](docs/USAGE.md) — using the library in your own project, the adapter contracts, and
  adding a new species with a JSON file.
- [addons/local_agents/sim/EMERGENCE.md](addons/local_agents/sim/EMERGENCE.md) — the design rule
  behind the simulation: behaviour comes from simple local rules interacting, never from scripted
  special cases.
- `CLAUDE.md` and `GODOT_BEST_PRACTICES.md` — contributor process and Godot conventions.

---

*This project started as MindGame, a hand-rolled C# Godot plugin for local language models, which had
one of the first in-engine coding agents.*
