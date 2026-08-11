class_name LASettingsWidgets
extends RefCounted

## Shared control builders for the settings screen. Each builder instantiates its widget scene under
## widgets/ and fills in only what is per-setting: text, range, tooltip and signal. Returns the created
## nodes so the section objects can drive them.

const HeaderScene: PackedScene = preload("res://addons/local_agents/game/menu/widgets/SettingsHeader.tscn")
const RowScene: PackedScene = preload("res://addons/local_agents/game/menu/widgets/SettingsRow.tscn")
const PresetButtonScene: PackedScene = preload("res://addons/local_agents/game/menu/widgets/PresetButton.tscn")
const SliderRowScene: PackedScene = preload("res://addons/local_agents/game/menu/widgets/SliderRow.tscn")
const OptionRowScene: PackedScene = preload("res://addons/local_agents/game/menu/widgets/OptionRow.tscn")


## A section header — a faint rule then an accented caption.
static func add_header(col: VBoxContainer, text: String) -> void:
	var header: VBoxContainer = HeaderScene.instantiate()
	(header.get_node("Label") as Label).text = text
	col.add_child(header)


## An empty HBox row (used for preset button rows and the action bar).
static func add_row(col: VBoxContainer) -> HBoxContainer:
	var row: HBoxContainer = RowScene.instantiate()
	col.add_child(row)
	return row


## A toggle preset button inside a ButtonGroup row. `cb` fires on press.
static func add_preset_button(row: HBoxContainer, text: String, group: ButtonGroup, tooltip: String, cb: Callable) -> Button:
	var button: Button = PresetButtonScene.instantiate()
	button.text = text
	button.button_group = group
	button.tooltip_text = tooltip
	button.pressed.connect(cb)
	row.add_child(button)
	return button


## A labelled numeric slider row: [caption ....... value] then the slider. The live value Label is
## formatted by `fmt` (a Callable(float) -> String). `changed` fires with the new float on drag. Returns
## {"slider": HSlider, "value": Label} so the caller can refresh it later. `tooltip` shows on hover.
static func add_slider(col: VBoxContainer, caption_text: String, tooltip: String, min_v: float, max_v: float, step: float, initial: float, fmt: Callable, changed: Callable) -> Dictionary:
	var row: VBoxContainer = SliderRowScene.instantiate()
	(row.get_node("Header") as HBoxContainer).tooltip_text = tooltip

	var caption: Label = row.get_node("Header/Caption")
	caption.text = caption_text
	caption.tooltip_text = tooltip

	var value: Label = row.get_node("Header/Value")
	value.text = String(fmt.call(initial))

	var slider: HSlider = row.get_node("Slider")
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.value = initial
	slider.tooltip_text = tooltip
	slider.value_changed.connect(changed)

	col.add_child(row)
	return {"slider": slider, "value": value}


## A labelled dropdown row for a categorical setting. `options` are the item labels in enum order;
## `selected` is the initial index. `changed` fires with the picked index. Returns the OptionButton so the
## caller can refresh its selection.
static func add_option(col: VBoxContainer, caption_text: String, tooltip: String, options: Array, selected: int, changed: Callable) -> OptionButton:
	var row: VBoxContainer = OptionRowScene.instantiate()
	(row.get_node("Row") as HBoxContainer).tooltip_text = tooltip

	var caption: Label = row.get_node("Row/Caption")
	caption.text = caption_text
	caption.tooltip_text = tooltip

	var option: OptionButton = row.get_node("Row/Option")
	option.tooltip_text = tooltip
	for i in options.size():
		option.add_item(String(options[i]), i)
	option.selected = clampi(selected, 0, options.size() - 1)
	option.item_selected.connect(changed)

	col.add_child(row)
	return option
