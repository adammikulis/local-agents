# API reference

This is the per-type reference for the Local Agents addon: exports as the inspector groups them, methods with their real signatures,
signals, and the configuration warnings each node shows in the editor before you press Play. `addons/local_agents/docs/USAGE.md`
covers how to assemble these into something that works.

Godot 4.7. Every file path here is relative to the project root, so you can paste one straight into a `res://` load or an editor
FileSystem search.

## Contents

- [What is public](#what-is-public)
- [Agents and chat](#agents-and-chat): [LocalAgent](#localagent), [LocalAgent3D](#localagent3d),
  [LocalAgentChatPanel](#localagentchatpanel), [LocalAgentConversation](#localagentconversation),
  [LocalAgentStatusLabel](#localagentstatuslabel), [LocalAgentLlmService](#localagentllmservice),
  [LocalAgentLlmClient](#localagentllmclient)
- [Configuration resources](#configuration-resources): [LocalAgentModelProfile](#localagentmodelprofile),
  [LocalAgentInferenceParams](#localagentinferenceparams)
- [Status and settings](#status-and-settings): [LocalAgentStatus](#localagentstatus),
  [LocalAgentSettings](#localagentsettings-and-the-project-settings), [LocalAgentManager](#localagentmanager)
- [The memory graph](#the-memory-graph): [LocalAgentGraph](#localagentgraph), [LocalAgentGraphNode](#localagentgraphnode),
  [LocalAgentGraphEdge](#localagentgraphedge), [LocalAgentGraphRule](#localagentgraphrule)
- [Simulation nodes](#simulation-nodes): [LocalAgentCreature](#localagentcreature),
  [LocalAgentCreatureSpawner](#localagentcreaturespawner), [LocalAgentCognitionScheduler](#localagentcognitionscheduler),
  [LocalAgentSimWorld](#localagentsimworld), [LocalAgentFieldBox](#localagentfieldbox)
- [Demo harness and catalogue](#demo-harness-and-catalogue): [LocalAgentDemoHarness](#localagentdemoharness),
  [LocalAgentDemoEntry](#localagentdemoentry), [LocalAgentTutorialStep](#localagenttutorialstep)

## What is public

The addon declares about 80 `class_name LocalAgent*` scripts. Most are internal modules that happen to sit in that namespace, and
this file does not document them. The types here are the ones you instantiate in a scene or assign in the inspector, plus two you
reach from code at runtime: `LocalAgentLlmClient` and the `AgentManager` autoload. Thirteen of the types carry an editor icon
(`@icon`), which is how you recognise them in the Create Node dialog: the twelve nodes LocalAgent,
LocalAgent3D, LocalAgentChatPanel, LocalAgentConversation, LocalAgentStatusLabel, LocalAgentLlmService,
LocalAgentCognitionScheduler, LocalAgentCreature, LocalAgentCreatureSpawner, LocalAgentSimWorld, LocalAgentFieldBox and
LocalAgentDemoHarness, plus the LocalAgentGraph resource. `LocalAgentStatus` and `LocalAgentSettings` are static-only and never
added to a scene.

Everything else is an implementation detail: the editor panels, the runtime plumbing (`LocalAgentLlamaServerManager`,
`LocalAgentRuntimePaths`, `LocalAgentExtensionLoader`, `LocalAgentModelSettingsStore`), the audio engine, the graph service layer
(`LocalAgentBackstory*`), and the four helper modules `LocalAgent` delegates to (`LocalAgentAgentHistory`, `LocalAgentAgentJobs`,
`LocalAgentAgentServer`, `LocalAgentAgentSpeech`). You can call them, but their signatures move without notice.

The plugin registers no custom node types. Every script here declares a `class_name`, so Godot already lists them.

## Agents and chat

### LocalAgent

`addons/local_agents/agents/Agent.gd`, extends `Node`, `@tool`.

One local LLM agent. Drop it into a scene, point it at a `.gguf`, call `think_async()`. It owns the conversation, the model choice,
optional text to speech, and an optional autonomous tick. It is `@tool` only so it can report configuration warnings while you edit:
the runtime never boots in the editor.

#### Exports, group Model
- `model_path` (String, default `""`, `@export_global_file("*.gguf")`). The weights this agent loads. Empty falls back to the
  project default.
- `system_prompt` (String, default `""`, multiline). Standing instruction at the front of every conversation. Empty uses the model
  profile's prompt or the runtime default.
- `model_profile` (LocalAgentModelProfile, default `null`). Load-time knobs. Share one profile between agents to describe the
  weights once.
- `inference` (LocalAgentInferenceParams, default `null`). Sampling knobs and which backend runs the request.
- `preload_model` (bool, default `false`). Load the weights in `_ready()` instead of on the first `think()`. Ignored for the
  llama-server backend, which loads the model in its own process.
- `use_player_settings` (bool, default `false`). Let the model the player picked in the in-game manager
  (`user://local_agents/model_settings.cfg`) override the three properties above.

#### Exports, group Speech
- `voice` (String, default `""`, placeholder `en_US-amy`). Piper voice id under `addons/local_agents/voices`, a folder name or an
  `.onnx` basename. Blank does not mute the agent, and does not mean the system voice. It resolves to `en_US-ryan-medium`
  (`SpeechEngine.gd:48`), and when that model is not on disk the engine starts a 63 MB download from rhasspy/piper-voices on first
  use. Lines spoken while that download runs use the operating system voice through `DisplayServer.tts_speak()`, and lines after it
  lands use Piper, so the system voice is the interim state rather than the destination. Set this property when you want a specific
  voice, or want no download. A headless run is silent either way.
- `speak_responses` (bool, default `false`). Say every reply out loud through Voice as well as emitting it as text.

#### Exports, group Autonomy
- `tick_enabled` (bool, default `false`). Let the native runtime tick the agent so it can emit `action_requested` without anyone
  calling `think()`.
- `tick_interval` (float, default `1.0`, range 0.0 to 60.0, suffix s). Seconds between autonomous ticks. Zero disables ticking
  outright: the native tick returns early on a non-positive interval.
- `max_actions_per_tick` (int, default `4`, range 1 to 32). Reserved. Forwarded to the native agent node, which stores it and does
  not act on it yet.

#### Exports, group Memory
- `memory_graph` (LocalAgentGraph, default `null`). Every message given to the agent and every reply it produces becomes a node in
  this graph, chained to the previous one by a `then` edge. Two agents handed the same resource write into one shared record.
- `db_path` (String, default `""`, `@export_global_file("*.db", "*.sqlite", "*.sqlite3")`). Reserved. Forwarded to the native node,
  which stores it and does not read it yet.

#### Public variables
- `agent_node` (Object). The native `AgentNode` child, or null when the extension is unavailable.
- `history` (Array). The conversation as `{"role": String, "content": String}` dictionaries.
- `inference_options` (Dictionary). Sampling settings. `configure()` replaces this wholesale.
- `load_options` (Dictionary). Load-time knobs: context window, threads, GPU layers, system prompt.

#### Signals
None of the four signal arguments are typed in the source, so a handler may declare what it needs.

- `model_output_received(text)`. The model produced non-empty text, after it was recorded in history. Also emitted by `transcribe()`
  with the transcript.
- `message_emitted(role, content)`. Re-emitted from the native node when it records a message.
- `action_requested(action, params)`. Re-emitted from the native node when an autonomous tick or a speech job produces an action.
- `think_completed(result)`. A `think_async()` job finished, on the main thread. `result` has the same shape as the return of
  `think()`.

#### think_async() and think()
```gdscript
func think_async(prompt: String, extra_opts: Dictionary = {}) -> bool
func think(prompt: String, extra_opts: Dictionary = {}) -> Dictionary
```

Use `think_async()`. It snapshots what the worker needs on the main thread, runs inference on a worker thread, and delivers the
result on the main thread through `think_completed`. It returns true when a job started and false when the agent is unavailable or a
job is already in flight. There is one in-flight job per agent and a second request is rejected rather than queued, so the caller
decides what to do.

`think()` is synchronous: it blocks the calling frame until the model finishes, which for a multi-gigabyte model is seconds of a
frozen game. Use it in editor tools, tests and headless scripts, and nowhere on the render path. Both take the same options and
produce the same result Dictionary, and `extra_opts` sits at the top of the precedence chain below.

#### The result Dictionary
The result always has `ok` (bool). On success it has `text` (String), the reply with surrounding whitespace stripped. On failure it
has `error` (String). In-process generation adds `json` (Variant) when the request asked for a JSON response format or carried a
`json_schema`.

The llama-server backend adds `provider` (always `"llama_server"`) on every result. The rest of its keys depend on how far the
request got, so read them with `Dictionary.get()` and a default rather than by subscript:

- `endpoint` (String) and `status_code` (int) are written the moment the HTTP POST returns, so every result from that point on
  carries both. The two request-building failures return before the POST: `missing_server_base_url` and `missing_messages` carry
  `ok`, `provider` and `error`, and nothing else.
- `raw` (String, the unparsed body) is on the four failures that had a body to show: `http_request_failed`, `http_status_error`,
  `invalid_json_response` and the server-reported error below. A transport failure adds `detail` (String).
- `response` (Dictionary, the parsed server body) appears once the body parses as a Dictionary, which rules out
  `invalid_json_response`.
- On success it may also carry `id`, `tool_calls`, `usage` and `json`.

Error codes, read from these four files:

- `addons/local_agents/agents/Agent.gd`
- `addons/local_agents/agents/AgentJobs.gd`
- `addons/local_agents/gdextensions/localagents/src/AgentRuntime.cpp`
- `addons/local_agents/runtime/LlamaServerManager.gd`

From the GDScript wrapper:

- `agent_unavailable`. The native `AgentNode` could not be created. This is what you get in the editor, and in a build where the
  extension failed to load.
- `runtime_unavailable`. The `AgentRuntime` singleton is missing.

From in-process generation:

- `model_not_loaded`. No weights are resident and no default model path is set.
- `sampler_init_failed`, `vocab_unavailable`, `tokenization_failed`, `llama_decode_failed`. The llama.cpp pipeline failed at that
  stage.
- `json_parse_failed`. A JSON response was required and the reply did not parse.
- `json_schema_validation_failed`. The reply parsed but did not match the schema. The result also carries `schema_reason` (String)
  and `json` (the parsed value).

From the llama-server backend:

- `missing_server_base_url`, `missing_messages`. The request could not be built.
- `http_request_failed`, `http_status_error`, `invalid_json_response`.
- `server_error`, or the server's own `error.message` string when it sent one.

From bringing a managed llama-server up, which arrive as `{"ok": false, "provider": "llama_server", "error": ..., "lifecycle":
{...}}`: `llm_unavailable_cached` (a recent attempt failed and the negative cache has not expired), `invalid_server_base_url`,
`server_model_missing`, `llama_server_binary_missing`, `llama_server_spawn_failed`, `llama_server_start_timeout`.

#### Two option dictionaries
`load_options` holds "which weights, loaded how": context size, threads, GPU layers, system prompt. `inference_options` holds "how
to sample from them": temperature, penalties, backend. They are separate because they have different lifetimes, and `configure()`
replaces `inference_options` wholesale. A durable setting stored in `inference_options` is dropped the moment anything applies a
sampling preset.

```gdscript
func configure(model_profile_config: LocalAgentModelProfile = null, inference_params: LocalAgentInferenceParams = null) -> void
```

A non-null `model_profile_config` replaces `load_options` with its `to_options()` and records its `model_path`. A non-null
`inference_params` replaces `inference_options` with its `to_options()`. Neither argument overrides this node's own Model Profile or
Inference resources.

The options for one request are built least specific first, each layer overwriting the keys of the one before it: (1)
`load_options`, (2) this node's `model_profile.to_options()` with `system_prompt` written over the top when the node's System Prompt
is not blank, (3) `inference_options`, (4) this node's `inference.to_options()`, (5) the player's in-game model settings when Use
Player Settings is on, (6) the `extra_opts` passed to this call.

Layers 1 and 2, and layers 3 and 4, are in that order on purpose: the node beats the project-wide value, so a scene-authored agent
is not silently retuned by a global preset.

#### Model path resolution
`resolve_model_path() -> String` returns the weights this agent will actually use, most specific first: (1) the player's in-game
choice when Use Player Settings is on, (2) `model_path`, (3) `model_profile.model_path`, (4) the `model_path` of the profile last
passed to `configure()`, (5) `LocalAgentStatus.resolve_model_path()`, the project-wide default. It returns `""` when nothing is
installed anywhere.

#### Methods
```gdscript
func is_runtime_ready() -> bool
func is_model_ready() -> bool
func ensure_model_loaded() -> bool
func status_text() -> String
func resolve_model_path() -> String
func submit_user_message(text: String) -> void
func clear_history() -> void
func get_history() -> Array
func set_history(messages: Array) -> void
func enqueue_action(name: String, params: Dictionary = {})
func speak(text: String, opts: Dictionary = {}) -> bool
func transcribe(opts: Dictionary = {}) -> String
func transcribe_async(input_path: String, opts: Dictionary = {}, callback: Callable = Callable()) -> int
func stop_managed_llama_server() -> Dictionary
```

`is_runtime_ready()` is true when the extension is loaded and the AgentManager autoload is registered. It does not check for a
model, and it deliberately does not use `LocalAgentStatus.is_ready()`, which is false when the Piper speech runtime is missing, a
condition that must not stop an agent from thinking. `is_model_ready()` is true when this agent resolves to some weights and the
runtime currently holds a model in memory.

`ensure_model_loaded()` puts this agent's weights in memory, blocking while the file loads. With no per-agent model named it is
exactly `LocalAgentStatus.ensure_model_loaded()`.

`status_text()` returns one or two lines for a Label: the headline, plus the next step when something is blocking.
`enqueue_action()` has no declared return type in the source.

`stop_managed_llama_server()` stops the server process this agent started, whatever the last request asked for.

#### The three speech entry points
`speak()` speaks `text` through Voice without asking the model anything, and blocks for as long as synthesis takes, roughly half a
second for a short line through python piper. Two `opts` keys reach the speech engine:

- `voice_id` (String). Speak this line in this voice instead of the node's Voice. The switch happens on the shared engine, but
  every call re-applies the node's Voice before reading `opts`, so the override lasts one line whenever Voice is set.
- `output_path` (String). Where the synthesised `.wav` is written. Blank rotates through four slots under
  `user://local_agents/tts/`, so a finished file is never overwritten while it is still loading.

`transcribe()` blocks on transcription, records the transcript as a user message, emits `model_output_received`, and returns `""` on
failure. `transcribe_async()` returns a job id, or -1 when the speech service is unavailable. Both hand `opts` to the native
`transcribe_audio`, which reads:

- `input_path` (String, required by `transcribe()`). The audio file to transcribe. `transcribe_async()` takes it as its first argument
  instead and overwrites any key of that name.
- `model_path` (String, required). The whisper model. `transcribe_async()` fails the job immediately with `whisper_model_missing` when
  it is blank, and still returns a job id rather than -1, so check the callback result, not the return value.
- `output_path` (String, optional). Where the transcript JSON is written. Blank appends `.json` to the input path.

The agent writes `runtime_directory` itself from its resolved runtime directory, so a key of that name in `opts` is discarded.

#### Configuration warnings
Delegated to `addons/local_agents/agents/AgentWarnings.gd`, in this order:

1. The native extension is not loaded, naming the library path that was expected.
2. The AgentManager autoload is missing.
3. No GGUF model was found, naming every path that was checked.
4. Speak Responses is on but the Piper runtime is missing.
5. The model file this agent names does not exist, naming the path.
6. Speak Responses is on but Voice is empty.
7. The named Voice was not found, naming the paths that were checked.
8. Tick Enabled is on but Tick Interval is 0, so the agent will never act.

The project-wide model check runs only when the node names no model of its own, since an agent pointed at its own file is not broken
because the project default is unset.

### LocalAgent3D

`addons/local_agents/agents/Agent3D.gd`, extends `CharacterBody3D`.

A character that thinks, writes the answer on a `Label3D` above its head, and plays a talk animation while it does.
`addons/local_agents/agents/Agent3D.tscn` is an instance already wired up: it holds an `Agent` node and a `ChatLabel3D`, which are
the defaults of the first two paths below. It holds no AnimationPlayer, so an instance of that scene resolves `animation_player` to
null and plays nothing until you add one.

#### Exports, group Wiring
- `agent_path` (NodePath, default `NodePath("Agent")`, `@export_node_path("LocalAgent")`). The LocalAgent that does the thinking.
  Without it the character is inert.
- `chat_label_path` (NodePath, default `NodePath("ChatLabel3D")`, `@export_node_path("Label3D")`). Empty gives a silent character
  whose replies you render yourself from `model_output_received`.
- `animation_player_path` (NodePath, default `NodePath("AnimationPlayer")`, `@export_node_path("AnimationPlayer")`). Empty gives a
  character that does not move when it speaks.

#### Exports, group Animation
- `animation_name` (StringName, default `&"bobble"`). Played when a reply arrives, if the AnimationPlayer is idle and has a clip by
  that name. A rig without one is not an error.

#### Public variables and signal
`agent` (LocalAgent), `chat_label` (Label3D) and `animation_player` (AnimationPlayer) are resolved in `_ready()` from the paths
above. The one signal is `model_output_received(text: String)`, re-emitted from the inner LocalAgent after the text has been
appended to the Label3D.

#### Methods
```gdscript
func think(prompt: String, extra_opts: Dictionary = {}) -> Dictionary
func think_async(prompt: String, extra_opts: Dictionary = {}) -> bool
func speak(text: String, opts: Dictionary = {}) -> bool
```

All three forward to the inner LocalAgent. `think()` and `think_async()` blank the Label3D first, so the old reply does not linger
while the new one is generated. `speak()` does not touch the Label3D at all, so the previous reply stays on screen while the line is
spoken. Blank it yourself if that is not what you want. With no agent resolved, `think()` returns
`{"ok": false, "error": "agent_unavailable"}` and the other two return false. This node has no configuration warnings.

### LocalAgentChatPanel

`addons/local_agents/agents/ui/ChatPanel.gd`, extends `PanelContainer`, `@tool`.

A drop-in chat window: transcript, prompt box, send button, readiness bar. Instance `addons/local_agents/agents/ui/ChatPanel.tscn`
under any Control, leave every property alone, and you have a working conversation with no script. Instance the scene rather than
attaching the script: the UI lives in the `.tscn` and the script only wires the nodes it already has (`%Transcript`, `%PromptInput`,
`%SendButton`, `%StatusLabel`, `%StatusBar`). Restyle it by editing the scene.

Speaker labels are not settings. The user's lines are prefixed `You` and the model's with the agent node's own name, so renaming the
LocalAgent node renames the speaker.

#### Exports, group Wiring
- `agent` (LocalAgent, default `null`). Empty finds a LocalAgent among this panel's own children, then among its parent's children.
  It stops there, so two panels under one parent do not grab each other's agent.

#### Exports, group Behaviour
- `run_async` (bool, default `true`). Use `think_async()` so the frame never blocks. Turning it off makes every send freeze the game
  until the model finishes.
- `send_on_enter` (bool, default `true`). Send when Enter is pressed in the text box.
- `prompt_prefix` (String, default `""`, multiline). Pasted in front of every prompt on its own line.
- `auto_load_model` (bool, default `true`). Load the resolved model on the first send if it is not loaded yet. That first send then
  pauses for as long as the load takes.

#### Exports, group Presentation
- `placeholder_text` (String, default `"Type a prompt and press enter..."`).
- `greeting` (String, default `""`, multiline). First line written into the transcript at startup, attributed to the agent.
- `show_status_bar` (bool, default `true`).
- `show_user_messages` (bool, default `true`). Off gives a one-sided feed where the agent narrates.
- `max_transcript_lines` (int, default `200`, range 20 to 2000, suffix lines). Older lines are dropped off the top.
- `user_color` (Color, default `Color(0.65, 0.78, 1.0)`). Colour of the `You` speaker tag.
- `agent_color` (Color, default `Color(0.85, 0.9, 0.95)`). Colour of the agent's speaker tag.

#### Signals
- `prompt_submitted(text: String)`. The moment a prompt is accepted, before generation starts. Carries the raw typed text without
  `prompt_prefix`.
- `reply_received(text: String)`. The model answered with non-empty text. Failures and empty replies are shown in the transcript but
  do not emit this.

#### Methods
```gdscript
func send(text: String) -> void
func clear_transcript() -> void
func append_agent_text(text: String) -> void
func refresh_status() -> void
```

`send()` behaves exactly as if the user had typed the text, so a quest trigger or a proximity volume can drive the panel without
touching its widgets. It refuses on empty text and while a reply is in flight, then refuses on any blocker
`LocalAgentStatus.check()` reports, writing that blocker's `next_step` into the status label. The one exemption is
`model_not_loaded`, and only while Auto Load Model is on, because that is the blocker `send()` resolves itself on the first prompt.
Turn Auto Load Model off and a present-but-unloaded model blocks the send like any other blocker, so load it yourself with
`LocalAgentStatus.ensure_model_loaded()`.

`clear_transcript()` empties the display and leaves the conversation the agent itself remembers.

#### Configuration warnings
The shared extension, autoload and model checks from `LocalAgentStatus.warnings_for()`. The node layout from
`addons/local_agents/agents/ui/ChatPanel.tscn` is missing, naming the five unique nodes it needs. No LocalAgent was found, when the
layout is present.

### LocalAgentConversation

`addons/local_agents/agents/Conversation.gd`, extends `Node`, `@tool`.

N LocalAgent nodes taking turns talking to each other. Drag your agents into `agents`, type a `topic`, press play. Each utterance is
appended to the transcript and recorded in `memory_graph`, chained to the previous one by an edge named `edge_name`. Personas are
not a property here: give each agent its own voice through its own System Prompt or Model Profile. Generation runs through
`think_async()`, so a turn never blocks the frame.

#### Exports, group Cast
- `agents` (Array[LocalAgent], default `[]`). The agents that take turns, in speaking order. Empty runs the canned exchange instead.
- `speaker_names` (PackedStringArray, default empty). Display names, one per agent, in the same order. Empty uses each agent node's
  own name.

#### Exports, group Conversation
- `topic` (String, default `""`, multiline). Sent with every prompt, so keep it to a sentence.
- `max_turns` (int, default `0`, range 0 to 500, suffix turns). Stop after this many utterances and emit `conversation_finished`. 0
  is unlimited.
- `context_turns` (int, default `6`, range 1 to 40, suffix turns). How many previous utterances are quoted back to the speaker as
  context.

#### Exports, group Pacing
- `auto_advance` (bool, default `false`). Take a turn every `turn_interval` seconds. Off means you call `next_turn()` yourself.
- `turn_interval` (float, default `2.0`, range 0.0 to 60.0, suffix s). A turn still waiting on the model is skipped rather than
  queued.

#### Exports, group Memory
- `memory_graph` (LocalAgentGraph, default `null`). One node per utterance, chained in order. Empty creates one when the scene runs,
  so the memory exists either way. Assign a saved `.tres` to keep it.
- `edge_name` (String, default `"then"`). Name given to the edge joining each utterance to the one before it.

#### Exports, group Fallback
- `canned_lines` (PackedStringArray, default empty). Used verbatim, in order, when no model is available. Empty uses the four-line
  built-in exchange in `DEFAULT_CANNED`.

#### Signals
- `turn_taken(speaker: String, text: String)`. Once per completed utterance, after it has been recorded in the transcript and the
  graph.
- `conversation_finished()`. `max_turns` was reached. Never emitted when `max_turns` is 0.

#### Methods
```gdscript
func next_turn() -> bool
func reset() -> void
func transcript() -> PackedStringArray
func is_using_model() -> bool
func turns_taken() -> int
```

`next_turn()` returns true when a turn was started, or completed on the canned path. False means the conversation is finished, a
turn is still in flight, or there is nobody to speak.

`reset()` clears the transcript, the turn counter and the graph, and lets the conversation run again from the top. The graph
resource is emptied in place, not replaced. `transcript()` returns the utterances so far as `"Speaker: text"` lines.

`is_using_model()` is true when a real model will produce the next line. The first call can pause briefly, because a model that is
present but not loaded is loaded here.

#### Configuration warnings
No agents assigned, so the node will speak Canned Lines. With agents assigned, the shared extension, autoload and model checks.
Speaker Names and Agents are different lengths, naming both counts.

### LocalAgentStatusLabel

`addons/local_agents/agents/StatusLabel.gd`, extends `Label`, `@tool`.

A Label that answers "is Local Agents working?" with no code. It polls `LocalAgentStatus` and shows the headline, tinted by
severity. `_ready()` returns immediately in the editor, because `refresh()` writes two serialised Label properties and would
otherwise bake the runtime status into your `.tscn`.

#### Exports, group Content
- `show_next_step` (bool, default `true`). Append the one-sentence fix for the topmost problem under the headline.

#### Exports, group Polling
- `refresh_interval` (float, default `2.0`, range 0.25 to 30.0, suffix s). Seconds between checks. The check is cheap but it touches
  the filesystem.

#### Exports, group Colours
- `ready_color` (Color, default `Color(0.45, 0.85, 0.5)`).
- `degraded_color` (Color, default `Color(0.95, 0.8, 0.35)`). Only one condition paints this today, a missing Piper speech runtime.
  A project without godot_voxel stays on `ready_color`, because `voxel_backend_missing` does not lower the level. See
  [LocalAgentStatus](#localagentstatus).
- `blocked_color` (Color, default `Color(0.95, 0.45, 0.45)`).

#### Signal and method
```gdscript
signal status_changed(level: int, headline: String)
func refresh() -> void
```

`status_changed` fires when the level or the headline changes, and `level` matches `LocalAgentStatus.Level`: 0 READY, 1 DEGRADED, 2
BLOCKED. Connect it to show a "Fix setup" button only while something is wrong. `refresh()` re-reads the status now and repaints, so
a Retry button can force a check. This node has no configuration warnings.

### LocalAgentLlmService

`addons/local_agents/agents/LlmService.gd`, extends `Node`, `@tool`.

The single shared owner of the local LLM runtime for a whole scene. It holds one LocalAgent, resolves the model path and server URL
in one place, and hands out one shared `LocalAgentLlmClient` that every consumer talks through, so a scene with twenty consumers
still runs one server on one model. Drop it into a scene, tick `enabled`, and point a `LocalAgentCognitionScheduler` at it.
`_ready()` self-configures from the exports whenever `setup()` was not called first, so a scene-placed service needs no script.

Availability is opt-in. With the service disabled, or with nothing installed, `is_available()` is false and every consumer runs its
offline path. That is correct behaviour, not an error, and `log_availability` prints one line saying which model and server were
resolved or why not.

#### Exports, group Availability
- `enabled` (bool, default `false`). Master switch. Off by default so the addon never boots a llama-server behind the player's back.
- `backend` (String, default `"llama_server"`, `@export_enum("llama_server", "in_process")`). `llama_server` talks to a process over
  HTTP and the Server group applies. `in_process` runs the weights inside the game through the native runtime.
- `log_availability` (bool, default `true`). Print one line at startup naming the resolved model and server, or the reason and the
  fix when offline.

#### Exports, group Server
- `server_url` (String, default `""`, placeholder `http://127.0.0.1:8080`). Empty follows `local_agents/llm/server_url`, which is
  the usual case. Anything typed here wins.
- `autostart_server` (bool, default `true`). Launch llama-server when nothing is answering.
- `start_timeout_ms` (int, default `30000`, range 1000 to 300000, suffix ms).
- `ready_timeout_ms` (int, default `1200`, range 200 to 60000, suffix ms).

#### Exports, group Model
- `model_path` (String, default `""`, `@export_global_file("*.gguf")`). Global rather than `res://`-scoped, because the Downloads
  tab installs models under `user://`.
- `model_profile` (LocalAgentModelProfile, default `null`). Load-time knobs shared by every request.
- `inference` (LocalAgentInferenceParams, default `null`). Sampling knobs applied to every request. Its whole `to_options()` output
  becomes the inner agent's `inference_options`, and this node then overwrites the connection keys, but which ones depends on the
  resolved backend (`LlmService.gd:191-202`). With `backend` at its default `llama_server` it writes `backend`, `server_base_url`,
  `server_autostart`, `server_start_timeout_ms`, `server_ready_timeout_ms`, and `server_model_path` when a model resolved. With
  `backend` set to `in_process` it writes only `backend` and `model_path`, and leaves every server URL, autostart and timeout key
  on the resource untouched. Either way the Server group on this node decides which server is talked to, and the rest of the
  resource's own Server subgroup survives into the request:
  `server_api_key`, `server_model`, `server_timeout_sec`, `id_slot` (from `server_slot`), `cache_prompt` (from
  `server_cache_prompt`) and `server_shutdown_on_exit`. Set an API key or a per-request model name on the resource and it is used.

#### Methods
```gdscript
func setup(options: Dictionary = {}) -> void
func resolve_model_path(preferred: String = "") -> String
func is_available() -> bool
func client()
func resolved_model_path() -> String
func resolved_server_url() -> String
func offline_reason() -> String
func status_line() -> String
```

`setup()` is the programmatic override of the exports. Recognised keys: `server_url` (passing this key also force-enables the
service, which is how a script points the sim at a server it just started), `enabled`, `model_path`, `backend`. It is idempotent:
any earlier agent and client are torn down first.

`resolve_model_path()` takes an explicit path first, then `LocalAgentStatus.resolve_model_path()`, then the runtime default, then
this service's own `MODEL_CANDIDATES` list of installed chat models. It returns `""` when nothing is installed. `client()` returns
the shared `LocalAgentLlmClient`, or null when offline, and has no declared return type. `status_line()` is one line safe to print
or drop into a Label.

The service comes online on any of: `setup({"enabled": true})`, `setup({"server_url": ...})`, the `enabled` export, a non-empty
`FUNCTIONGEMMA_URL` environment variable, or `local_agents/llm/auto_enable_when_model_present` once a model resolves. The mere
presence of a model file on disk does not switch it on.

#### Configuration warnings
The extension and model checks from `LocalAgentStatus.warnings_for()`, plus one for a service that is disabled with the auto-enable
setting off, so every consumer runs its offline path.

### LocalAgentLlmClient

`addons/local_agents/agents/LlmClient.gd`, extends `RefCounted`.

The async endpoint every consumer talks to. It wraps one LocalAgent's `think_async()` so a caller can send OpenAI-style messages
and optional tool specs without knowing anything about the agent, the backend or the server. Get one from
`LocalAgentLlmService.client()`. Do not construct it yourself unless you are building your own service: `_init(agent, defaults)`
takes the agent it wraps and the standing per-request options to send with every call.

```gdscript
func is_available() -> bool
func is_busy() -> bool
func request(messages: Array, tools: Array, opts: Dictionary, on_done: Callable) -> bool
```

`is_available()` is true when the wrapped agent still exists. It says nothing about whether a model or a server is up, because that
only shows up as an `ok: false` result. Treat a false return from `request()` the same way you treat an unavailable model.

`request()` sends `messages` as an OpenAI-style `[{"role": ..., "content": ...}]` array, and merges `opts` over the standing
defaults it was built with. A non-empty `tools` array of function specs is passed through, and `tool_choice` defaults to
`"required"` so the model must call exactly one. Set `tool_choice` yourself in `opts` or in the standing defaults to change that.
`on_done` is called on the main thread with the native result Dictionary, the same shape `LocalAgent.think()` returns.

One request is in flight per client. A second `request()` while one is running returns false immediately rather than queueing, so
the caller decides what to do: the cognition scheduler falls back to its heuristic teacher, and a commentator skips the beat. That
is what keeps one shared server honest without a queue.

## Configuration resources

### LocalAgentModelProfile

`addons/local_agents/configuration/parameters/ModelProfile.gd`, extends `Resource`.

Design-time description of one local model: which `.gguf` to load, and how to load it. Save a `.tres`, pick it in the inspector, and
the runtime reads it. It holds load-time knobs only. Sampling belongs on `LocalAgentInferenceParams`, and per-agent behaviour such
as voice and tick rate belongs on the LocalAgent node. Keeping the three apart means one profile can be shared by every agent in a
scene.

#### Exports, group Model
- `profile_name` (String, default `""`). Cosmetic label shown wherever profiles are listed.
- `model_path` (String, default `""`, `@export_file("*.gguf")`). Absolute paths work, and so does a `res://` path for a model you
  ship. Blank falls back to `local_agents/model/default_path`.

#### Exports, group Loading
- `context_size` (int, default `4096`, range 0 to 131072 or greater, suffix tok). 0 keeps whatever the model file declares.
- `threads` (int, default `0`, range 0 to 64). 0 lets the runtime pick. Note that the in-process runtime does not implement this
  knob yet.
- `gpu_layers` (int, default `0`, range 0 to 128). Transformer layers offloaded to the GPU. 0 is CPU only. Too high for your VRAM
  and loading fails.

#### Exports, group Prompting
- `system_prompt` (String, default `""`, multiline). Standing instruction prepended to every conversation with this model.

#### Exports, group Chat template
- `chat_template` (String, default `""`, multiline). Jinja template overriding the one baked into the GGUF. Only needed when a model
  ships a broken or missing template.

#### Method
```gdscript
func to_options() -> Dictionary
```

Emits the load-time options: `context_size`, `threads`, `n_gpu_layers`, `system_prompt`, `chat_template`. Zero and blank values are
omitted rather than sent as 0, so the runtime keeps its own default for that knob. These knobs only apply when the agent also names
a Model Path, here or on the node. Without one the runtime lazy-loads with its own defaults and the profile is ignored.

### LocalAgentInferenceParams

`addons/local_agents/configuration/parameters/InferenceParams.gd`, extends `Resource`.

How the model generates: sampling, penalties, and which backend runs the request. Save it as a `.tres`, tweak it in the inspector,
hand it to `LocalAgent.configure()` or assign it to an agent's Inference property. The two knobs worth touching first are
Temperature and Max tokens.

- `inference_config_name` (String, default `""`, placeholder `<default>`). Cosmetic label. Not in a group, so it sits at the top of
  the inspector.

#### Exports, group Sampling
- `temperature` (float, default `0.8`, range 0.0 to 2.0). 0 is fully deterministic.
- `max_tokens` (int, default `256`, range 1 to 8192 or greater, suffix tok). Hard ceiling on one reply. The model may stop earlier.
- `top_p` (float, default `1.0`, range 0.0 to 1.0). 1.0 disables it.
- `top_k` (int, default `0`, range 0 to 200). 0 disables it. 40 is a common choice.
- `min_p` (float, default `0.0`, range 0.0 to 1.0). 0 disables it.
- `typical_p` (float, default `1.0`, range 0.0 to 1.0). 1.0 disables it.
- `seed` (int, default `-1`). -1 draws a fresh seed per generation. Pin it to make a run reproducible. It is only emitted into the
  options when it is 0 or greater.

#### Exports, group Penalties
- `repeat_penalty` (float, default `1.1`, range 0.0 to 2.0). 1.0 is off.
- `repeat_last_n` (int, default `64`, range 0 to 2048). How far back the repeat penalty looks.
- `frequency_penalty` (float, default `0.0`, range -2.0 to 2.0). Negative values encourage repetition.
- `presence_penalty` (float, default `0.0`, range -2.0 to 2.0).

#### Exports, group Mirostat
- `mirostat_mode` (int, default `0`, `@export_enum("Off:0", "Mirostat v1:1", "Mirostat v2:2")`). Emitted as `mirostat`, so an
  override keyed `mirostat_mode` in `extra_options` or `extra_opts` adds a key nothing reads and changes nothing.
- `mirostat_tau` (float, default `5.0`, range 0.0 to 10.0). Target perplexity.
- `mirostat_eta` (float, default `0.1`, range 0.0 to 1.0). Correction rate.
- `mirostat_m` (int, default `100`, range 1 to 1000). Used by v1 only.

#### Exports, group Backend
- `backend` (String, default `""`, `@export_enum("in_process", "llama_server")`). Blank omits the key entirely, and the runtime
  treats a request with no `backend` as in-process. Only `LocalAgentLlmService` consults `local_agents/llm/backend`. A plain
  LocalAgent does not. Use the inspector's revert arrow to clear the field.
- `output_json` (bool, default `false`). Ask the model to reply with strict JSON. Only useful when your prompt describes a JSON
  shape.

#### Exports, group Backend, subgroup Server
Every property below is prefixed `server_` in code and shown without the prefix in the inspector.

- `server_base_url` (String, default `""`, placeholder `http://127.0.0.1:8080`). Blank omits the key, and the runtime falls back to
  its own built-in `http://127.0.0.1:8080`.
- `server_api_key` (String, default `""`). Stored as plain text in the saved `.tres` and shown unmasked in the inspector. Do not put
  a secret you care about here, and do not commit the file.
- `server_model` (String, default `""`). Model name to request from a server hosting several.
- `server_timeout_sec` (int, default `120`, range 1 to 600 or greater, suffix s).
- `server_slot` (int, default `-1`, range -1 to 32). Pin this agent to one server slot so its KV cache is not shared. -1 lets the
  server choose. Emitted as `id_slot`.
- `server_cache_prompt` (bool, default `true`). Let the server reuse the cached prefix of a repeated prompt. Emitted as
  `cache_prompt`.
- `server_autostart` (bool, default `true`).
- `server_shutdown_on_exit` (bool, default `true`). Off keeps a warm server between runs.
- `server_start_timeout_ms` (int, default `30000`, range 0 to 120000 or greater, suffix ms).
- `server_ready_timeout_ms` (int, default `1200`, range 0 to 60000 or greater, suffix ms).

#### Exports, group Advanced
- `server_extra_body` (Dictionary, default `{}`). Extra JSON fields merged into the server request body, for backend features with
  no property here.
- `extra_options` (Dictionary, default `{}`). Merged last into the emitted options, so it overrides everything above.

#### Method
```gdscript
func to_options() -> Dictionary
```

Blank strings and sentinel values (a -1 slot, a non-positive timeout) are omitted so the backend keeps its own default.
`extra_options` is merged last and wins over everything else.

These fifteen keys are always emitted, whatever their values: `temperature`, `max_tokens`, `top_p`, `top_k`, `min_p`, `typical_p`,
`repeat_penalty`, `repeat_last_n`, `frequency_penalty`, `presence_penalty`, `mirostat`, `mirostat_tau`, `mirostat_eta`,
`mirostat_m` and `output_json`.

Three more are always emitted from the Server subgroup: `cache_prompt`, `server_autostart` and `server_shutdown_on_exit`.

The last ten are emitted only when they are set: `backend`, `server_base_url`, `server_api_key` and `server_model` when the string
is non-blank after trimming, `server_timeout_sec`, `server_start_timeout_ms` and `server_ready_timeout_ms` when positive, `id_slot`
when `server_slot` is 0 or greater, `seed` when it is 0 or greater, and `server_extra_body` when the Dictionary is non-empty.

Use that list when you build an `extra_opts` Dictionary by hand, since an override only lands if it uses the emitted key name.

## Status and settings

### LocalAgentStatus

`addons/local_agents/runtime/AgentStatus.gd`, extends `RefCounted`, `@tool`. Static only. Never instantiate it.

The single answer to "is Local Agents ready, and if not, what do I do about it?"

#### check()
```gdscript
static func check() -> Dictionary
```

Every key below is always present, so a caller never branches on absence.

| Key | Type | Meaning |
| --- | --- | --- |
| `level` | int | `Level.READY` (0), `Level.DEGRADED` (1) or `Level.BLOCKED` (2). |
| `ready` | bool | True only when `level` is READY. |
| `headline` | String | One line naming the state, safe to drop into a Label. |
| `next_step` | String | One actionable sentence for `blockers[0]`, or `""` when nothing blocks. |
| `blockers` | PackedStringArray | Reasons generation cannot happen, in fix order. |
| `warnings` | PackedStringArray | Optional features that are unavailable. These never gate generation, and only some of them lower `level`. |
| `extension_ok` | bool | The native GDExtension is loaded. |
| `extension_error` | String | The loader's error text, or `""`. |
| `expected_library_path` | String | Where the native library was expected for this platform. |
| `autoload_ok` | bool | The AgentManager autoload is registered. |
| `model_path` | String | The GGUF the project resolves to, or `""`. |
| `model_candidates` | PackedStringArray | Everything `resolve_model_path()` would try, in order. |
| `model_loaded` | bool | The runtime currently holds a model in memory. |
| `runtime_dir` | String | The resolved platform runtime directory. |
| `speech_ok` | bool | The runtime reports Piper installed. False whenever the extension itself is unavailable. |
| `voxel_backend_ok` | bool | `ClassDB` has `VoxelLodTerrain`, meaning godot_voxel is installed. |

`blockers` is ordered by the order you have to fix them in, which is what lets `next_step` be a single sentence and lets a UI render
a checklist without knowing anything about the runtime. The order is `extension_missing`, `autoload_missing`, `model_missing`, then
`model_not_loaded` (a model file is present but not in memory, appended only when the extension loaded, and mutually exclusive with
`model_missing`). The two warning codes are `speech_runtime_missing` and `voxel_backend_missing`. All six are exposed as the
constants `BLOCK_EXTENSION_MISSING`, `BLOCK_AUTOLOAD_MISSING`, `BLOCK_MODEL_MISSING`, `BLOCK_MODEL_NOT_LOADED`,
`WARN_SPEECH_MISSING` and `WARN_VOXEL_MISSING`. Compare against those, not against string literals.

`level` is BLOCKED when `blockers` is non-empty. Otherwise it is DEGRADED when `warnings` holds a code listed in the
`LEVEL_WARNINGS` constant, and READY in every other case, `warnings` non-empty included. `LEVEL_WARNINGS` holds
`WARN_SPEECH_MISSING` alone today, so read the two warning codes like this:

- `speech_runtime_missing` lowers `level` to DEGRADED. Piper ships with the addon, so a missing speech runtime means the addon's
  own install is incomplete and `speak()` will not work.
- `voxel_backend_missing` leaves `level` at READY. `addons/zylann.voxel/` is a third-party dependency that only
  `LocalAgentSimWorld` in SPHERE mode needs, and a chat-only project will never install it. It stays in `warnings`, where a node
  that genuinely needs it picks it up through `warnings_for_state(state, {"voxel": true})`.

That matters for any UI keyed on `level`: on a working chat install with no godot_voxel, `check()` returns `level == Level.READY`
with `warnings == ["voxel_backend_missing"]`, so `LocalAgentStatusLabel` paints `ready_color`, not `degraded_color`. Read
`warnings` directly if you want to surface the missing backend anyway.

`check()` re-probes the filesystem, the ClassDB and the extension loader on every call, so a UI drawing several rows per tick
should call it once and pass the result to `warnings_for_state()`.

#### load_model()
```gdscript
static func load_model(path: String, options: Dictionary = {}) -> bool
```

This is the one sanctioned way to load a model. Returns true when `path` is resident afterwards, and false immediately when `path`
is empty or the runtime is unavailable. The native `AgentRuntime::load_model` always unloads and reloads from disk and never
short-circuits on an already-resident path, so "what is resident" has to be tracked. This function tracks it under a Mutex and
returns early when the requested path is already resident. Tracking it anywhere else is how an agent ends up silently generating on
someone else's weights.

On arity: the native method is bound as `load_model(model_path, options)` with no default for `options`, so calling the singleton
with the path alone silently fails, which is what once left the chat panel and three demos unable to generate on an otherwise
healthy install. `LocalAgentStatus.load_model()` defaults `options` to `{}` and always forwards both arguments, so calling it with
one argument is safe. Do not reach past it to `Engine.get_singleton("AgentRuntime")`.

#### Other static methods
```gdscript
static func is_ready() -> bool
static func headline() -> String
static func next_step() -> String
static func resident_model_path() -> String
static func ensure_model_loaded(options: Dictionary = {}) -> bool
static func warnings_for(needs: Dictionary) -> PackedStringArray
static func warnings_for_state(state: Dictionary, needs: Dictionary) -> PackedStringArray
static func resolve_model_path() -> String
static func candidate_paths() -> PackedStringArray
static func expected_library_path() -> String
```

`ensure_model_loaded()` loads the project's resolved model if nothing is loaded yet, and returns false when the extension is
unavailable. `resident_model_path()` returns the path `load_model()` believes is resident, or `""`.

`warnings_for()` builds the strings a node's `_get_configuration_warnings()` returns. `needs` selects which checks apply, so each
node stays a one-line forwarder. Recognised keys and their defaults: `extension` (true), `autoload` (false), `model` (false),
`speech` (false), `voxel` (false).

`resolve_model_path()` is the one model-resolution owner: the explicit `local_agents/model/default_path` if that file exists, then
the runtime's own default, then each entry in `local_agents/model/search_paths` in order. `candidate_paths()` returns everything it
would try, for "checked: ..." messages. `expected_library_path()` returns the platform-specific native library path, or `""` on a
platform that is not macOS, Linux or Windows.

### LocalAgentSettings and the project settings

`addons/local_agents/runtime/Settings.gd`, extends `RefCounted`, `@tool`. Static only.

The one registry of Local Agents project settings. `addons/local_agents/plugin.gd` publishes every entry as a typed, hinted row in
Project Settings, and every consumer reads back through the typed getters here. Adding a setting is one record in `SPECS`. The
file's own rule is that only settings something reads get registered, and `local_agents/runtime/fail_fast` is currently the one
exception.

Resolution order is ProjectSetting, then environment variable, then default. A String setting that is blank and an array setting
that is empty both count as unset, so the env var or the default wins. A `false` or a `0` does not, because those are choices
someone may have made deliberately.

| Setting | Type | Default | Env var | Read by |
| --- | --- | --- | --- | --- |
| `local_agents/model/default_path` | String, global file `*.gguf` | `""` | none | `LocalAgentStatus.resolve_model_path()` and `candidate_paths()` |
| `local_agents/model/search_paths` | PackedStringArray | three `user://local_agents/models/...` Qwen3 paths | none | `LocalAgentStatus.resolve_model_path()` and `candidate_paths()` |
| `local_agents/llm/server_url` | String | `http://127.0.0.1:8080` | `FUNCTIONGEMMA_URL` | `LocalAgentLlmService` |
| `local_agents/llm/backend` | String, enum `llama_server,in_process` | `llama_server` | none | `LocalAgentLlmService`, only when its own Backend resolves to a blank string |
| `local_agents/llm/auto_enable_when_model_present` | bool | `false` | none | `LocalAgentLlmService` availability, and its configuration warning |
| `local_agents/runtime/fail_fast` | bool | `true` | none | Nothing. Registered but unread, so setting it changes no behaviour today |
| `local_agents/editor/enabled` | bool | `false` | none | `addons/local_agents/plugin.gd`, to auto-open the bottom panel. Written by the panel's own Activate button |

The three default search paths, in order, are `user://local_agents/models/qwen3-4b-instruct/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`,
`user://local_agents/models/qwen3-1_7b/Qwen3-1.7B-Q4_K_M.gguf` and
`user://local_agents/models/qwen3-0_6b-instruct/Qwen3-0.6B-Q4_K_M.gguf`. The first file that exists wins.

`FUNCTIONGEMMA_URL` doubles as a switch: `LocalAgentLlmService` treats a non-empty value as a reason to come online.

#### Static methods
```gdscript
static func specs() -> Array
static func get_value(name: String) -> Variant
static func get_string(name: String) -> String
static func get_bool(name: String) -> bool
static func get_int(name: String) -> int
static func get_float(name: String) -> float
static func get_string_array(name: String) -> PackedStringArray
```

`get_value()` pushes a warning and returns null for an unknown setting name, so prefer the typed getters.
`addons/local_agents/plugin.gd` seeds only absent keys, so re-enabling the plugin never overwrites a value you set.

### LocalAgentManager

`addons/local_agents/agent_manager/AgentManager.gd`, extends `Node`.

The `AgentManager` autoload, registered by the plugin. `LocalAgentStatus.check()` reports whether it is there as `autoload_ok`, and
`LocalAgent.is_runtime_ready()` is false without it. It exists because the saved model and inference configuration has to outlive
any one scene, so it owns a `ConfigList` resource and persists every change made to it.

Reach it as `/root/AgentManager`, never by instancing the script. Most projects never call it at all: assign a Model Profile and an
Inference resource on the LocalAgent node instead. Call it when you are building setup UI, which is what the addon's own bottom
panel does.

The shipped `addons/local_agents/configuration/parameters/ConfigList.tres` is a read-only seed, because `res://` cannot be written
in an exported build. `_ready()` calls `_ensure_config_list()`, which copies the seed to
`user://local_agents/config/ConfigList.tres` at startup, before anything has been applied, added or removed
(`AgentManager.gd:21-22`, `:53-59`, `:75-76`). Every later read prefers that copy. So editing the `res://` seed after the addon has
run once has no effect, and the fix is to delete the `user://` copy rather than to look for a write that triggers it.

#### Public variables and signals
- `config_list` (Resource). The `ConfigList` holding the saved profiles and the current and last-good selections.
- `agent` (Node). The LocalAgent the manager configures. Built on demand, or replaced by `register_agent()`.
- `agent_ready(agent)`. The manager has an agent to configure.
- `configs_updated()`. A configuration was applied, added or removed. The setup UI redraws on this.

#### Methods
```gdscript
func apply_model_config(params: LocalAgentModelProfile) -> void
func apply_inference_config(params) -> void
func add_model_config(params: LocalAgentModelProfile) -> void
func remove_model_config(index: int) -> void
func add_inference_config(params) -> void
func remove_inference_config(index: int) -> void
func get_model_configs() -> Array
func get_inference_configs() -> Array
func set_autoload_last_good_model(enabled: bool) -> void
func set_autoload_last_good_inference(enabled: bool) -> void
func register_agent(agent_instance: Node) -> void
```

`apply_model_config()` makes `params` the active profile, writes its `to_options()` into the agent's `load_options`, records it as
last-good, saves, and emits `configs_updated`. It deliberately leaves `inference_options` alone, and it does not inject
`params.model_path`, because which weights load is owned by `LocalAgentStatus.resolve_model_path()`. `apply_inference_config()` is
the same shape and calls `agent.configure(null, params)`, which replaces `inference_options` wholesale. Both push a warning and
still save when no agent exists yet, so a configuration chosen before the runtime came up is applied later.

The rest of the surface:

- `add_model_config()` and `add_inference_config()` append to the saved list without changing the active selection.
- `remove_model_config()` and `remove_inference_config()` ignore an out-of-range index and do nothing.
- `get_model_configs()` and `get_inference_configs()` hand back the live Arrays rather than copies, so go through the add and
  remove methods when you want the change written to disk.
- `set_autoload_last_good_model()` and `set_autoload_last_good_inference()` control whether `_ready()` re-applies the last-good
  selection on the next run.

`register_agent()` hands the manager an agent you built yourself, applies the current model profile and inference config to it, and
emits `agent_ready`. `apply_inference_config()` and `add_inference_config()` declare `params` untyped, but the value they expect is
a `LocalAgentInferenceParams`, which is what the `ConfigList` Array they write into is typed as.

## The memory graph

### LocalAgentGraph

`addons/local_agents/graph/Graph.gd`, extends `Resource`.

A directed graph of typed nodes and weighted edges. `LocalAgent` writes its conversation into one when you assign it to Memory
Graph, and `LocalAgentConversation` records one utterance per node. It is an ordinary Resource, so you can save it as a `.tres`,
hand the same instance to several agents to give them a shared record, or build one yourself.

Ids are assigned by the graph. `ensure_id_counters()` rescans `nodes` and `edges` for the highest id in use and numbers from one
past it, which is what makes a graph loaded from disk continue correctly. `add_node()` and `add_edge()` call it first, so you rarely
call it yourself. Note that ids are therefore reusable: remove the highest-numbered node and the next one added takes that id back.

#### Exports
- `nodes` (Array[LocalAgentGraphNode], default `[]`).
- `edges` (Array[LocalAgentGraphEdge], default `[]`).

#### Methods
```gdscript
func ensure_id_counters() -> void
func add_node(name: String = "", data: Dictionary = {}) -> LocalAgentGraphNode
func remove_node(node_id: int) -> bool
func add_edge(source_id: int, target_id: int, name: String = "", weight: float = 1.0, data: Dictionary = {}, is_bidirectional: bool = false) -> LocalAgentGraphEdge
func remove_edge(edge_id: int) -> bool
func get_node(node_id: int) -> LocalAgentGraphNode
func get_edge(edge_id: int) -> LocalAgentGraphEdge
func get_edges() -> Array[LocalAgentGraphEdge]
func update_edge_weight(edge_id: int, amount: float) -> void
func update_all_edge_weights(amount: float) -> void
```

`remove_node()` also removes every edge touching that node, and returns false when the id is not found. `add_edge()` pushes an error
and returns null when either endpoint does not exist, and with `is_bidirectional` true it also appends a reverse edge with its own
id sharing the same name, weight and data, while still returning the forward one. `update_edge_weight()` and
`update_all_edge_weights()` add `amount` to the weight, so pass a negative number to decay.

`get_node()` and `get_edge()` are linear scans, and so is every id lookup underneath the mutators. That is fine for a conversation
and wrong for a graph of thousands of nodes.

### LocalAgentGraphNode

`addons/local_agents/graph/GraphNode.gd`, extends `Resource`.

- `id` (int, default `0`). Assigned by the graph.
- `name` (String, default `""`). In a conversation graph this is the speaker or the role.
- `data` (Dictionary, default `{}`). Deep-copied on construction.

```gdscript
func _init(p_id: int = 0, p_name: String = "", p_data: Dictionary = {})
```

`LocalAgentConversation` writes `{"turn": int, "said": String}` into `data`.

### LocalAgentGraphEdge

`addons/local_agents/graph/GraphEdge.gd`, extends `Resource`.

- `id` (int, default `0`). Assigned by the graph.
- `source_id` (int, default `0`), `target_id` (int, default `0`).
- `name` (String, default `""`). The relation. Conversation edges are named `then` by default.
- `weight` (float, default `1.0`).
- `data` (Dictionary, default `{}`). Deep-copied on construction.

```gdscript
func _init(p_id: int = 0, p_source: int = 0, p_target: int = 0, p_name: String = "", p_weight: float = 1.0, p_data: Dictionary = {})
func update_weight(amount: float) -> void
```

`update_weight()` adds `amount` to the current weight rather than replacing it.

### LocalAgentGraphRule

`addons/local_agents/graph/GraphRule.gd`, extends `Resource`.

A condition plus a threshold, for driving graph changes from a predicate.

- `condition` (Callable, default `Callable()`). Called as `condition.call(variable, delta)` and expected to return an Array whose
  first two entries are a string and a bool.
- `memory_threshold` (float, default `0.0`).

```gdscript
func _init(p_condition: Callable = Callable(), p_threshold: float = 0.0)
func evaluate(variable: String, delta: float) -> Array
```

`evaluate()` returns `["", false]` when the Callable is invalid or when the result is not an Array of at least two entries.
Otherwise it returns `[str(result[0]), bool(result[1])]`.

A Callable does not serialise on a Resource, so a rule saved to a `.tres` loses its condition. Build these in code.

## Simulation nodes

### LocalAgentCreature

`addons/local_agents/creatures/Creature.gd`, extends `CharacterBody3D`, `@tool`.

One flexible creature driven by a species config. Behaviour is emergent from local rules: flee larger hunters, hunt prey, scavenge
carrion, eat plants, panic at felt or heard events, flock with same-kind neighbours, and live or die on an energy budget. `@tool` is
here only so the inspector can show configuration warnings: `_ready`, `_process` and `_physics_process` are the script's only engine
callbacks and each returns immediately in the editor, so an editor-placed creature stays inert.

Instance `addons/local_agents/creatures/Creature.tscn` rather than attaching the script. That scene stores `standalone_on_ready =
true`, so a creature dragged into a scene configures itself.

#### Exports, group Standalone
- `standalone_on_ready` (bool, default `false` on the script, `true` in the scene). Configure this creature from its species file
  during `_ready()`, with a flat-ground terrain at Ground Y. Turn it off when a world will call `setup()` for it instead.
- `standalone_species` (String, default `""`). A species id such as `rabbit`, `fox` or `bird`, backed by
  `addons/local_agents/creatures/species/**/<id>.json`. A `res://` path ending in `.json` also works. Blank uses the built-in
  generic walker. It is a plain String because `@export_enum` cannot offer an empty option, so the editor plugin supplies a
  dropdown instead.
- `ground_y` (float, default `0.0`, range -1000.0 to 1000.0, suffix m). World Y of the flat ground plane when running standalone.

#### Exports, group Cognition
- `llm_enabled` (bool, default `true`). Let this creature escalate novel situations to the language model. It needs a scheduler
  injected before it can do anything, and with no scheduler this costs nothing, because escalations resolve on the heuristic
  teacher.

#### Setup
```gdscript
func setup(_terrain, _config: Dictionary, _genome_arg = null) -> void
func setup_standalone(config_source = {}, opts: Dictionary = {}) -> void
func set_cognition_scheduler(s) -> void
func set_ecology(e) -> void
func set_material_field(w) -> void
```

`setup()` is the world path: it expresses the species config onto this individual, builds the body, and constructs the per-creature
modules. `setup_standalone()` is the library drop-in path: a flat floor and none of the sim's optional services, so a pure
fast-brain animal you can put in any scene. Its `config_source` may be a Dictionary, a `.json` path, a species id, or `""` for the
generic walker, and `opts` may carry `ground_y` and `cognition_scheduler`.

#### Stimuli and damage
```gdscript
func add_fear(source_pos: Vector3, intensity: float) -> void
func hear_call(source_pos: Vector3, from_species: String, call_type: String, caller) -> void
func take_damage(amount: float, cause: String = "", impulse: Vector3 = Vector3.ZERO) -> void
func on_struck() -> void
func die(cause: String = "", impulse: Vector3 = Vector3.ZERO) -> void
func fling(impulse: Vector3) -> void
func apply_field_force(force: Vector3, delta: float) -> void
```

`add_fear()` ignores a non-positive intensity, otherwise clamps the panic duration to between 0.6 and 7.0 seconds and forces a
decision on the next frame. `take_damage()` subtracts from `health`, deposits blood scent into the material field when one is
attached, calls `die()` at zero, and otherwise flings the body when the impulse is longer than 3.0. `die()` does not delete the node
or spawn a corpse: the creature becomes a carcass in place, falls, and rots.

`fling()` shoves a living creature with a physics impulse, so the shadow takes over, it tumbles, then it stands back up. It is
decoupled from dying. `apply_field_force()` applies a continuous force in world units per second over `delta`, which is the wind and
momentum advection path, and is inert while the creature is held, ragdolling or a carcass.

#### Carrying and querying
```gdscript
func hold_begin() -> void
func hold_end() -> void
func throw(velocity: Vector3) -> void
func is_held() -> bool
func is_hunter() -> bool
func is_mature() -> bool
func debug_heading() -> Vector3
func refresh_state_tint() -> void
static func set_behavior_highlight(category: String, col: Color, on: bool) -> void
func get_cognition()
func get_genome()
func get_family_id() -> int
func get_inspector_payload() -> Dictionary
func feed(amount: float) -> float
func food_profile() -> Dictionary
func nutrition() -> float
```

`is_held()` is true while held or ragdolling. `is_hunter()` is true for a carnivore, or for an omnivore with a non-empty `preys_on`.
`debug_heading()` returns the current steering heading, or `Vector3.ZERO` while held, ragdolling or a carcass. `feed()`,
`food_profile()` and `nutrition()` are the carcass food contract, only meaningful once dead, and `feed()` returns the energy
actually removed. `get_cognition()` and `get_genome()` have no declared return type.

#### Runtime state worth reading
These are plain variables, not exports, written by `setup()` from the species config: `species` (String, `"creature"`), `diet`
(String, `"herbivore"`), `speed` (float, `3.0`), `size` (float, `0.5`), `preys_on` (PackedStringArray), `energy` and `max_energy`
(float, `100.0`), `health` and `max_health` (float, `100.0`), `hydration` and `max_hydration` (float, `100.0`), `age` (float,
`0.0`), `max_age` (float, `90.0`), `metabolism` (float, `2.2`), `thirst_rate` (float, `1.0`), `breath_capacity` (float, `6.0`),
`breathes` (String, `"air"`, meaning lungs, against `"water"` for gills), `family_id` (int, `0`).

#### Configuration warnings
Delegated to `addons/local_agents/creatures/creature/CreatureWarnings.gd`:

- Standalone Species names an id with no species file, listing the known ids and where to add one.
- Standalone Species names a `.json` path that does not exist.
- Standalone Species is set but Standalone On Ready is off, so it will be ignored.

### LocalAgentCreatureSpawner

`addons/local_agents/creatures/CreatureSpawner.gd`, extends `Node3D`, `@tool`.

Type how many of each species you want, press play, and you get a population of standalone creatures scattered around this node,
optionally standing on a floor it builds for you. The creatures it makes are standalone ones: a flat-ground terrain at `ground_y`,
no material field, no ecology, no planet. Assign `cognition_scheduler` and turn on `llm_enabled` to also let them escalate to a
language model. `_ready()` returns immediately in the editor, so a spawner in an open scene never populates it.

#### Exports, group Population
- `counts` (Dictionary[String, int], default `{"rabbit": 5}`). Species id to how many, using the file names under
  `addons/local_agents/creatures/species/**/<id>.json`. A blank id is not valid. Assigning from code works directly, but
  `set("counts", {...})` with an untyped literal is silently dropped, so pass a typed local if you go through `set()`.

#### Exports, group Placement
- `area_extent` (Vector3, default `Vector3(16.0, 0.0, 16.0)`). Full width, height and depth in metres of the box creatures scatter
  inside, centred on this node. Creatures snap to the ground either way.
- `ground_y` (float, default `0.0`, range -1000.0 to 1000.0, suffix m). World Y of the ground plane, and where the convenience floor
  is built.
- `spawn_on_ready` (bool, default `true`).
- `placement_seed` (int, default `0`, range 0 to 65535 or greater). The same seed lays the scene out identically every run. Species
  are sorted before scattering, so the layout does not depend on the order you typed the rows.

#### Exports, group Convenience
- `build_floor` (bool, default `true`). Build a visible, collidable square floor at Ground Y, so a spawner alone is a runnable
  scene.
- `floor_size` (float, default `80.0`, range 1.0 to 500.0, suffix m).
- `floor_color` (Color, default `Color(0.32, 0.45, 0.28)`).

#### Exports, group Cognition
- `cognition_scheduler` (LocalAgentCognitionScheduler, default `null`).
- `llm_enabled` (bool, default `false`). Passed to each spawned creature, which keeps it unless its species file overrides it.

#### Methods
```gdscript
func spawn() -> void
func spawned() -> Array[Node]
func clear() -> void
```

`spawn()` calls `clear()` first, so calling it twice replaces the population rather than stacking a second one on top. `spawned()`
returns the creatures this spawner made that are still alive, since a starved or eaten one frees itself. `clear()` removes every
creature this spawner made and leaves the convenience floor in place.

#### Configuration warnings
- Counts is empty.
- A Counts key is blank.
- A Counts key names an unknown species, reusing the creature's own species validation.
- A Counts value is 0 or less.
- Area Extent has a negative component, or is flat in both X and Z so everything spawns on one spot.
- Llm Enabled is on with no scheduler assigned here.
- A scheduler is assigned but Llm Enabled is off.

### LocalAgentCognitionScheduler

`addons/local_agents/creatures/cognition/CognitionScheduler.gd`, extends `Node`.

The shared slow brain throttle. Every creature escalates rare or uncertain situations here, and this one node decides for the whole
world whether there is budget to resolve another deliberation right now, resolves it off the physics frame, and writes a training
trace. Two backends resolve an escalation: the shared `LocalAgentLlmClient` runs a function-calling request off the frame and hands
back the chosen tool call, and the heuristic teacher is a synchronous rule-of-thumb whose callback is deferred, so it too never
blocks. The teacher is the offline path and also the source of training traces when no model is loaded.

Drop it into a scene next to a `LocalAgentLlmService`, pick that service in `llm_service`, and every creature in `adopt_group` is
wired to it on ready, including creatures spawned later. That is the whole hookup.

#### Exports, group Model
- `llm_service` (LocalAgentLlmService, default `null`). Leave it empty, or leave the service disabled, and every escalation resolves
  with the heuristic teacher.
- `enabled` (bool, default `true`). Off sends every escalation straight to the teacher, which is the cheapest way to A/B the model
  against the rules of thumb.

#### Exports, group Budget
- `max_in_flight` (int, default `2`, range 1 to 16). Concurrent resolutions across the whole world.
- `max_requests_per_second` (float, default `4.0`, range 0.1 to 60.0, suffix /s). Escalations over the ceiling are dropped, and
  those creatures keep the action their fast brain already picked.
- `highlight_linger_ms` (int, default `1200`, range 0 to 10000, suffix ms). How long the thinking or queued highlight stays on a
  creature after its consult resolves. Display only.

#### Exports, group Training traces
- `write_traces` (bool, default `true`). Append one JSONL line per resolved escalation.
- `trace_dir` (String, default `"user://"`). A plain String rather than `@export_dir`, because that picker is `res://`-scoped and
  cannot express this default.
- `trace_filename` (String, default `"functiongemma_traces.jsonl"`). Lines are appended, never overwritten.

#### Exports, group Auto-adopt
- `adopt_group` (StringName, default `&"la_creatures"`). Creatures in this group are wired to this scheduler automatically. Clear it
  to wire them yourself with `set_cognition_scheduler()`.

#### Signal
- `degraded(reason: String)`. Emitted once per scheduler, the first time an escalation falls back to the teacher. `reason` names the
  cause and the fix. It is a signal rather than a print because the fallback fires per creature per second and would flood the
  console.

#### Methods
```gdscript
func setup(options: Dictionary = {}) -> void
func request(creature, cognition, sig: Dictionary, innate_action: String) -> bool
func is_thinking(c) -> bool
func is_queued(c) -> bool
func stats() -> Dictionary
func total_calls() -> int
```

`setup()` overrides the exports from code. Recognised keys: `enabled`, `llm_service`, `llm_client`, `trace_path`, `max_in_flight`,
`max_rps`. `request()` is the escalation entry point called by a creature's cognition: it returns true when the request was
accepted, meaning a result will come back asynchronously, and false when the global budget is full and the caller stays on the fast
path. It never blocks the physics frame.

`is_thinking()` and `is_queued()` are O(1) and drive a highlight. Thinking is exact while the escalation is in flight and then
lingers for `highlight_linger_ms`. Queued means the creature wanted to escalate but the budget was full. `stats()` returns
`{"in_flight": int, "total_calls": int, "llm_calls": int, "teacher_calls": int, "dropped": int}`. On leaving the tree the scheduler
prints one summary line naming how the escalations were actually resolved. This node has no configuration warnings.

### LocalAgentSimWorld

`addons/local_agents/sim/SimWorld.gd`, extends `Node3D`, `@tool`.

The one-node facade for a self-contained ecosystem sim. Pick a `world_type`, set its bounds, and call `spawn_world()`, or let it run
on `_ready()`. It composes the existing controllers behind a small export surface and adds no behaviour of its own. `@tool` is only
for the configuration warnings: every lifecycle callback returns early in the editor, so dropping the node in a scene never starts
building a planet.

godot_voxel is optional, and this node is where that is enforced. SPHERE is built out of the `zylann.voxel` GDExtension. FLAT is
not, and keeps working in a project that never installed it. Asking for SPHERE without the extension builds nothing and pushes a
`VOXEL_BACKEND_REQUIRED` error, because the repo convention is an explicit typed failure over silent degradation. The enum is
`WorldType { SPHERE, FLAT }`.

#### Exports, group World
- `world_type` (WorldType, default `SPHERE`). SPHERE grows a cubed-sphere planet and needs godot_voxel. FLAT builds a ground plane
  plus a box field volume and needs nothing beyond this addon.
- `build_on_ready` (bool, default `true`).

#### Exports, group Sphere bounds, subgroup Shape
- `radius` (float, default `250.0`, range 25.0 to 2000.0 or greater, suffix m). Relief, feature size and the field shell all scale
  from this. The numbers were tuned at 250, so 500 gives the same looking planet at twice the size.
- `ocean_bias` (float, default `3.0`, range -30.0 to 60.0, suffix m). How far the whole surface is pushed inward before relief is
  added, so a larger number means more ocean. Negative pushes outward for a drier planet.
- `caves_enabled` (bool, default `true`).
- `tides_enabled` (bool, default `false`). Passed straight through to the planet body. Nothing reads it yet, because this facade
  builds no ocean shell.

#### Exports, group Sphere bounds, subgroup Field grid
- `grid_res` (int, default `20`, range 8 to 64, suffix cells). Field cells along one edge of each of the six cube faces. Doubling it
  quadruples the grid.
- `grid_depth` (int, default `20`, range 8 to 32, suffix layers). Radial layers from the innermost crust layer out to space.

#### Exports, group Sphere bounds, subgroup Lighting
- `sun_enabled` (bool, default `true`). Add a fixed DirectionalLight3D so the field's solar pass has a real sun. SPHERE only.

#### Exports, group Flat bounds
- `flat_extent` (Vector3, default `Vector3(120.0, 40.0, 120.0)`, range 1 to 2000 or greater per axis, suffix m). Size of the box
  field volume, centred horizontally on this node with its floor at Ground Y.
- `flat_cell_size` (float, default `5.0`, range 0.5 to 25.0 or greater, suffix m). Must be greater than 0: the build divides the
  extent by it.
- `ground_y` (float, default `0.0`, range -500.0 to 500.0, suffix m).

#### Exports, group Population
- `auto_spawn` (bool, default `true`). Spawn the starting ecology as soon as the world is built and its ground is queryable.
- `initial_counts` (Dictionary[String, int], default `{}`). How many of each kind to found the world with. Empty uses
  `DEFAULT_COUNTS`, which is `{"rabbit": 14, "fox": 3, "bird": 10, "plant": 40}`. Keys are `plant`, `rock` and `tree`, which the
  ecology instances directly, or any species id under `addons/local_agents/creatures/species/` (`rabbit`, `fox`, `bird`,
  `villager`, `mouse`, `trout` and the rest). An unknown key pushes a warning and spawns nothing. Same typed-Dictionary caveat as
  the spawner's `counts`.
- `forest_clusters` (int, default `6`, range 0 to 64 or greater, suffix clusters). SPHERE only. A FLAT world gets its plants from
  `initial_counts`.

#### Methods
```gdscript
static func has_voxel_backend() -> bool
func spawn_world() -> void
func spawn_life() -> void
func planned_cell_count() -> int
func material_field() -> Variant
func ecology() -> Variant
func terrain() -> Variant
func planet_body() -> Variant
func actors_root() -> Node3D
func has_built() -> bool
func has_spawned() -> bool
```

`has_voxel_backend()` is `ClassDB.class_exists("VoxelLodTerrain")` and is safe to call from the editor. `spawn_world()` is
idempotent, and refuses with an error for SPHERE without godot_voxel and for a non-positive `flat_cell_size`. `spawn_life()` places
the founding population now, bypassing the auto gate. A SPHERE spawn otherwise waits for the top-of-planet patch to mesh and
collide, plus a few settle ticks.

`planned_cell_count()` is `6 * grid_res * grid_res * grid_depth` for SPHERE, and the extent divided by the cell size on each axis
for FLAT, so a host can size a world before building it. It returns 0 when the settings cannot produce a grid. The five accessors
return null until `spawn_world()` succeeds, and `terrain()` is duck-typed: a voxel terrain service for SPHERE, a flat ground adapter
for FLAT.

#### Configuration warnings
- World Type is Sphere but godot_voxel is not installed.
- Flat Cell Size is 0 or less.
- Flat Extent has a zero or negative component.
- Auto Spawn is on but Build On Ready is off.
- The settings ask for more than `SLOW_BUILD_CELLS` (250000) field cells, naming the count.

### LocalAgentFieldBox

`addons/local_agents/sim/material/FieldBox.gd`, extends `Node3D`.

The material field sandbox as a node. Drag it in, press play, and you get a volumetric field in box mode with a heat source at its
floor and a plane of cubes tinted by the live temperature, so you can watch warmth diffuse and rise. It owns a material field as a
child rather than extending it, so the inspector surface lives out here and the field hub stays untouched. Coordinates are local to
this node, so the box and its cubes move with its transform.

Box mode is a pure CPU substrate and runs anywhere, headless included. Only the slice visual needs a display, and it is skipped and
reported when there is none. Pair the node with a `LocalAgentDemoHarness` whose `report_source` is this node for the standard `--
--run-frames=N` report line.

#### Exports, group Volume
Every property in this group is read once when the node starts. Changing one later does not resize a running field.

- `extent` (Vector3, default `Vector3(60.0, 40.0, 60.0)`). Size of the simulated box in world units.
- `cell_size` (float, default `5.0`, range 0.5 to 20.0, suffix m). Cells per axis is `extent / cell_size`, so smaller is finer and
  slower.
- `origin_offset` (Vector3, default `Vector3.ZERO`). At zero the box is centred on X and Z with the centres of its floor cells at y
  = 0.

#### Exports, group Heat source
- `heat_enabled` (bool, default `true`). Off gives an inert volume you drive yourself by calling `add_heat()` on `field()`.
- `heat_per_frame` (float, default `40.0`, range 0.0 to 500.0, suffix C). Degrees injected per physics frame per source cell.
- `heat_burst_frames` (int, default `40`, range 0 to 6000, suffix frames). Frames the source runs before switching off. 0 never
  stops.
- `heat_source_cells` (Vector3i, default `Vector3i(3, 1, 3)`). Source footprint in cells, centred on the floor.

Heat goes in on the physics clock, which is the clock the field steps on, so the energy deposited by a given run does not vary with
the display framerate.

#### Exports, group Slice view
- `show_slice` (bool, default `true`). The plane of cubes that makes the field visible.
- `slice_axis` (String, default `"Z"`, `@export_enum("X", "Y", "Z")`). Z gives a vertical wall facing the camera, Y gives a
  horizontal floor plan.
- `slice_position` (float, default `0.5`, range 0.0 to 1.0). 0 is the low face of the box, 1 the high face.
- `cube_fill` (float, default `0.85`, range 0.05 to 1.0). Cube edge as a fraction of `cell_size`. 1.0 makes the cubes touch.
- `color_span` (float, default `60.0`, range 1.0 to 400.0, suffix C). Temperature above ambient that reaches `hot_color`. Smaller is
  a more sensitive display.
- `cold_color` (Color, default `Color(0.15, 0.2, 0.5)`). A cell at ambient.
- `hot_color` (Color, default `Color(1.0, 0.35, 0.1)`). A cell `color_span` degrees above ambient, or hotter.

The whole slice is one MultiMeshInstance3D, so it costs one draw call however many cells it covers.

#### Methods
```gdscript
func field() -> Node
func cell_dims() -> Vector3i
func demo_report() -> Dictionary
```

`field()` returns the material field this node owns, so you can drive the volume yourself. The three calls you want first do not
share a coordinate convention, so read the signatures before you pass anything:

```gdscript
func add_heat(world_pos: Vector3, amount: float, radius: float = 0.0) -> void
func temp_at(pos: Vector3) -> float
func add_water_cell(ix: int, iy: int, iz: int, amount: float) -> void
```

`add_heat()` and `temp_at()` take a position in the field's frame, which is this node's local space, with the floor of the box at
y = 0 and the box centred on X and Z unless Origin Offset moves it. `add_water_cell()` takes integer cell indices instead, and does
nothing for an out-of-bounds or solid cell. To go between the two, `cell_world_pos(ix, iy, iz) -> Vector3` gives the position of a
cell and `world_to_cell(pos) -> int` gives the linear index of a position, so a point from `cell_world_pos()` handed to `temp_at()`
lands on exactly the cell it came from.

`add_heat()`'s `radius` argument does nothing in box mode. The radius walk needs the cubed-sphere neighbour table, so a box field
heats the single cell at `world_pos` whatever radius you pass. Loop over the cells you want instead.

`demo_report()` returns `frames`, `cells`, `dims` (a `"WxHxD"` string), `top_start`, `top_now`, `bottom_now`, `flowed` (true when
the top is more than 0.5 degrees above where it started), `slice_instances`, and `slice_skipped` (the reason string, empty when the
visual was drawn). Temperatures are snapped to two decimals. Before the field exists the report omits `dims`, `slice_instances` and
`slice_skipped`. This node has no configuration warnings.

## Demo harness and catalogue

### LocalAgentDemoHarness

`addons/local_agents/runtime/DemoHarness.gd`, extends `Node`.

The headless run, report and screenshot harness for a demo scene. Drop it under any scene root, point `report_source` at the node
that knows the numbers, and that scene gains the standard command-line contract:

```
godot --headless --path . <scene>.tscn -- --run-frames=120
godot --path . <scene>.tscn -- --shoot=shot.png --shoot-frames=90
```

The report source only answers questions and never reads the command line itself. Every hook below is optional, and with none of
them the report body is `{}`:

- `demo_report() -> Dictionary`. The payload, printed as JSON. This is the normal case.
- `demo_report_json() -> String`. The payload already serialised, for when exact number formatting matters more than JSON
  conventions. It wins when present.
- `demo_exit_code() -> int`. The process exit code, default 0, so a smoke scene can fail.
- `demo_shot_info() -> String`. Extra `key=value` text appended to the `SHOT_SAVED` line.
- `demo_harness_configured(frames: int, shoot: String) -> void`. Called once, right after the command line is parsed, so the scene
  can react to the resolved settings without re-reading argv.

#### Exports, group Headless run
- `run_frames` (int, default `0`, range 0 to 100000, suffix frames). Frames to run before printing the report and quitting. 0 never
  auto-quits. `-- --run-frames=N` overrides it.
- `count_physics_frames` (bool, default `false`). Count physics frames instead of render frames. Turn it on for anything measuring a
  simulation: physics ticks are fixed-rate while render frames are not, so a run ended after N render frames contains a
  machine-dependent number of simulation steps.
- `report_source` (Node, default `null`). Empty uses the parent, so dropping the harness under a scene root works.
- `report_prefix` (String, default `"DEMO"`).
- `report_suffix` (String, default `"_REPORT"`). The default prints `PREFIX_REPORT={...}`. Clear it to print a bare `PREFIX={...}`.

#### Exports, group Screenshot
- `shoot_path` (String, default `""`, `@export_global_file("*.png")`). Empty means no screenshot. Global rather than
  `res://`-scoped, because this is an output path and `res://` is read-only in an exported build. `-- --shoot=<path>` overrides it.
- `shoot_frames` (int, default `90`, range 1 to 100000, suffix frames). `-- --shoot-frames=N` overrides it.

A scene given both flags is photographed, not measured: the screenshot branch is checked first.

#### Exports, group Exit
- `use_app_exit` (bool, default `true`). Route the quit through an `AppExit` autoload when one is registered, otherwise
  `get_tree().quit()`. The node resolves that autoload by name at runtime, so the harness works in projects that do not register it.

#### Methods and constants
```gdscript
func frames_elapsed() -> int
func emit_report() -> void
static func print_complete(code: int) -> void
```

`emit_report()` prints the report line now without quitting, so a host can force a report at any moment. The payload is serialised
with `JSON.stringify(payload, "", false)`, so fields print in the order the source declared them rather than alphabetised. The
parsed argument prefixes are exposed as `ARG_RUN_FRAMES` (`"--run-frames="`), `ARG_SHOOT` (`"--shoot="`) and `ARG_SHOOT_FRAMES`
(`"--shoot-frames="`). This node has no configuration warnings.

`print_complete()` prints `LA_RUN_COMPLETE={"code":N}`, and `COMPLETE_MARKER` holds `"LA_RUN_COMPLETE"`. It is static so a scene
with its own harness can emit the identical marker. That line is the only reliable end-of-run signal: a watchdog matching
report-shaped lines instead will match a scene's periodic progress lines and kill healthy runs.

### LocalAgentDemoEntry

`addons/local_agents/examples/DemoEntry.gd`, extends `Resource`, `@tool`.

One rung of the demo ladder, as data. Drop a `.tres` into `addons/local_agents/examples/demos/` and it appears in the launcher.
There is nothing to edit in code.

- `order` (int, default `0`, range 0 to 999). Position on the ladder, low to high. The launcher sorts on this and numbers the rows
  from it. In-tree entries are spaced by ten, so a new rung can be inserted without renumbering. Two entries sharing an order is a
  catalogue error.
- `title` (String, default `""`). The row heading. Do not number it: the launcher prefixes the position itself.
- `description` (String, default `""`, multiline). One or two sentences on what this demo shows that the rung above it did not.
- `scene_path` (String, default `""`, `@export_file("*.tscn")`). A path, deliberately not a PackedScene, loaded on click rather than
  when the menu opens. A PackedScene reference is a real dependency, so painting a twelve-row menu would load twelve demo scenes
  and their whole script graphs.
- `requires_model` (bool, default `false`). Set it when the demo can do nothing without a GGUF: the launcher greys the row out and
  prints the fix sentence for whatever is missing. Leave it false for a demo that degrades honestly, such as canned conversation
  lines or a setup checklist, since those are worth opening precisely when there is no model.
- `requires_voxel_backend` (bool, default `false`). Set it when the demo needs godot_voxel. The launcher greys the row out when
  `ClassDB` has no `VoxelLodTerrain`.

Drift between an entry and its scene is caught by `scripts/check_demo_catalog.sh`, which fails the build when an entry points at a
scene that does not exist.

### LocalAgentTutorialStep

`addons/local_agents/ui/tutorial/TutorialStep.gd`, extends `Resource`.

One step in a guided tutorial: the instruction text, what on screen it points at, and the condition that advances to the next step.
Pure data, so steps can be authored in the inspector or built in code, and nothing here knows about any particular scene.

`enum TargetKind { NONE, CONTROL, RECT, WORLD }`. NONE is a centred callout with no spotlight, CONTROL resolves `control_path`
relative to the sequencer's target root, RECT spotlights a fixed screen rectangle, WORLD projects a world-space point to screen
through the sequencer's Camera3D. `enum Advance { NEXT_BUTTON, TARGET_PRESSED, PREDICATE, SIGNAL }`: TARGET_PRESSED requires the
target Control to be a BaseButton, PREDICATE polls `advance_predicate` each frame, and SIGNAL awaits `signal_name` on
`signal_source`.

#### Exports
- `text` (String, default `""`, multiline). The instruction body.
- `title` (String, default `""`). Optional bold heading above the body.
- `target_kind` (TargetKind, default `NONE`).
- `control_path` (NodePath, default `NodePath()`). For CONTROL.
- `rect` (Rect2, default `Rect2()`). For RECT.
- `world_point` (Vector3, default `Vector3.ZERO`). For WORLD.
- `target_pad` (float, default `8.0`). Extra pixels of breathing room around the spotlight.
- `advance` (Advance, default `NEXT_BUTTON`).

#### Runtime-only variables
Callables and Signals do not serialise on a Resource, so these are assigned in code and left empty for inspector-authored
NEXT_BUTTON and TARGET_PRESSED steps.

- `advance_predicate` (Callable, default `Callable()`).
- `signal_source` (Object, default `null`).
- `signal_name` (StringName, default `&""`).

#### Static constructors
```gdscript
static func for_control(path: NodePath, body: String, heading: String = "", adv: Advance = Advance.TARGET_PRESSED) -> LocalAgentTutorialStep
static func message(body: String, heading: String = "") -> LocalAgentTutorialStep
static func for_world(point: Vector3, body: String, heading: String = "") -> LocalAgentTutorialStep
static func from_dict(d: Dictionary) -> LocalAgentTutorialStep
```

`from_dict()` builds a step from a loose Dictionary, which is handy for JSON-authored tutorials. The recognised keys mirror the
exports: `text`, `title`, `target_kind`, `control_path`, `rect`, `world_point`, `target_pad`, `advance`. `target_kind` accepts an
int or one of `"none"`, `"control"`, `"rect"`, `"world"`, and `advance` accepts an int or one of `"next"`, `"target"`,
`"target_pressed"`, `"predicate"`, `"signal"`. Anything unrecognised falls back to NONE and NEXT_BUTTON.
