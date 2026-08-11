# API: configuration, status and settings

Part of the [API reference](API.md).

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

---

[Back to the API reference index](API.md)
