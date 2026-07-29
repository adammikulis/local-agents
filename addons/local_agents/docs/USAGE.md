# Using Local Agents in your project

This document covers assembling the addon into something that works: what is in
`addons/local_agents/`, what you can delete, the nodes you drop into a scene, the project settings
that point the addon at a model, and the two duck-typed contracts the creature behaviour talks
through.

INSTALL.md covers getting the native extension and a model file. API.md is the per-type reference.
DEMOS.md lists the example scenes.

## What is in the addon

The addon is one plugin, and the game is deletable. Copy `addons/local_agents/` into your project,
delete `game/`, and the agent, creature and simulation nodes keep working. No script outside `game/`
names a path inside it.

`scripts/check_library_only.sh` proves that on every run rather than asking you to trust it. It stages
the install for you, deletes `game/`, and then does two passes. First an editor scan, which catches an
unresolved `class_name`. Then a force-load of every script in the tree through
`scripts/parse_all_scripts.gd`, because a scan only loads what something references, so a script
nothing instantiates can preload a deleted file and never be looked at. That is not hypothetical: the
gate reported OK for days while `sim/streamer/StreamerHost.gd` preloaded `game/ui/SceneEnergyGraph.gd`.
That file has since moved to `sim/streamer/`, next to the only code that used it.

Two details of that gate are worth knowing if you write one like it. `load()` on a script whose preload
target is missing returns a NON-null Script and prints the parse error to stderr, so loading is what
makes the engine parse but the stderr grep is what notices. And zylann.voxel is symlinked into the
staged project rather than omitted, because `sim/` genuinely needs it for SPHERE mode and leaving it
out buried the one real break under 26 unresolved types.

Core library directories:

| directory | what is in it |
| --- | --- |
| `agents/` | `LocalAgent`, `LocalAgent3D`, `LocalAgentConversation`, `LocalAgentStatusLabel`, `LocalAgentLlmService`, `LocalAgentLlmClient`, and the chat window under `agents/ui/` |
| `agent_manager/` | `LocalAgentManager`, the script registered as the `AgentManager` autoload |
| `runtime/` | the GDExtension loader, `LocalAgentStatus`, `LocalAgentSettings`, model path resolution, `LocalAgentDemoHarness`, and speech under `runtime/audio/` |
| `configuration/` | the `LocalAgentModelProfile` and `LocalAgentInferenceParams` resources and their editor UI |
| `graph/` | `LocalAgentGraph`, a nodes-and-edges memory `Resource`, plus the backstory graph services |
| `creatures/` | the creature behaviour stack: `LocalAgentCreature`, `LAFish`, `LocalAgentCreatureSpawner`, the cognition stack under `cognition/`, species data under `species/`, the flat terrain adapter under `terrain/adapters/` |
| `controllers/`, `ui/`, `models/` | the chat, saved-conversation and model-download controllers, the model manager panels, and `models/catalog.json` |
| `editor/` | the Local Agents bottom panel and its Setup checklist |
| `examples/` | the example scenes and the demo catalogue under `examples/demos/` |
| `icons/` | the node icons that show up in Add Node |
| `docs/` | this file, plus README.md, INSTALL.md, API.md, DEMOS.md and the images under `img/` |
| `gdextensions/` | the native runtime source, and its compiled `bin/` |
| `tests/` | the headless test suite |

`sim/` is the simulation library: the `LocalAgentSimWorld` facade, the `LAMaterialField3D` substrate
under `material/`, ecology, cubed-sphere planet generation, terrain, actors, events, and the
local-LLM streamer. `LocalAgentSimWorld` in SPHERE mode needs the optional zylann.voxel GDExtension
from https://github.com/Zylann/godot_voxel, FLAT mode needs nothing beyond this addon.
`sim/EMERGENCE.md` explains the rule the simulation is built on.

`game/`, `assets/` and `voices/` are the optional Anima game. `audio/` is not: `creatures/creature/
CreatureThink.gd:158` and four actors under `sim/actors/` call `LAAudioDirector.emit()` to make a
chomp, an impact or a weather sound. A creature making a noise is a stimulus broadcast like scent, so
`audio/` is part of the library and deleting it is a parse error.

## Installing into your own project

1. Copy `addons/local_agents/` into your project's `addons/` directory.
2. Optionally delete `game/`, `assets/` and `voices/`. Read "What deleting costs you" below before you
   delete `sim/`.
3. Click Project > Project Settings > Plugins and enable Local Agents.
4. Add a node and fill in the inspector.

### What deleting costs you

One file outside `game/` names a path inside it: `examples/demos/voxel_planet_game.tres:10`, the
catalogue entry for the flagship scene. Its `scene_path` is an `@export_file` String rather than a
`PackedScene`, so the resource still loads and its launcher row reports "Its scene is missing" instead
of breaking the menu.

Deleting `sim/` costs more than you might expect. Two example scenes name a `sim/` script on an
`ext_resource` line:

- `examples/BoxFieldDemo.tscn:3` needs `sim/material/FieldBox.gd`.
- `examples/SimWorldPlanetDemo.tscn:4` needs `sim/SimWorld.gd`.

Both break quietly rather than loudly. Godot still loads a `.tscn` whose `ext_resource` script is
missing: it logs `Parse Error: [ext_resource] referenced non-existent resource` and hands back a
`PackedScene` with that one node stripped down to its bare type. Every sibling survives. `BoxFieldDemo`
still opens with its camera, its light and a working `DemoHarness`, whose script lives in `runtime/`
rather than `sim/`, and only its `FieldBox` child loses its script. `SimWorldPlanetDemo` opens with
`%SimWorld` reduced to a plain `Node3D`, so the cast at `examples/SimWorldPlanetDemo.gd:21` yields
null. Neither reports anything at load. The failure surfaces later as a null-instance property access
inside `demo_report()`, which only a `--run-frames` run reaches.

The launcher does not warn you either. `LADemoLauncher.gate_reason()` at
`examples/DemoLauncher.gd:90` only calls `ResourceLoader.exists(entry.scene_path)`, and that returns
true for a `.tscn` whose script is gone, so both rows stay clickable. Delete those two scenes and
their catalogue entries along with `sim/`, or keep `sim/`.

The creature stack itself survives. `creatures/Creature.gd:369` and
`creatures/creature/CreatureThink.gd:16` are the only other references into `sim/`, and both are plain
String constants resolved through a guarded `ResourceLoader.exists()` at runtime. Without `sim/` a
creature simply cannot throw a rock and shows no flame prop when it burns.

Enabling the plugin registers the `AgentManager` autoload for you, so you do not add it by hand.
`plugin.gd` writes it in `_enter_tree()`, and on disable it removes the entry only if the plugin was
what added it, so an autoload you registered yourself is left alone. Enabling also publishes every
project setting listed below, adds the bottom panel, and installs an inspector plugin that turns the
species id, Piper voice and model path String fields into pick lists.

The plugin registers no custom node types. Every node you are meant to drop into a scene declares a
`class_name`, so Godot already lists it in Add Node without help. Right-click a node in the Scene
dock, click Add Child Node, and type "LocalAgent" to filter. An editor-side alias on top of the
`class_name` registrations produced a second, generically iconed copy of each node in the dialog,
which is why it was removed.

Nine node scripts have no `class_name`, and none of them are meant to be picked from that dialog.
Seven are the scripts already attached to a demo scene: `examples/TutorialDemo.gd`,
`examples/AgentActionsDemo.gd`, `examples/SimWorldPlanetDemo.gd`, `examples/CoreCreatureSmoke.gd`,
`examples/AgentConversationDemo.gd`, `examples/ThinkingCreatureDemo.gd` and `examples/ChatExample.gd`.
The other two are game-only: `game/world/VoxelViewControls.gd` and `game/menu/GameMode.gd`.

`project.godot` in this repo also registers `GameMode` and `AppExit`. Both live under `game/` and are
game-only. Do not register them in a library-only project.

## Project settings

The plugin publishes these under Project Settings > General, each as a typed row rather than a string
you hand-edit into `project.godot`. This is the supported way to point the addon at a model. Each
value resolves as project setting first, then the environment variable if the row lists one, then the
default. Existing values are never overwritten, so re-enabling the plugin is not destructive.

| setting | type | default | environment variable |
| --- | --- | --- | --- |
| `local_agents/model/default_path` | path to a `.gguf` | empty | none |
| `local_agents/model/search_paths` | string array | three `user://local_agents/models/` Qwen3 paths | none |
| `local_agents/llm/server_url` | string | `http://127.0.0.1:8080` | `FUNCTIONGEMMA_URL` |
| `local_agents/llm/backend` | `llama_server` or `in_process` | `llama_server` | none |
| `local_agents/llm/auto_enable_when_model_present` | bool | `false` | none |
| `local_agents/runtime/fail_fast` | bool | `true` | none |
| `local_agents/editor/enabled` | bool | `false` | none |

Two functions resolve a model path today, and each docstring claims to be the only one. Under stock
settings they agree, because the list one of them hardcodes and the list the other reads from Project
Settings hold the same three files. They agree by coincidence rather than by construction, so read the
code rather than the comment when it matters which weights got loaded, and expect them to drift the
moment either list is edited.

`LocalAgentStatus.resolve_model_path()` at `runtime/AgentStatus.gd:213` is the settings-driven one. It
takes `local_agents/model/default_path` if that file exists, then the two built-in locations
(`user://local_agents/models/qwen3-4b-instruct/Qwen3-4B-Instruct-2507-Q4_K_M.gguf` and the same
subpath under `res://addons/local_agents/models/`), then each entry in
`local_agents/model/search_paths` in order. `LocalAgentStatus.candidate_paths()` returns all of them
in that order, which is what the "Checked: ..." text in the setup warnings is built from. This is what
`LocalAgentStatus.check()` reports on, and what a bare `LocalAgent` with an empty Model Path gets.

`LocalAgentLlmService.resolve_model_path()` at `agents/LlmService.gd:219` is the second one, with a
different order. It takes an explicit path first, which is the service's own Model Path export, then
whatever `LocalAgentStatus.resolve_model_path()` returned, then `RuntimePaths.resolve_default_model()`
a second time (the step above already tried it, so it never fires), then three paths hardcoded in
`MODEL_CANDIDATES` at `agents/LlmService.gd:35`, all under `user://local_agents/models/`:

- `qwen3-1_7b/Qwen3-1.7B-Q4_K_M.gguf`
- `qwen3-0_6b-instruct/Qwen3-0.6B-Q4_K_M.gguf`
- `qwen3-4b-instruct/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`

Those are the same three files as the default `local_agents/model/search_paths`, in a different order,
so today both resolvers find the same weights and nothing diverges. What makes this worth knowing is
that the agreement is not enforced anywhere. Edit `search_paths` in Project Settings, or add a fourth
entry to `MODEL_CANDIDATES`, and the creature slow brain and the streamer can then load a model that
`LocalAgentStatus.check()` reports as missing, because they reach the model through the service and
the setup panel reports on the settings-driven resolver.

To add a setting, add one record to `SPECS` in `addons/local_agents/runtime/Settings.gd` and read it
back through `LocalAgentSettings.get_string()` or one of the other typed getters. Do not put a
`ProjectSettings.get_setting()` literal at a call site.

## The nodes you drop in

Most of what the examples do is these nodes with their properties filled in. API.md documents every
export, so what follows is what each one is for and the handful of properties that decide whether it
works at all.

### Agents

`LocalAgent` is the agent itself, a `Node`. Set Model Path to a `.gguf`, or leave it empty to fall
back to `local_agents/model/default_path`. Set System Prompt to the standing instruction. Preload
Model loads the weights when the scene starts instead of on the first `think()`, so the load stall
happens before play rather than in the middle of it. It is ignored on the llama-server backend,
because that process loads the model itself. The Autonomy group (Tick Enabled, Tick Interval, Max
Actions Per Tick) lets the agent act on its own schedule rather than waiting to be asked. Model
Profile and Inference take the two resources below, and Memory Graph takes a `LocalAgentGraph`.

`LocalAgent3D` is a `CharacterBody3D` that owns a `LocalAgent` and a `Label3D` for the reply. Agent
Path and Chat Label Path default to the node names in `agents/Agent3D.tscn`, so an instance of that
scene needs no configuration. `think()`, `think_async()` and `speak()` forward to the inner agent.

It can also drive a talk animation, but you have to build that part. Animation Player Path defaults to
`AnimationPlayer` and `agents/Agent3D.tscn` contains no such node, so `animation_player` resolves to
null and `_on_agent_output()` at `agents/Agent3D.gd:82` never plays anything. Add an `AnimationPlayer`
under the character, point Animation Player Path at it, and give it a clip named by Animation Name,
which defaults to `bobble`. No clip in the addon carries that name.

`LocalAgentChatPanel` is a transcript, a prompt box, a send button and a readiness bar. Instance
`addons/local_agents/agents/ui/ChatPanel.tscn` rather than attaching the script to a bare node: the
script only wires the `%Transcript`, `%PromptInput`, `%SendButton`, `%StatusLabel` and `%StatusBar`
nodes that the scene already contains, and warns you when they are absent. Point Agent at a
`LocalAgent`, or leave it empty and the panel takes the first one among its own children or its
siblings. Auto Load Model is on by default, so the first prompt loads the weights.

`LocalAgentConversation` runs N agents taking turns. Drag them into Agents, type a Topic, and set Max
Turns (0 runs forever). Every utterance is appended to Memory Graph as a node, chained to the
previous one by an edge named by Edge Name. See `LocalAgentGraph` under Resources below for what that
`Resource` is and how to save one. Turn on Auto Advance to pace it by Turn Interval, or
leave it off and call `next_turn()` yourself from a button or a trigger volume. Personas are not a
property here, give each agent its own voice through its own System Prompt. With no usable model the
node speaks Canned Lines instead, so the turn-taking and the graph still demonstrate themselves.

`LocalAgentStatusLabel` is a `Label` that answers "is Local Agents working". It polls
`LocalAgentStatus` every Refresh Interval seconds and shows the headline, tinted by `level`: green
for `READY`, yellow for `DEGRADED` and red for `BLOCKED`. Show Next Step adds the one sentence that
fixes the topmost problem.

`LocalAgentLlmService` is the single shared owner of the LLM runtime for a whole scene. It holds one
`LocalAgent`, resolves the model path and server URL in one place, and hands out one shared
`LocalAgentLlmClient`, so the creature slow brain and the streamer talk to one server with one model
and one config. Enabled is the master switch and it defaults to off, so the addon never boots a
llama-server behind the player's back. Backend picks `llama_server`, which talks to a process over
HTTP, or `in_process`, which runs the weights inside the game through the native runtime. The Server
group holds Server Url, Autostart Server, Start Timeout Ms (default 30000) and Ready Timeout Ms
(default 1200). Raise Start Timeout Ms when an autostarted llama-server is slow to come up on your
machine. The Model group holds Model Path, Model Profile and Inference. Leave Log Availability on: an
offline service is otherwise completely silent, and with it on you get one line naming the resolved
model and server, or the reason and the fix.

### Creatures and worlds

`LocalAgentCreatureSpawner` is a `Node3D` that builds a population. Fill in Counts, a
`Dictionary[String, int]` like `{"rabbit": 5, "fox": 1}` keyed by species id, and press play. The
Placement group decides where they land:

- Area Extent: the box they scatter inside, default `Vector3(16, 0, 16)`.
- Ground Y: the floor height.
- Spawn On Ready: on by default. Turn it off to call `spawn()` yourself.
- Placement Seed: assigned straight to the scatter RNG at `creatures/CreatureSpawner.gd:88`, so every
  run of a given seed lays out identically. Change it for a different layout.

Build Floor is on by default, and Floor Size and Floor Color size and tint it, so a spawner on its own
is already a runnable scene. The creatures it makes are standalone ones on a flat-ground adapter with
no field, no ecology and no planet. Assign Cognition Scheduler and turn on Llm Enabled to let them
escalate to a language model.

`LocalAgentCognitionScheduler` is the shared slow-brain throttle. Every creature escalates rare or
uncertain situations to this one node, which decides for the whole world at once whether there is
budget to resolve another deliberation now. Point Llm Service at a `LocalAgentLlmService` and every
creature in Adopt Group (`la_creatures` by default) is wired to it on ready, including creatures
spawned later. Max In Flight and Max Requests Per Second are the caps. Write Traces appends one JSONL
line per resolved escalation for the finetune loop.

`LAFish` is the aquatic animal, a `CharacterBody3D` in its own right rather than a
`LocalAgentCreature` subclass. It needs an `LAMaterialField3D`, because the whole behaviour is one
rule read out of the field: swim just under the surface, school loosely with your own species, and
turn back whenever the next step would leave water or enter water outside your tolerated salinity and
depth band. Fish variants, turtle, crab, whale, jellyfish and shrimp are all the same script with
different config, keyed on `salinity_min`, `salinity_max`, `depth_min`, `depth_max`, `body`, `basks`,
size and speed. The salinity pair is what places a species in the world:

- a low `salinity_max` keeps it in lakes and rivers
- a raised `salinity_min` holds it to the open sea
- a band straddling the middle keeps it near river mouths and the coast

No per-species branch exists anywhere in the script. Every one falls back to a procedural body when it
has no model asset.

You do not instance `LAFish` yourself. `LAEcologyService.spawn()` builds one whenever a species config
carries `"aquatic": true` (`sim/ecology/EcologyService.gd:436`), and refuses to place it out of water.
The ten configs shipped today live in `creatures/species/aquatic/`.

`LocalAgentSimWorld` is a `Node3D` that composes a whole world: a planet body or a ground plane, the
`LAMaterialField3D` substrate, the ecology, and the founding population. See the third quickstart
below for its export surface.

`LocalAgentFieldBox` is a `Node3D` that runs the material field in box mode with a heat source at its
floor and a plane of cubes tinted by live temperature, so you can watch warmth diffuse and rise. Its
exports come in groups:

- Volume: Extent, Cell Size, Origin Offset.
- Heat Source: Heat Enabled, Heat Per Frame, Heat Burst Frames, and Heat Source Cells, which is how
  many cells wide the emitter is.
- Slice View: Show Slice, Slice Axis, Slice Position, Cube Fill, Color Span, Cold Color, Hot Color.

Box mode is a CPU substrate, so the simulation runs headless and only the visual is skipped when
there is no display. The node owns an `LAMaterialField3D` as a child rather than extending it.

### Resources and the harness

`LocalAgentGraph` is the memory `Resource` that `LocalAgent`'s Memory Graph and
`LocalAgentConversation`'s Memory Graph both take. It is a plain nodes-and-edges store with two
exports, `nodes: Array[LocalAgentGraphNode]` and `edges: Array[LocalAgentGraphEdge]`.

To make one in the editor, click the Memory Graph property's resource picker, choose to create a new
`LocalAgentGraph`, then use the same picker's save option to write it to a `.tres` you can share
between agents. Leave it empty and `LocalAgentConversation` creates one for itself at
`agents/Conversation.gd:108`, but that copy lives only as long as the node. From code,
`LocalAgentGraph.new()` does the same.

The API is small. `add_node(name, data)` appends a node and returns it. `add_edge(source_id,
target_id, name, weight, data, is_bidirectional)` links two by id, pushes an error and returns null
when either id is unknown, and appends a second reversed edge when `is_bidirectional` is true.
`get_node(id)`, `get_edge(id)`, `get_edges()`, `remove_node(id)`, `remove_edge(id)`,
`update_edge_weight(id, amount)` and `update_all_edge_weights(amount)` are the rest. Removing a node
also removes every edge touching it. Ids are assigned from a counter that `ensure_id_counters()`
rebuilds from the current contents, so a graph loaded from disk keeps issuing fresh ids.

`LocalAgentGraphNode` carries `id`, `name` and a free-form `data: Dictionary`. `LocalAgentGraphEdge`
carries `id`, `source_id`, `target_id`, `name`, `weight` and its own `data`, plus
`update_weight(amount)`. `LocalAgentConversation` uses exactly this shape: each utterance becomes a
node named after the speaker with `{"turn": n, "said": text}` as its data, chained to the previous one
by an edge named by Edge Name (`agents/Conversation.gd:234-238`).

`LocalAgentGraphRule` is separate from the graph and nothing in the addon instantiates it. It wraps a
`Callable` condition and a `memory_threshold`, and `evaluate(variable, delta)` calls the condition and
returns `[String, bool]`. Treat it as a hook for your own recall logic.

`LocalAgentModelProfile` is a `Resource` describing which weights to load and how. Its exports are
Profile Name, Model Path, Context Size, Threads, Gpu Layers, System Prompt and Chat Template. Profile
Name is cosmetic, a label shown wherever profiles are listed. Save the resource as a `.tres` and
share one profile between agents so the weights load once. The runtime does not implement Threads
yet.

`LocalAgentInferenceParams` is the companion `Resource` describing how to sample. Inference Config
Name is the same cosmetic label. The two worth touching first are Temperature and Max Tokens. The
rest, by group:

- Sampling: Temperature, Max Tokens, Top P, Top K, Min P, Typical P, Seed (`-1` for random).
- Penalties: Repeat Penalty, Repeat Last N, Frequency Penalty, Presence Penalty.
- Mirostat: Mirostat Mode, Mirostat Tau, Mirostat Eta, Mirostat M.
- Backend: Backend, Output Json, and a Server subgroup holding Server Base Url, Server Api Key, Server
  Model, Server Timeout Sec, Server Slot, Server Cache Prompt, Server Autostart, Server Shutdown On
  Exit, Server Start Timeout Ms and Server Ready Timeout Ms.
- Advanced: Server Extra Body, merged into the server request body, and Extra Options, merged into
  the emitted options and overriding anything set above it. Use them for backend features that have
  no typed export here.

`LocalAgentDemoHarness` is a `Node` that gives any scene the repo's headless run contract. Drop it
under the scene root and it parses `--run-frames=N`, `--shoot=<path.png>` and `--shoot-frames=N` from
the command line. Point Report Source at the node that answers `demo_report() -> Dictionary`, or
leave it empty to use the parent. It prints `<Report Prefix><Report Suffix>={...}` followed by
`LA_RUN_COMPLETE={"code":N}`, then quits. Turn on Count Physics Frames for anything measuring a
simulation, because render frames are not fixed-rate and a run ended after N of them contains a
machine-dependent number of simulation steps.

## Quickstart 1: chat with a local model

Add a `LocalAgent` node, type a system prompt into its inspector, then instance
`addons/local_agents/agents/ui/ChatPanel.tscn` under a `Control` and point its Agent property at the
agent. That is a working conversation with no script. `examples/AgentQuickstart.tscn` is exactly
those two nodes plus layout, and it contains no script at all.

The code you actually write is the part that reacts to a reply:

```gdscript
extends Node

@onready var agent: LocalAgent = $Agent

func _ready() -> void:
    agent.think_completed.connect(_on_reply)
    agent.think_async("Say hello in one short sentence.")

func _on_reply(result: Dictionary) -> void:
    if bool(result.get("ok", false)):
        print(String(result["text"]))
    else:
        push_warning("Local Agents: %s" % String(result.get("error", "unknown")))
```

`think_async()` runs the model on a worker thread and delivers the result on the main thread through
`think_completed`, so the game keeps drawing. It returns `false` and starts nothing when the agent is
unavailable or a job is already in flight. There is a blocking `think()` that returns the same
Dictionary directly, but it freezes the frame until the model finishes, so keep it for tools and
tests. The Dictionary carries `ok` and `text`, and `error` when `ok` is false.

To have the model drive behaviour instead of producing text, connect
`action_requested(action, params)` and decide in your own code what each action means.

### What happens with no model installed

Nothing falls back to a canned reply. Which failure you get depends on which piece is missing:

- No native extension, or no `AgentNode` class registered: `think()` returns
  `{"ok": false, "error": "agent_unavailable"}`, and `think_async()` returns `false` and emits the
  same Dictionary on `think_completed`.
- Extension loaded but no `AgentRuntime` singleton: `think_async()` emits
  `{"ok": false, "error": "runtime_unavailable"}`.
- Extension and runtime present but no `.gguf` resolves: the native `generate()` returns
  `{"ok": false, "error": "model_not_loaded"}`.

`LocalAgentStatus.check()` tells you which of those you are in before you ask. It returns a
fixed-shape Dictionary whose keys are always present, including `level` (`READY`, `DEGRADED` or
`BLOCKED`), `blockers` ordered by the order you have to fix them in, and `next_step`, one sentence
for the topmost blocker. The blocker names are `extension_missing`, `autoload_missing`,
`model_missing` and `model_not_loaded`.

A missing Piper voice and a missing voxel backend land in `warnings` instead, and neither stops
generation. Only the voice moves `level` to `DEGRADED`, because Piper ships with the addon so its
absence means the install is incomplete. zylann.voxel is an optional third-party dependency that only
`LocalAgentSimWorld` in SPHERE mode needs, so counting it would leave a perfectly good chat install
reporting a permanent "1 optional feature unavailable". Ask for it explicitly with
`LocalAgentStatus.warnings_for({"voxel": true})` when your node actually needs it.

There is an offline path in the addon, but it belongs to creature cognition rather than to
`LocalAgent`. `LocalAgentCognitionScheduler` resolves an escalation with a synchronous heuristic
teacher when no model is available, which still plays correctly and still writes training traces.
`LocalAgentConversation` has its own Canned Lines for the same reason.

## Quickstart 2: creatures on flat ground

Add a `LocalAgentCreatureSpawner`, set Counts to `{"rabbit": 8, "fox": 2}`, and press play. You get a
floor, a scattered population, and creatures picking their own actions on the fast brain with no
planet and no material field. `LAActionRegistry.ACTIONS` holds the 15 labels they choose from, in
order: flee, hunt, throw_rock, scavenge, graze, drink, seek_water, flock, wander, rest, migrate,
investigate, come, stay, follow. The last three are player companion commands a bonded creature obeys,
and they no-op on a wild creature with no bond target. Both consumers iterate the whole array, so all
15 are in play for the fast tier at `creatures/cognition/CognitionScheduler.gd:513` and for the model
at `creatures/cognition/FunctionGemmaClient.gd:158`. Add a `Camera3D` to see them.

To give them a slow brain as well, add a `LocalAgentLlmService` and a `LocalAgentCognitionScheduler`,
point the scheduler's Llm Service at the service, point the spawner's Cognition Scheduler at the
scheduler, and turn on the spawner's Llm Enabled. That is the whole hookup, and it is what
`examples/ThinkingCreatureDemo.tscn` does: a spawner, a camera, a light, an LLM service, a scheduler
and a harness, with the script owning only the report payload.

From code, the spawner does the same job in two lines:

```gdscript
extends Node3D

@onready var spawner: LocalAgentCreatureSpawner = $Spawner

func _ready() -> void:
    spawner.counts = {"rabbit": 8, "fox": 2}
    spawner.spawn()
```

`spawn()` removes any creatures this spawner made earlier, so calling it twice replaces the
population rather than stacking a second one on top. `spawned()` returns the ones still alive.
Assigning `counts` directly converts fine, but `set("counts", {...})` with an untyped literal is
silently dropped, so pass a typed local if you have to go through `set()`.

## Quickstart 3: a whole world from one node

Add a `LocalAgentSimWorld`, pick a World Type, set the bounds, and press play. It composes the planet
body, the material field, the ecology and the founding population behind one node, with no game
shell, so no HUD, menus, disasters or save system. `examples/SimWorldPlanetDemo.tscn` is that node
plus a camera, a light and a harness, and its script contains no world-building code at all.

| export | mode | meaning |
| --- | --- | --- |
| `world_type` | both | `SPHERE` (cubed-sphere planet) or `FLAT` (ground plane plus a box field) |
| `build_on_ready` | both | build automatically, or call `spawn_world()` yourself |
| `radius`, `ocean_bias`, `caves_enabled`, `tides_enabled` | SPHERE | planet shape and toggles |
| `grid_res`, `grid_depth` | SPHERE | field grid resolution and layer count |
| `sun_enabled` | SPHERE | build the child sun that drives the field's solar pass |
| `flat_extent`, `flat_cell_size`, `ground_y` | FLAT | box extent, field cell size, floor height |
| `auto_spawn`, `initial_counts` | both | founding population |
| `forest_clusters` | SPHERE | forest seed clusters scattered at start, default 6 |

`forest_clusters` is read only inside the `world_type == WorldType.SPHERE` arm of `spawn_life()` at
`sim/SimWorld.gd:259`. The FLAT arm calls `_scatter_flat(counts)` and never touches it, so setting it
on a FLAT world does nothing. Put plants in `initial_counts` instead.

SPHERE needs zylann.voxel. Asking for it without the extension is a hard, named failure:
`spawn_world()` pushes `VOXEL_BACKEND_REQUIRED` and builds nothing rather than quietly doing
something else. FLAT never touches the planet scripts, which is why the SPHERE path is `load()`ed at
runtime instead of preloaded.

After the build, `material_field()`, `ecology()`, `terrain()`, `planet_body()` and `actors_root()`
hand back the composed pieces, and `has_built()` and `has_spawned()` report progress. To frame the
planet:

```gdscript
extends Node3D

@onready var world: LocalAgentSimWorld = $SimWorld
@onready var camera: Camera3D = $Camera3D

func _ready() -> void:
    var body: Variant = world.planet_body()
    if body != null:
        camera.look_at_from_position(Vector3(0.0, 0.0, world.radius * 3.0), body.center(), Vector3.UP)
```

Raise the camera's Far, or the planet clips out of view.

## The two adapter contracts

The creature behaviour stack is decoupled from the world through two duck-typed interfaces. To
support a new kind of cognizer or a new terrain you provide the methods, you do not patch the actor.

### Cognizer

`LACognition`, the per-creature brain, talks to whatever is cognizing only through
`LACognizerAdapter`. It never names a `LocalAgentCreature` field directly, so any actor exposing this
read-only surface reuses the brain unchanged. The adapter's accessors are static, so nothing is
allocated per decision.

- Drives: `energy` and `max_energy`, `hydration` and `max_hydration`, `health` and `max_health`.
- Body: `global_position`, `breath_capacity` and `_breath`, `_panic_timer`, `_material`. The last
  four are read through `senses(c, temp_fallback)`, which returns `{health, fear, o2, temp}`, so the
  brain never touches the private field names.
- Control: `llm_enabled`, the slow-brain opt-out.
- Social: `species` and `family_id`, plus `neighbours(c)`, which scans the `species_<name>` group.

### Terrain

A creature talks to its terrain only through this surface, so it can stand on a flat floor or a voxel
planet with the same code. `LAFlatGroundTerrain` and `LAVoxelTerrainService` both implement it, and
they differ only in geometry.

```
up_at(pos) -> Vector3                          # local "up" at a world point
planet_center() -> Vector3                     # the centre all radial math is measured from
planet_radius() -> float                       # distance from that centre to the ground datum
sea_radius() -> float                          # radius of the sea shell (<= 0 or -INF means no sea)
surface_point(dir) -> Vector3                  # where the ray centre->dir meets the ground (NAN-vec if none)
surface_radius(dir) -> float                   # distance centre->that point (NAN if none)
ground_point(pos) -> Vector3                   # the ground point directly below a world point
altitude_at(pos) -> float                      # height above local ground (> 0 air, < 0 underground)
is_planet() -> bool                            # radial-up planet, false for flat
is_ready_at(pos) -> bool                       # is the ground under pos queryable yet
raycast_terrain(from, dir, max) -> Dictionary  # {hit, position, normal}
carve_sphere(pos, r) -> void                   # destructive edit, a no-op on flat ground
```

`LAFlatGroundTerrain` is the plane `y == ground_y` with +Y up, and it is the standalone library
terrain. It puts its synthetic planet centre 100000 units below the plane, which makes the radial up
`Vector3.UP` to within about 1e-5 while `surface_point()` still solves the exact ray-plane crossing,
so the sphere movement path runs unchanged on flat ground without losing horizontal precision. It has
no sea, so land walkers never hit coast avoidance.

`LAVoxelTerrainService` is the cubed-sphere planet, owned by `LAPlanetBody`, and it adds the voxel
operations the flat adapter has no use for: `fill_sphere()`, `fill_box()`, `fill_rock()`, `sdf_at()`,
`is_solid()`, `attach_viewer()` and `build_planet()`.

`Creature.setup()` defaults `terrain` to a fresh `LAFlatGroundTerrain` when none is injected, so a
bare creature never null-derefs its movement path.

## Wiring a creature by hand

`LocalAgentCreature` has one hard dependency and three optional injectors. All three optional wires
are guarded, so a creature runs on its pure fast brain with none of them.

| call | injects | what its absence means |
| --- | --- | --- |
| `setup(_terrain, _config: Dictionary, _genome_arg = null)` | terrain, plus the species config | terrain defaults to `LAFlatGroundTerrain` |
| `set_material_field(w)` | the shared `LAMaterialField3D` substrate | no field reads at all, listed below |
| `set_ecology(e)` | the `LAEcologyService`, which owns `broadcast_scare()`, `broadcast_seismic()`, `spawn()` and the population dynamics | no ecology broadcasts |
| `set_cognition_scheduler(s)` | the shared slow brain | fast and reinforced brain only, no LLM escalation |

Leaving `set_material_field()` unwired removes a lot more than a temperature probe. Every field read
in the creature stack sits behind a `c._material == null` early return, so each of these silently
stops happening. A creature without a field loses:

- Drinking. `CreatureThirst.gd:16` needs `is_water_at()`, so hydration only ever falls.
- Blood deposits on injury (`Creature.gd:412`) and detritus on decay (`CreatureRagdoll.gd:227`).
- Scent tracking, both the prey trail at `CreatureSenses.gd:160` and the food trail at
  `CreatureThink.gd:267` and `CreatureThink.gd:366`.
- Chemical sense, the whole learned scent-valence path at `CreatureChemSense.gd:151`.
- Waste and detritus deposits at `CreatureExcretion.gd:49-54`.
- Wind push and water current at `CreatureFieldForces.gd:38-52`.
- Every temperature effect. `CreatureMetabolism.tick_environment()` at `CreatureMetabolism.gd:89`
  returns early, so nothing combusts, overheats or freezes. Herbivore digestion loses its temperature
  term at `CreatureDigestion.gd:74-82`. Carcass decomposition falls back to the dry-land constant at
  `CreatureRagdoll.gd:246-254` instead of reading warmth and snow depth.
- Drowning, which reads `is_submerged_at()` at `CreatureMetabolism.gd:152`.
- Fever heat radiated back into the world at `CreatureDisease.gd:103`.
- Water-site nesting for aquatic nesters at `CreatureNesting.gd:67`.
- The `at_water` context the scheduler builds for an escalation at `CognitionScheduler.gd:392`, which
  silently becomes false.

Nothing on that list errors. Each one just stops happening, so a fieldless creature reads as alive but
oddly inert. Wire the field whenever you want any of it.

`setup_standalone(config_source, opts)` is the one-call version: it supplies an `LAFlatGroundTerrain`
and leaves all three optional injectors unset, and that absence is the pure fast-brain default.
`config_source` may be a Dictionary, a `.json` path, a species id like `"rabbit"`, or `""` for a
generic walker. `opts` may carry `ground_y` and `cognition_scheduler`.

`creatures/Creature.tscn` stores `standalone_on_ready = true`, so a Creature dragged into a scene
self-configures from its Standalone Species and Ground Y properties. The bare script path the ecology
uses starts from the export default of `false`, so a sim creature never self-configures over the
`setup()` the world is about to call.

## Adding a species

Species stats live in `addons/local_agents/creatures/species/<class>/<kind>.json`, clustered by
taxonomic folder: `mammals/`, `birds/`, `insects/`, `people/`, `aquatic/`, `plants/`. Drop a new file
in and it loads automatically. The folder name is injected as `host_class` unless the file sets it,
so anything keyed on taxonomic class stays data-driven with no per-species field to maintain.

```json
{
  "species": "otter", "diet": "carnivore", "speed": 4.2, "size": 0.5,
  "color": [0.35, 0.25, 0.18], "sense_radius": 10.0,
  "preys_on": ["fish"], "flees_from": ["fox"], "herd": false,
  "max_energy": 90.0, "metabolism": 2.0, "max_age": 120.0
}
```

JSON cannot hold Godot types, so `LASpeciesLibrary` converts on read: `"color": [r, g, b]` or
`[r, g, b, a]` becomes a `Color`, and the `"preys_on"` and `"flees_from"` string arrays become
`PackedStringArray`. Load one with `LASpeciesLibrary.load_config("otter")`, or from an explicit path
with `LASpeciesLibrary.load_path(path)`. `known_kinds()` lists every id that has a file, and
`convert(raw)` normalizes a Dictionary you built yourself. `setup_standalone("otter")` resolves the
id for you.

Read `creatures/species/mammals/rabbit.json` for the full field set, which covers flocking, eye field
of view, hearing range, nesting, breeding density and population cap.

## Demos

The example scenes are catalogued as `LocalAgentDemoEntry` resources in
`addons/local_agents/examples/demos/`, one `.tres` per demo, following the species-JSON precedent.
Each entry holds `order`, `title`, `description`, `scene_path`, `requires_model` and
`requires_voxel_backend`. Drop a resource in the directory and a row appears in
`examples/DemoLauncher.tscn`, which is also reachable from the main menu's Examples button. Nothing
lists the demos in code.

`scripts/check_demo_catalog.sh` is the gate that keeps that true. It reads the `.tres` files as text
rather than booting Godot, so it runs in milliseconds and takes no editor lock. It fails on five
conditions:

1. A demo scene has no entry. A `.tscn` directly in `examples/` counts as a demo unless it is
   `DemoLauncher.tscn` or a fragment some other scene instances as a sub-scene.
2. An entry's `scene` does not resolve to a file on disk.
3. Two entries share an `order`, which would make their row order arbitrary.
4. A `.tres` in `demos/` is not a `LocalAgentDemoEntry` at all.
5. `addons/local_agents/docs/DEMOS.md` is not what the catalogue renders to right now. The gate shells
   out to `scripts/gen_demos_doc.sh --check` for this, and fails when that script is missing or has
   lost its executable bit.

DEMOS.md is the current list, generated from the same catalogue by `scripts/gen_demos_doc.sh`. You can
run `scripts/gen_demos_doc.sh --check` on its own, but condition 5 above is what enforces it in lint.
This file deliberately does not restate the list.

`LADemoLauncher` (`examples/DemoLauncher.gd`) is the script behind that scene. It builds one
row per entry and greys out the ones this machine cannot open, with `gate_reason()` supplying the
sentence explaining why. A launcher cannot be clicked headless, so it takes a flag instead:

```bash
godot --headless addons/local_agents/examples/DemoLauncher.tscn -- --catalog-report
```

That prints one `DEMO_CATALOG={...}` line and quits. The JSON carries `entries`, the resolved
`model_path`, `voxel_backend_ok`, the current `blockers`, and a `demos` array giving each row's
`open` flag and `reason`, which is how a run proves the rows really were built and which ones this
machine can open. `scripts/check_demo_catalog.sh` answers the static half of the same question.

## Running a scene headless

Scenes carrying a `LocalAgentDemoHarness` honour `--run-frames=N` and exit on their own. Run them
with `scripts/run_demo.sh`, which takes about a second each:

```bash
scripts/run_demo.sh --list                  # which scenes honour the contract, and which do not
scripts/run_demo.sh BoxFieldDemo            # one demo, 40 frames
scripts/run_demo.sh BoxFieldDemo 200        # one demo, 200 frames
scripts/run_demo.sh --all                   # every demo that honours the contract
```

`BoxFieldDemo`, `CoreCreatureSmoke`, `SimWorldPlanetDemo`, `ThinkingCreatureDemo` and `TutorialDemo`
carry the harness today. The script detects that per scene by grep rather than from a hardcoded list,
and refuses the others up front instead of hanging on them, because a scene with no harness ignores
`--run-frames` and runs forever. Run those with the engine's own flag:

```bash
godot --headless --path . addons/local_agents/examples/GraphExample.tscn --quit-after 120
```

One scene genuinely needs a window. `addons/local_agents/game/VoxelWorld.tscn` runs its field as a
compute shader, and a headless run has no compute device, so it boots and exits 0 while reporting an
empty field: `active_cells` 0, `biomass` 0, no field gauges, where the same run windowed reports
about 27500 active cells. It fails silently rather than loudly, which makes a headless run of it a
green light that measured nothing. Use `scripts/run_sim_offscreen.sh` for that scene, and for
anything taking a screenshot.

A new `class_name` or `.gdextension` only registers after an editor scan. If Godot reports a class as
missing, run `scripts/editor_scan.sh` once and try again.
