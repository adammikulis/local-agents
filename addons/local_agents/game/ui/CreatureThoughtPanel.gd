class_name LACreatureThoughtPanel
extends CanvasLayer


const REFRESH_INTERVAL: float = 0.3   # seconds between live refreshes while a creature is selected

const COL_THOUGHT: Color = Color(0.98, 0.90, 0.55)       # warm amber — the star line
const COL_THOUGHT_LLM: Color = Color(0.60, 0.95, 0.70)   # green when the local model authored it
const COL_TEXT: Color = Color(0.80, 0.83, 0.88)
const COL_DIM: Color = Color(0.58, 0.61, 0.68)
const COL_TEACHER: Color = Color(0.62, 0.78, 0.98)       # blue — slow-brain resolved by the teacher, not the LLM

@onready var _panel: PanelContainer = $ThoughtPanel
@onready var _title: Label = $ThoughtPanel/VBox/Title
@onready var _badge: Label = $ThoughtPanel/VBox/Badge
@onready var _thought: Label = $ThoughtPanel/VBox/Thought
@onready var _hint: Label = $ThoughtPanel/VBox/Hint
@onready var _llm_toggle: CheckButton = $ThoughtPanel/VBox/LlmToggle
@onready var _lines: VBoxContainer = $ThoughtPanel/VBox/Lines
@onready var _history_scroll: ScrollContainer = $ThoughtPanel/VBox/HistoryScroll
@onready var _history_box: VBoxContainer = $ThoughtPanel/VBox/HistoryScroll/HistoryBox
@onready var _llm_species_btn: Button = $ThoughtPanel/VBox/GroupRow/SpeciesBtn
@onready var _llm_all_btn: Button = $ThoughtPanel/VBox/GroupRow/AllBtn

var _interaction: Node = null
var _selected: Node = null
var _refresh_accum: float = 0.0


func _ready() -> void:
	_llm_toggle.toggled.connect(_on_llm_toggled)
	_llm_species_btn.pressed.connect(_on_apply_species)
	_llm_all_btn.pressed.connect(_on_apply_all)


## Wire the selection source. `interaction` emits selection_changed(node) on every click/cycle/programmatic
## select — this is the ONLY hook; the panel adds no parallel input path.
func setup(interaction: Node) -> void:
	_interaction = interaction
	if interaction != null and interaction.has_signal("selection_changed"):
		interaction.selection_changed.connect(_on_selection_changed)


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


# Rebuild the panel from the selected creature's live brain. One creature, O(1)/O(small) reads.
func _refresh() -> void:
	var c: Node = _selected
	if c == null or not is_instance_valid(c):
		return

	_title.text = LACreatureThought.title(c)

	# Reflect this creature's live slow-brain flag without re-emitting (no feedback loop).
	if _llm_toggle != null and "llm_enabled" in c:
		_llm_toggle.set_pressed_no_signal(bool(c.llm_enabled))

	var t: Dictionary = LACreatureThought.thought(c)
	_thought.text = "“%s”" % String(t.get("text", ""))
	var is_llm: bool = bool(t.get("is_llm", false))
	_thought.add_theme_color_override("font_color", COL_THOUGHT_LLM if is_llm else COL_THOUGHT)

	if is_llm:
		_badge.text = "thinking via %s" % String(t.get("source", "local model"))
		_badge.add_theme_color_override("font_color", COL_THOUGHT_LLM)
		_hint.text = "This behaviour was chosen by the on-device model. No cloud, fully offline."
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

	_refresh_history(c)


# Rebuild the recent-decisions log from LACognition.history() (oldest first) and snap the scroll to the
# bottom so the newest entry is in view. O(HISTORY_CAP) on the same coarse timer, not per frame.
func _refresh_history(c: Node) -> void:
	if _history_box == null:
		return
	_clear(_history_box)
	var cog = c.get_cognition() if c.has_method("get_cognition") else null
	if cog == null or not cog.has_method("history"):
		return
	for entry in cog.history():
		var line: Dictionary = LACreatureThought.history_line(entry as Dictionary)
		var lbl: Label = Label.new()
		lbl.text = String(line.get("text", ""))
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.custom_minimum_size = Vector2(300.0, 0.0)
		lbl.add_theme_font_size_override("font_size", 12)
		var kind: String = String(line.get("kind", "fast"))
		var col: Color = COL_THOUGHT_LLM if kind == "llm" else (COL_TEACHER if kind == "teacher" else COL_DIM)
		lbl.add_theme_color_override("font_color", col)
		_history_box.add_child(lbl)
	await get_tree().process_frame
	if _history_scroll != null:
		_history_scroll.scroll_vertical = int(_history_scroll.get_v_scroll_bar().max_value)


# Per-creature toggle: gating happens in LACognition._should_escalate, so this takes effect on the next
# decision.
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
