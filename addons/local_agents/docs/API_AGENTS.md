# API: agents and chat

Part of the [API reference](API.md).

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
  [LocalAgentStatus](API_CONFIG.md#localagentstatus).
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

---

[Back to the API reference index](API.md)
