extends VBoxContainer
class_name LAInferenceSettingsTab

# "Inference settings" tab of the model manager.
#
# Surfaces a generous set of the fields on the reused LocalAgentInferenceParams resource plus the
# model-load knobs (context length, threads, GPU layers) and a system prompt. Also lets the player
# pick which model drives each sim role (streamer / creature cognition / embedding), or leave a role
# on the single active model. Everything writes straight into the shared store and persists on Save.

var _store: LocalAgentModelSettingsStore = null
var _inventory: LocalAgentModelInventory = null

@onready var _n_ctx: SpinBox = %NCtxSpin
@onready var _temperature: SpinBox = %TemperatureSpin
@onready var _top_p: SpinBox = %TopPSpin
@onready var _top_k: SpinBox = %TopKSpin
@onready var _repeat_penalty: SpinBox = %RepeatPenaltySpin
@onready var _max_tokens: SpinBox = %MaxTokensSpin
@onready var _threads: SpinBox = %ThreadsSpin
@onready var _n_gpu_layers: SpinBox = %NGpuLayersSpin
@onready var _seed: SpinBox = %SeedSpin
@onready var _system_prompt: TextEdit = %SystemPromptEdit
@onready var _role_grid: GridContainer = %RoleGrid
@onready var _save_button: Button = %SaveButton
@onready var _status: Label = %StatusLabel

var _role_options: Dictionary = {}   # role -> OptionButton

func _ready() -> void:
	_save_button.pressed.connect(_on_save_pressed)
	_build_role_rows()

func setup(store: LocalAgentModelSettingsStore, inventory: LocalAgentModelInventory) -> void:
	_store = store
	_inventory = inventory

# One row per entry in LocalAgentModelSettingsStore.ROLES, so a new role is a new record there.
func _build_role_rows() -> void:
	for role: String in LocalAgentModelSettingsStore.ROLES:
		var label: Label = Label.new()
		label.text = String(LocalAgentModelSettingsStore.ROLE_LABELS.get(role, role))
		_role_grid.add_child(label)
		var option: OptionButton = OptionButton.new()
		option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_role_grid.add_child(option)
		_role_options[role] = option

func refresh() -> void:
	if _store == null:
		return
	_temperature.value = _store.inference.temperature
	_top_p.value = _store.inference.top_p
	_top_k.value = _store.inference.top_k
	_repeat_penalty.value = _store.inference.repeat_penalty
	_max_tokens.value = _store.inference.max_tokens
	_seed.value = _store.inference.seed
	_n_ctx.value = _store.n_ctx
	_threads.value = _store.threads
	_n_gpu_layers.value = _store.n_gpu_layers
	_system_prompt.text = _store.system_prompt
	_refresh_role_options()

func _refresh_role_options() -> void:
	var models: Array = _available_models()
	for role: String in _role_options.keys():
		var option: OptionButton = _role_options[role]
		option.clear()
		option.add_item("(use active model)")
		option.set_item_metadata(0, "")
		var selected_index: int = 0
		var current: String = String(_store.role_models.get(role, ""))
		for i: int in range(models.size()):
			var entry: Dictionary = models[i]
			var path: String = String(entry.get("path", ""))
			option.add_item(String(entry.get("label", path.get_file())))
			option.set_item_metadata(option.item_count - 1, path)
			if path == current and current != "":
				selected_index = option.item_count - 1
		option.select(selected_index)

# Builds the choice list for role assignment: registered models + everything detected on disk.
func _available_models() -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	if _store != null:
		for entry: Dictionary in _store.registered_models:
			var path: String = String(entry.get("path", ""))
			if path != "" and not seen.has(path):
				seen[path] = true
				out.append({"label": String(entry.get("label", path.get_file())), "path": path})
	if _inventory != null and _store != null:
		for row: Dictionary in _inventory.scan(_store.custom_folders, _store.hf_cache_override):
			var path2: String = String(row.get("path", ""))
			if path2 != "" and not seen.has(path2):
				seen[path2] = true
				out.append({"label": String(row.get("filename", path2.get_file())), "path": path2})
	return out

func _on_save_pressed() -> void:
	if _store == null:
		return
	_store.inference.temperature = _temperature.value
	_store.inference.top_p = _top_p.value
	_store.inference.top_k = int(_top_k.value)
	_store.inference.repeat_penalty = _repeat_penalty.value
	_store.inference.max_tokens = int(_max_tokens.value)
	_store.inference.seed = int(_seed.value)
	_store.n_ctx = int(_n_ctx.value)
	_store.threads = int(_threads.value)
	_store.n_gpu_layers = int(_n_gpu_layers.value)
	_store.system_prompt = _system_prompt.text
	for role: String in _role_options.keys():
		var option: OptionButton = _role_options[role]
		var path: String = String(option.get_item_metadata(option.get_selected_id()))
		if option.selected >= 0:
			path = String(option.get_item_metadata(option.selected))
		if path == "":
			_store.role_models.erase(role)
		else:
			_store.role_models[role] = path
	var ok: bool = _store.save()
	if _status != null:
		_status.text = "Saved." if ok else "Save failed."
