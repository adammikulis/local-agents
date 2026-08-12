@tool
extends EditorInspectorPlugin
class_name LAChoiceInspectorPlugin


const SPECIES_ROOT: String = "res://addons/local_agents/creatures/species"
const VOICES_ROOT: String = "res://addons/local_agents/voices"

## Property name -> the method on this class that returns its choices.
const PROVIDERS: Dictionary = {
	"standalone_species": "_species_ids",
	"species": "_species_ids",
	"voice": "_voice_ids",
	"model_path": "_installed_models",
}


func _can_handle(object: Object) -> bool:
	return object != null


func _parse_property(_object: Object, type: Variant.Type, name: String, _hint: PropertyHint,
		_hint_string: String, _usage_flags: int, _wide: bool) -> bool:
	if type != TYPE_STRING or not PROVIDERS.has(name):
		return false
	var choices: PackedStringArray = call(String(PROVIDERS[name]))
	if choices.is_empty():
		return false                      # nothing discovered: leave the plain text field alone
	add_property_editor(name, LocalAgentChoiceProperty.new(choices), false)
	return true


## Species ids are the basenames of creatures/species/<class>/<id>.json.
func _species_ids() -> PackedStringArray:
	return _collect_basenames(SPECIES_ROOT, ["json"], true)


## Piper voices are .onnx models sitting under the voices root (which ships empty).
func _voice_ids() -> PackedStringArray:
	return _collect_basenames(VOICES_ROOT, ["onnx"], true)


## Installed .gguf models, from the same resolution order LocalAgentStatus uses at runtime, so the
## dropdown cannot offer a path the runtime would not accept.
func _installed_models() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for candidate in LocalAgentStatus.candidate_paths():
		var path: String = String(candidate)
		if path == "" or out.has(path):
			continue
		if FileAccess.file_exists(LocalAgentRuntimePaths.normalize_path(path)):
			out.append(path)
	return out


func _collect_basenames(root: String, extensions: Array, recurse: bool) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	_scan_into(root, extensions, recurse, out)
	out.sort()
	return out


func _scan_into(dir_path: String, extensions: Array, recurse: bool, out: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full: String = "%s/%s" % [dir_path, entry]
		if dir.current_is_dir():
			if recurse:
				_scan_into(full, extensions, recurse, out)
		elif extensions.has(entry.get_extension().to_lower()):
			var id: String = entry.get_basename()
			if not out.has(id):
				out.append(id)
		entry = dir.get_next()
	dir.list_dir_end()


class LocalAgentChoiceProperty extends EditorProperty:
	var _choices: PackedStringArray
	var _picker: OptionButton
	var _field: LineEdit
	var _updating: bool = false

	func _init(choices: PackedStringArray) -> void:
		_choices = choices
		var row: HBoxContainer = HBoxContainer.new()
		_picker = OptionButton.new()
		_picker.add_item("(choose…)", 0)
		for i in _choices.size():
			_picker.add_item(_choices[i], i + 1)
		_picker.item_selected.connect(_on_picked)
		row.add_child(_picker)
		_field = LineEdit.new()
		_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_field.placeholder_text = "(default)"
		_field.text_submitted.connect(_on_typed)
		_field.focus_exited.connect(func() -> void: _on_typed(_field.text))
		row.add_child(_field)
		add_child(row)
		add_focusable(_field)

	func _on_picked(index: int) -> void:
		if index <= 0:
			return
		_field.text = _choices[index - 1]
		_commit(_field.text)

	func _on_typed(text: String) -> void:
		_commit(text)

	func _commit(value: String) -> void:
		if _updating:
			return
		emit_changed(get_edited_property(), value)

	func _update_property() -> void:
		var value: String = String(get_edited_object().get(get_edited_property()))
		_updating = true
		if _field.text != value:
			_field.text = value
		var found: int = _choices.find(value)
		_picker.select(found + 1 if found >= 0 else 0)
		_updating = false
