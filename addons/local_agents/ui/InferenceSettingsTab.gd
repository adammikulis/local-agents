extends VBoxContainer
class_name LocalAgentsInferenceSettingsTab

# "Inference settings" tab of the model manager.
#
# Surfaces a generous set of the fields on the reused LocalAgentsInferenceParams resource plus the
# model-load knobs (context length, threads, GPU layers) and a system prompt. Also lets the player
# pick which model drives each sim role (streamer / creature cognition / embedding), or leave a role
# on the single active model. Everything writes straight into the shared store and persists on Save.

var _store: LocalAgentsModelSettingsStore = null
var _inventory: LocalAgentsModelInventory = null

var _n_ctx: SpinBox = null
var _temperature: SpinBox = null
var _top_p: SpinBox = null
var _top_k: SpinBox = null
var _repeat_penalty: SpinBox = null
var _max_tokens: SpinBox = null
var _threads: SpinBox = null
var _n_gpu_layers: SpinBox = null
var _seed: SpinBox = null
var _system_prompt: TextEdit = null
var _role_options: Dictionary = {}   # role -> OptionButton
var _status: Label = null

func setup(store: LocalAgentsModelSettingsStore, inventory: LocalAgentsModelInventory) -> void:
	_store = store
	_inventory = inventory
	_build()

func _build() -> void:
	add_theme_constant_override("separation", 8)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	var body: VBoxContainer = VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	scroll.add_child(body)

	_add_heading(body, "Sampling")
	var grid: GridContainer = GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 6)
	body.add_child(grid)

	_temperature = _add_spin(grid, "Temperature", 0.0, 2.0, 0.01, false)
	_top_p = _add_spin(grid, "Top-p", 0.0, 1.0, 0.01, false)
	_top_k = _add_spin(grid, "Top-k", 0.0, 500.0, 1.0, true)
	_repeat_penalty = _add_spin(grid, "Repeat penalty", 0.0, 2.0, 0.01, false)
	_max_tokens = _add_spin(grid, "Max tokens", 1.0, 32768.0, 1.0, true)
	_seed = _add_spin(grid, "Seed (-1 = random)", -1.0, 2147483647.0, 1.0, true)

	_add_heading(body, "Model load")
	var grid2: GridContainer = GridContainer.new()
	grid2.columns = 2
	grid2.add_theme_constant_override("h_separation", 16)
	grid2.add_theme_constant_override("v_separation", 6)
	body.add_child(grid2)
	_n_ctx = _add_spin(grid2, "Context length (n_ctx)", 256.0, 131072.0, 256.0, true)
	_threads = _add_spin(grid2, "Threads (0 = auto)", 0.0, 256.0, 1.0, true)
	_n_gpu_layers = _add_spin(grid2, "GPU layers (n_gpu_layers)", 0.0, 200.0, 1.0, true)

	_add_heading(body, "System prompt")
	_system_prompt = TextEdit.new()
	_system_prompt.custom_minimum_size = Vector2(0, 90)
	_system_prompt.placeholder_text = "Optional system prompt applied to cognition/streamer prompts."
	_system_prompt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(_system_prompt)

	_add_heading(body, "Model per role")
	var role_grid: GridContainer = GridContainer.new()
	role_grid.columns = 2
	role_grid.add_theme_constant_override("h_separation", 16)
	role_grid.add_theme_constant_override("v_separation", 6)
	body.add_child(role_grid)
	for role: String in LocalAgentsModelSettingsStore.ROLES:
		var label: Label = Label.new()
		label.text = String(LocalAgentsModelSettingsStore.ROLE_LABELS.get(role, role))
		role_grid.add_child(label)
		var option: OptionButton = OptionButton.new()
		option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		role_grid.add_child(option)
		_role_options[role] = option

	var save_button: Button = Button.new()
	save_button.text = "Save settings"
	save_button.pressed.connect(_on_save_pressed)
	body.add_child(save_button)

	_status = Label.new()
	body.add_child(_status)

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

func _add_heading(parent: Control, text: String) -> void:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 16)
	parent.add_child(label)

func _add_spin(grid: GridContainer, label_text: String, min_v: float, max_v: float, step: float, whole: bool) -> SpinBox:
	var label: Label = Label.new()
	label.text = label_text
	grid.add_child(label)
	var spin: SpinBox = SpinBox.new()
	spin.min_value = min_v
	spin.max_value = max_v
	spin.step = step
	spin.rounded = whole
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(spin)
	return spin

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
