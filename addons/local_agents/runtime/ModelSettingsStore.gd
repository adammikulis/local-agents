@tool
extends RefCounted
class_name LocalAgentModelSettingsStore

# Persistence layer over the two configuration Resources, for the in-game model manager.
#
# The Resources are the SCHEMA — LocalAgentModelProfile ("which model, loaded how") and
# LocalAgentInferenceParams ("how it generates"). This store owns neither shape: it holds one of
# each, round-trips them through a single ConfigFile under user://, and adds the parts that are
# genuinely player-runtime rather than design-time (the models a player registered by browsing to a
# .gguf, the folders to scan, and which model each role uses). No AgentManager autoload required,
# so this works standalone inside the voxel sim.
#
# to_llama_options() emits the exact Dictionary LocalAgentLlamaServerManager.ensure_running() reads:
# the profile's load-time keys (context_size / threads / n_gpu_layers / system_prompt) merged over
# the sampling params from InferenceParams.

const InferenceParams: GDScript = preload("res://addons/local_agents/configuration/parameters/InferenceParams.gd")
const ModelProfile: GDScript = preload("res://addons/local_agents/configuration/parameters/ModelProfile.gd")

const CONFIG_PATH: String = "user://local_agents/model_settings.cfg"

# Roles the sim can assign a distinct model to. A player may leave a role blank to fall back to the
# single active model. Kept as data so adding a role is a one-line edit, not a new branch.
const ROLES: Array[String] = ["streamer", "creature_cognition", "embedding"]
const ROLE_LABELS: Dictionary = {
	"streamer": "Streamer / commentator",
	"creature_cognition": "Creature cognition",
	"embedding": "Embedding",
}

# Which model, loaded how (the design-time schema, reused verbatim at runtime).
var profile: LocalAgentModelProfile = null

# Sampling params (the other half of the schema).
var inference: LocalAgentInferenceParams = null

# Where to look for already-downloaded models (persisted so detection survives a restart).
var hf_cache_override: String = ""
var custom_folders: PackedStringArray = PackedStringArray()

# Bring-your-own models the player registered by browsing to a .gguf. Each entry {label, path}.
var registered_models: Array = []

# Optional per-role overrides (role -> absolute path). The fallback is the profile's model_path.
var role_models: Dictionary = {}

# -- Views onto the profile ---------------------------------------------------
# The profile is the single owner of these values; these named views exist because the settings UI
# (and any game code) speaks in llama.cpp's vocabulary. Assigning through a view writes the profile.

# Absolute path of the model the player selected. Same storage as profile.model_path.
var active_model_path: String:
	get:
		return profile.model_path if profile != null else ""
	set(value):
		_ensure_profile()
		profile.model_path = value

# Context window in tokens.
var n_ctx: int:
	get:
		return profile.context_size if profile != null else 0
	set(value):
		_ensure_profile()
		profile.context_size = maxi(0, value)

# CPU threads for inference; 0 -> let the runtime pick.
var threads: int:
	get:
		return profile.threads if profile != null else 0
	set(value):
		_ensure_profile()
		profile.threads = maxi(0, value)

# Transformer layers offloaded to the GPU; 0 -> CPU only.
var n_gpu_layers: int:
	get:
		return profile.gpu_layers if profile != null else 0
	set(value):
		_ensure_profile()
		profile.gpu_layers = maxi(0, value)

# Standing instruction prepended to every conversation.
var system_prompt: String:
	get:
		return profile.system_prompt if profile != null else ""
	set(value):
		_ensure_profile()
		profile.system_prompt = value

func _init() -> void:
	_ensure_profile()
	inference = InferenceParams.new()
	inference.inference_config_name = "In-game"
	inference.temperature = 0.8
	inference.max_tokens = 512
	inference.top_p = 0.95
	inference.top_k = 40
	inference.repeat_penalty = 1.1
	inference.seed = -1

func _ensure_profile() -> void:
	if profile == null:
		profile = ModelProfile.new()
		profile.profile_name = "In-game"

# -- Custom-model registry ----------------------------------------------------

func register_model(path: String, label: String = "") -> bool:
	var trimmed: String = path.strip_edges()
	if trimmed == "":
		return false
	for entry: Dictionary in registered_models:
		if String(entry.get("path", "")) == trimmed:
			return false
	var display: String = label.strip_edges()
	if display == "":
		display = trimmed.get_file()
	registered_models.append({"label": display, "path": trimmed})
	return true

func unregister_model(path: String) -> void:
	var kept: Array = []
	for entry: Dictionary in registered_models:
		if String(entry.get("path", "")) != path:
			kept.append(entry)
	registered_models = kept

# -- Options emission ---------------------------------------------------------

# Merges the sampling params with the profile's load-time knobs into the Dictionary the llama server
# manager consumes. The profile is merged LAST so its context/threads/GPU settings win.
func to_llama_options() -> Dictionary:
	var opts: Dictionary = inference.to_options() if inference != null else {}
	if profile != null:
		var load_opts: Dictionary = profile.to_options()
		for key: String in load_opts:
			opts[key] = load_opts[key]
	return opts

# Resolves the model path a given role should use: its override if set, else the active model.
func model_for_role(role: String) -> String:
	var override: String = String(role_models.get(role, "")).strip_edges()
	if override != "":
		return override
	return active_model_path

# -- Persistence --------------------------------------------------------------

func save() -> bool:
	_ensure_profile()
	var cfg: ConfigFile = ConfigFile.new()
	cfg.set_value("inference", "temperature", inference.temperature)
	cfg.set_value("inference", "max_tokens", inference.max_tokens)
	cfg.set_value("inference", "top_p", inference.top_p)
	cfg.set_value("inference", "top_k", inference.top_k)
	cfg.set_value("inference", "repeat_penalty", inference.repeat_penalty)
	cfg.set_value("inference", "seed", inference.seed)

	cfg.set_value("model", "n_ctx", profile.context_size)
	cfg.set_value("model", "threads", profile.threads)
	cfg.set_value("model", "n_gpu_layers", profile.gpu_layers)
	cfg.set_value("model", "system_prompt", profile.system_prompt)
	cfg.set_value("model", "chat_template", profile.chat_template)
	cfg.set_value("model", "profile_name", profile.profile_name)

	cfg.set_value("paths", "hf_cache_override", hf_cache_override)
	cfg.set_value("paths", "custom_folders", custom_folders)

	cfg.set_value("custom_models", "registered", registered_models)

	cfg.set_value("active", "model_path", profile.model_path)
	cfg.set_value("active", "role_models", role_models)

	var dir: String = CONFIG_PATH.get_base_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var err: int = cfg.save(CONFIG_PATH)
	return err == OK

func load() -> bool:
	var cfg: ConfigFile = ConfigFile.new()
	var err: int = cfg.load(CONFIG_PATH)
	if err != OK:
		return false
	_ensure_profile()
	inference.temperature = float(cfg.get_value("inference", "temperature", inference.temperature))
	inference.max_tokens = int(cfg.get_value("inference", "max_tokens", inference.max_tokens))
	inference.top_p = float(cfg.get_value("inference", "top_p", inference.top_p))
	inference.top_k = int(cfg.get_value("inference", "top_k", inference.top_k))
	inference.repeat_penalty = float(cfg.get_value("inference", "repeat_penalty", inference.repeat_penalty))
	inference.seed = int(cfg.get_value("inference", "seed", inference.seed))

	profile.context_size = int(cfg.get_value("model", "n_ctx", profile.context_size))
	profile.threads = int(cfg.get_value("model", "threads", profile.threads))
	profile.gpu_layers = int(cfg.get_value("model", "n_gpu_layers", profile.gpu_layers))
	profile.system_prompt = String(cfg.get_value("model", "system_prompt", profile.system_prompt))
	profile.chat_template = String(cfg.get_value("model", "chat_template", profile.chat_template))
	profile.profile_name = String(cfg.get_value("model", "profile_name", profile.profile_name))

	hf_cache_override = String(cfg.get_value("paths", "hf_cache_override", hf_cache_override))
	custom_folders = cfg.get_value("paths", "custom_folders", custom_folders)

	registered_models = cfg.get_value("custom_models", "registered", registered_models)

	profile.model_path = String(cfg.get_value("active", "model_path", profile.model_path))
	role_models = cfg.get_value("active", "role_models", role_models)
	return true

# -- Self-test ----------------------------------------------------------------

# Round-trips a fully-populated store through save()/load() into a fresh instance and asserts every
# field survives. Uses the real CONFIG_PATH but restores whatever was there first.
static func run_selftest() -> Dictionary:
	var backup: PackedByteArray = PackedByteArray()
	var had_existing: bool = FileAccess.file_exists(CONFIG_PATH)
	if had_existing:
		var reader: FileAccess = FileAccess.open(CONFIG_PATH, FileAccess.READ)
		if reader != null:
			backup = reader.get_buffer(reader.get_length())
			reader.close()

	var store: LocalAgentModelSettingsStore = LocalAgentModelSettingsStore.new()
	store.inference.temperature = 0.42
	store.inference.top_k = 33
	store.inference.max_tokens = 777
	store.inference.seed = 12345
	store.profile.profile_name = "Selftest"
	store.profile.context_size = 8192
	store.profile.threads = 6
	store.profile.gpu_layers = 24
	store.profile.system_prompt = "You are a helpful island spirit."
	store.profile.chat_template = "{{ messages }}"
	store.hf_cache_override = "/tmp/fake_hf"
	store.custom_folders = PackedStringArray(["/models/a", "/models/b"])
	store.register_model("/models/a/custom.gguf", "My custom model")
	# Written through the view to prove it lands on the profile.
	store.active_model_path = "/models/a/custom.gguf"
	store.role_models = {"streamer": "/models/b/streamer.gguf"}
	var saved: bool = store.save()

	var loaded_store: LocalAgentModelSettingsStore = LocalAgentModelSettingsStore.new()
	var loaded: bool = loaded_store.load()
	var options: Dictionary = loaded_store.to_llama_options()

	var checks: Dictionary = {
		"saved": saved,
		"loaded": loaded,
		"view_writes_profile": store.profile.model_path == "/models/a/custom.gguf",
		"temperature": is_equal_approx(loaded_store.inference.temperature, 0.42),
		"top_k": loaded_store.inference.top_k == 33,
		"max_tokens": loaded_store.inference.max_tokens == 777,
		"seed": loaded_store.inference.seed == 12345,
		"profile_name": loaded_store.profile.profile_name == "Selftest",
		"context_size": loaded_store.profile.context_size == 8192,
		"threads": loaded_store.profile.threads == 6,
		"gpu_layers": loaded_store.profile.gpu_layers == 24,
		"system_prompt": loaded_store.profile.system_prompt == "You are a helpful island spirit.",
		"chat_template": loaded_store.profile.chat_template == "{{ messages }}",
		"view_reads_profile": loaded_store.n_ctx == 8192 and loaded_store.n_gpu_layers == 24,
		"hf_cache_override": loaded_store.hf_cache_override == "/tmp/fake_hf",
		"custom_folders": loaded_store.custom_folders.size() == 2 and String(loaded_store.custom_folders[1]) == "/models/b",
		"registered_model": loaded_store.registered_models.size() == 1 and String((loaded_store.registered_models[0] as Dictionary).get("path", "")) == "/models/a/custom.gguf",
		"active_model": loaded_store.active_model_path == "/models/a/custom.gguf",
		"role_override": loaded_store.model_for_role("streamer") == "/models/b/streamer.gguf",
		"role_fallback": loaded_store.model_for_role("embedding") == "/models/a/custom.gguf",
		"options_context": int(options.get("context_size", 0)) == 8192,
		"options_gpu": int(options.get("n_gpu_layers", 0)) == 24,
		"options_sampling": int(options.get("max_tokens", 0)) == 777,
	}
	var ok: bool = true
	for key: String in checks:
		if not bool(checks[key]):
			ok = false

	# Restore whatever the player had before the test.
	if had_existing:
		var w: FileAccess = FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
		if w != null:
			w.store_buffer(backup)
			w.close()
	elif FileAccess.file_exists(CONFIG_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CONFIG_PATH))

	return {"ok": ok, "checks": checks}
