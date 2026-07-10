@tool
extends RefCounted
class_name LocalAgentsModelSettingsStore

# Persistent model + inference settings for the in-game model manager.
#
# Reuses the existing LocalAgentsInferenceParams resource for the sampling fields (temperature,
# top_p, top_k, repeat_penalty, max_tokens, seed, …) so the runtime and the editor config UI speak
# the same shape, and adds the model-load knobs a player expects (context length, threads, GPU
# layers, system prompt). Everything round-trips through a single ConfigFile under user:// — no
# AgentManager autoload required, so this works standalone inside the voxel sim.
#
# to_llama_options() emits the exact Dictionary LocalAgentsLlamaServerManager.ensure_running() reads
# (context_size / threads / n_gpu_layers alongside the sampling params from InferenceParams).

const InferenceParams: GDScript = preload("res://addons/local_agents/configuration/parameters/InferenceParams.gd")

const CONFIG_PATH: String = "user://local_agents/model_settings.cfg"

# Roles the sim can assign a distinct model to. A player may leave a role blank to fall back to the
# single active model. Kept as data so adding a role is a one-line edit, not a new branch.
const ROLES: Array[String] = ["streamer", "creature_cognition", "embedding"]
const ROLE_LABELS: Dictionary = {
	"streamer": "Streamer / commentator",
	"creature_cognition": "Creature cognition",
	"embedding": "Embedding",
}

# Sampling params (reused resource).
var inference: LocalAgentsInferenceParams = null

# Model-load knobs (map to LlamaServerManager options).
var n_ctx: int = 4096
var threads: int = 0            # 0 -> let the runtime pick
var n_gpu_layers: int = 0       # 0 -> CPU only; positive -> offload N layers
var system_prompt: String = ""

# Where to look for already-downloaded models (persisted so detection survives a restart).
var hf_cache_override: String = ""
var custom_folders: PackedStringArray = PackedStringArray()

# Bring-your-own models the player registered by browsing to a .gguf. Each entry {label, path}.
var registered_models: Array = []

# Active-model selection + optional per-role overrides (role -> absolute path).
var active_model_path: String = ""
var role_models: Dictionary = {}

func _init() -> void:
	inference = InferenceParams.new()
	inference.inference_config_name = "In-game"
	inference.temperature = 0.8
	inference.max_tokens = 512
	inference.top_p = 0.95
	inference.top_k = 40
	inference.repeat_penalty = 1.1
	inference.seed = -1

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

# Merges the sampling params with the model-load knobs into the Dictionary the llama server manager
# consumes. system_prompt travels under its own key for whichever cognition path wants it.
func to_llama_options() -> Dictionary:
	var opts: Dictionary = inference.to_options() if inference != null else {}
	if n_ctx > 0:
		opts["context_size"] = n_ctx
	if threads > 0:
		opts["threads"] = threads
	if n_gpu_layers > 0:
		opts["n_gpu_layers"] = n_gpu_layers
	if system_prompt.strip_edges() != "":
		opts["system_prompt"] = system_prompt
	return opts

# Resolves the model path a given role should use: its override if set, else the active model.
func model_for_role(role: String) -> String:
	var override: String = String(role_models.get(role, "")).strip_edges()
	if override != "":
		return override
	return active_model_path

# -- Persistence --------------------------------------------------------------

func save() -> bool:
	var cfg: ConfigFile = ConfigFile.new()
	cfg.set_value("inference", "temperature", inference.temperature)
	cfg.set_value("inference", "max_tokens", inference.max_tokens)
	cfg.set_value("inference", "top_p", inference.top_p)
	cfg.set_value("inference", "top_k", inference.top_k)
	cfg.set_value("inference", "repeat_penalty", inference.repeat_penalty)
	cfg.set_value("inference", "seed", inference.seed)

	cfg.set_value("model", "n_ctx", n_ctx)
	cfg.set_value("model", "threads", threads)
	cfg.set_value("model", "n_gpu_layers", n_gpu_layers)
	cfg.set_value("model", "system_prompt", system_prompt)

	cfg.set_value("paths", "hf_cache_override", hf_cache_override)
	cfg.set_value("paths", "custom_folders", custom_folders)

	cfg.set_value("custom_models", "registered", registered_models)

	cfg.set_value("active", "model_path", active_model_path)
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
	inference.temperature = float(cfg.get_value("inference", "temperature", inference.temperature))
	inference.max_tokens = int(cfg.get_value("inference", "max_tokens", inference.max_tokens))
	inference.top_p = float(cfg.get_value("inference", "top_p", inference.top_p))
	inference.top_k = int(cfg.get_value("inference", "top_k", inference.top_k))
	inference.repeat_penalty = float(cfg.get_value("inference", "repeat_penalty", inference.repeat_penalty))
	inference.seed = int(cfg.get_value("inference", "seed", inference.seed))

	n_ctx = int(cfg.get_value("model", "n_ctx", n_ctx))
	threads = int(cfg.get_value("model", "threads", threads))
	n_gpu_layers = int(cfg.get_value("model", "n_gpu_layers", n_gpu_layers))
	system_prompt = String(cfg.get_value("model", "system_prompt", system_prompt))

	hf_cache_override = String(cfg.get_value("paths", "hf_cache_override", hf_cache_override))
	custom_folders = cfg.get_value("paths", "custom_folders", custom_folders)

	registered_models = cfg.get_value("custom_models", "registered", registered_models)

	active_model_path = String(cfg.get_value("active", "model_path", active_model_path))
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

	var store: LocalAgentsModelSettingsStore = LocalAgentsModelSettingsStore.new()
	store.inference.temperature = 0.42
	store.inference.top_k = 33
	store.inference.max_tokens = 777
	store.inference.seed = 12345
	store.n_ctx = 8192
	store.threads = 6
	store.n_gpu_layers = 24
	store.system_prompt = "You are a helpful island spirit."
	store.hf_cache_override = "/tmp/fake_hf"
	store.custom_folders = PackedStringArray(["/models/a", "/models/b"])
	store.register_model("/models/a/custom.gguf", "My custom model")
	store.active_model_path = "/models/a/custom.gguf"
	store.role_models = {"streamer": "/models/b/streamer.gguf"}
	var saved: bool = store.save()

	var loaded_store: LocalAgentsModelSettingsStore = LocalAgentsModelSettingsStore.new()
	var loaded: bool = loaded_store.load()

	var checks: Dictionary = {
		"saved": saved,
		"loaded": loaded,
		"temperature": is_equal_approx(loaded_store.inference.temperature, 0.42),
		"top_k": loaded_store.inference.top_k == 33,
		"max_tokens": loaded_store.inference.max_tokens == 777,
		"seed": loaded_store.inference.seed == 12345,
		"n_ctx": loaded_store.n_ctx == 8192,
		"threads": loaded_store.threads == 6,
		"n_gpu_layers": loaded_store.n_gpu_layers == 24,
		"system_prompt": loaded_store.system_prompt == "You are a helpful island spirit.",
		"hf_cache_override": loaded_store.hf_cache_override == "/tmp/fake_hf",
		"custom_folders": loaded_store.custom_folders.size() == 2 and String(loaded_store.custom_folders[1]) == "/models/b",
		"registered_model": loaded_store.registered_models.size() == 1 and String((loaded_store.registered_models[0] as Dictionary).get("path", "")) == "/models/a/custom.gguf",
		"active_model": loaded_store.active_model_path == "/models/a/custom.gguf",
		"role_override": loaded_store.model_for_role("streamer") == "/models/b/streamer.gguf",
		"role_fallback": loaded_store.model_for_role("embedding") == "/models/a/custom.gguf",
		"options_context": int(loaded_store.to_llama_options().get("context_size", 0)) == 8192,
		"options_gpu": int(loaded_store.to_llama_options().get("n_gpu_layers", 0)) == 24,
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
