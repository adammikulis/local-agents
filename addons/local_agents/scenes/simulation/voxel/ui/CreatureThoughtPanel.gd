class_name LACreatureThoughtPanel
extends CanvasLayer

## The headline hook: click a creature and this panel shows what it is actually thinking — its name,
## its current behaviour, how it decided, what it has learned, and (the star) its latest natural-language
## thought from the LOCAL model, offline. It SURFACES the existing per-creature cognition via
## LACreatureThought; it starts no LLM of its own. Self-contained CanvasLayer built in code (same
## convention as StreamerOverlay / SpawnPaletteHud / DebugPanel).
##
## Cheap by construction: it rebuilds only on selection change and on a coarse timer while one creature
## is selected — never per frame, never per creature, no group scans. (Explicit types only — no ':='.)

const REFRESH_INTERVAL: float = 0.3   # seconds between live refreshes while a creature is selected

const COL_HEADING: Color = Color(0.86, 0.92, 1.0)
const COL_THOUGHT: Color = Color(0.98, 0.90, 0.55)   # warm amber — the star line
const COL_THOUGHT_LLM: Color = Color(0.60, 0.95, 0.70)   # green when the local model authored it
const COL_TEXT: Color = Color(0.80, 0.83, 0.88)
const COL_DIM: Color = Color(0.58, 0.61, 0.68)

var _panel: PanelContainer = null
var _title: Label = null
var _thought: Label = null
var _badge: Label = null
var _hint: Label = null
var _lines: VBoxContainer = null
var _llm_toggle: CheckButton = null   # per-creature local-LLM "slow brain" on/off for the selection
var _llm_species_btn: Button = null   # apply the toggle's value to this creature's whole species
var _llm_all_btn: Button = null       # apply the toggle's value to every creature

var _interaction: Node = null
var _selected: Node = null
var _refresh_accum: float = 0.0


func _ready() -> void:
	layer = 88
	_build_ui()
	_hide()


## Wire the selection source. `interaction` emits selection_changed(node) on every click/cycle/programmatic
## select — this is the ONLY hook; the panel adds no parallel input path.
func setup(interaction: Node) -> void:
	_interaction = interaction
	if interaction != null and interaction.has_signal("selection_changed"):
		interaction.selection_changed.connect(_on_selection_changed)


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.name = "ThoughtPanel"
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_panel.offset_left = 14.0
	_panel.offset_bottom = -14.0
	_panel.custom_minimum_size = Vector2(320.0, 0.0)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.10, 0.90)
	style.border_color = Color(0.30, 0.55, 0.85, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(10.0)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	_panel.add_child(vbox)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 17)
	_title.add_theme_color_override("font_color", COL_HEADING)
	vbox.add_child(_title)

	_badge = Label.new()
	_badge.add_theme_font_size_override("font_size", 11)
	_badge.add_theme_color_override("font_color", COL_DIM)
	vbox.add_child(_badge)

	_thought = Label.new()
	_thought.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_thought.custom_minimum_size = Vector2(300.0, 0.0)
	_thought.add_theme_font_size_override("font_size", 15)
	_thought.add_theme_color_override("font_color", COL_THOUGHT)
	vbox.add_child(_thought)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size = Vector2(300.0, 0.0)
	_hint.add_theme_font_size_override("font_size", 11)
	_hint.add_theme_color_override("font_color", COL_DIM)
	vbox.add_child(_hint)

	var sep: HSeparator = HSeparator.new()
	vbox.add_child(sep)

	# Per-creature local-LLM control: turn the slow brain on/off for this creature, and apply that choice to
	# its whole species or every creature. Off => it never consults the on-device model (fast policy only).
	_llm_toggle = CheckButton.new()
	_llm_toggle.text = "Local model reasoning"
	_llm_toggle.add_theme_font_size_override("font_size", 12)
	_llm_toggle.toggled.connect(_on_llm_toggled)
	vbox.add_child(_llm_toggle)

	var group_row: HBoxContainer = HBoxContainer.new()
	group_row.add_theme_constant_override("separation", 4)
	_llm_species_btn = Button.new()
	_llm_species_btn.text = "Apply to species"
	_llm_species_btn.add_theme_font_size_override("font_size", 11)
	_llm_species_btn.pressed.connect(_on_apply_species)
	group_row.add_child(_llm_species_btn)
	_llm_all_btn = Button.new()
	_llm_all_btn.text = "Apply to all"
	_llm_all_btn.add_theme_font_size_override("font_size", 11)
	_llm_all_btn.pressed.connect(_on_apply_all)
	group_row.add_child(_llm_all_btn)
	vbox.add_child(group_row)

	var sep2: HSeparator = HSeparator.new()
	vbox.add_child(sep2)

	_lines = VBoxContainer.new()
	_lines.add_theme_constant_override("separation", 3)
	vbox.add_child(_lines)


func _on_selection_changed(node: Node) -> void:
	if node != null and node.is_in_group("creature") and node.has_method("get_cognition"):
		_selected = node
		_refresh_accum = REFRESH_INTERVAL   # force an immediate rebuild next frame
		_show()
		_refresh()
	else:
		_selected = null
		_hide()


func _process(delta: float) -> void:
	if _selected == null:
		return
	if not is_instance_valid(_selected):
		_selected = null
		_hide()
		return
	_refresh_accum += delta
	if _refresh_accum >= REFRESH_INTERVAL:
		_refresh_accum = 0.0
		_refresh()


# Rebuild the panel from the selected creature's LIVE brain. One creature, O(1)/O(small) reads.
func _refresh() -> void:
	var c: Node = _selected
	if c == null or not is_instance_valid(c):
		return

	_title.text = LACreatureThought.title(c)

	# Reflect this creature's live slow-brain flag on the toggle without re-emitting (no feedback loop).
	if _llm_toggle != null and "llm_enabled" in c:
		_llm_toggle.set_pressed_no_signal(bool(c.llm_enabled))

	var t: Dictionary = LACreatureThought.thought(c)
	_thought.text = "“%s”" % String(t.get("text", ""))
	var is_llm: bool = bool(t.get("is_llm", false))
	_thought.add_theme_color_override("font_color", COL_THOUGHT_LLM if is_llm else COL_THOUGHT)

	if is_llm:
		_badge.text = "thinking via %s" % String(t.get("source", "local model"))
		_badge.add_theme_color_override("font_color", COL_THOUGHT_LLM)
		_hint.text = "This behaviour was chosen by the on-device model — no cloud, fully offline."
	else:
		_badge.text = "reasoning: %s" % String(t.get("source", "rule-based"))
		_badge.add_theme_color_override("font_color", COL_DIM)
		_hint.text = "(load a local model for natural-language reasoning)"

	_clear(_lines)
	for entry in LACreatureThought.detail_lines(c):
		var lbl: Label = Label.new()
		lbl.text = String(entry)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.custom_minimum_size = Vector2(300.0, 0.0)
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", COL_TEXT)
		_lines.add_child(lbl)


# Per-creature toggle: turn this creature's slow brain on/off. Config-driven flag on the creature; gating
# happens in LACognition._should_escalate, so this takes effect on its next decision.
func _on_llm_toggled(on: bool) -> void:
	if _selected != null and is_instance_valid(_selected) and "llm_enabled" in _selected:
		_selected.llm_enabled = on


# Apply the current toggle value to the selected creature's whole species.
func _on_apply_species() -> void:
	if _selected == null or not is_instance_valid(_selected) or _llm_toggle == null:
		return
	var sp: String = String(_selected.get("species"))
	var n: int = LALLMControl.set_group(get_tree(), sp, _llm_toggle.button_pressed)
	print("LLM_GROUP_SET={scope:species, species:%s, on:%s, count:%d}" % [sp, str(_llm_toggle.button_pressed), n])


# Apply the current toggle value to every creature in the world.
func _on_apply_all() -> void:
	if _llm_toggle == null:
		return
	var n: int = LALLMControl.set_group(get_tree(), "", _llm_toggle.button_pressed)
	print("LLM_GROUP_SET={scope:all, on:%s, count:%d}" % [str(_llm_toggle.button_pressed), n])


func _show() -> void:
	if _panel != null:
		_panel.visible = true


func _hide() -> void:
	if _panel != null:
		_panel.visible = false


func _clear(box: Node) -> void:
	for child in box.get_children():
		child.queue_free()
