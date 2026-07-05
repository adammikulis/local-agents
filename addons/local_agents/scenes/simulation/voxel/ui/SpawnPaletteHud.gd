class_name LASpawnPaletteHud
extends CanvasLayer

## In-code HUD for the voxel simulation: a bottom-center spawn palette, a right-side
## inspector panel, and a top status bar. The entire Control tree and Theme are built
## in _ready() -- no .tscn, no external fonts or image files.

signal spawn_selected(kind: String)

const KINDS: PackedStringArray = [
	"plant", "rabbit", "fox", "bird", "villager", "fish", "meteor", "volcano",
]

const KIND_LABELS: Dictionary = {
	"plant": "Plant",
	"rabbit": "Rabbit",
	"fox": "Fox",
	"bird": "Bird",
	"villager": "Villager",
	"fish": "Fish",
	"meteor": "Meteor",
	"volcano": "Volcano",
}

const KIND_COLORS: Dictionary = {
	"plant": Color(0.36, 0.72, 0.36),
	"rabbit": Color(0.85, 0.82, 0.78),
	"fox": Color(0.90, 0.49, 0.18),
	"bird": Color(0.35, 0.68, 0.90),
	"villager": Color(0.62, 0.52, 0.85),
	"fish": Color(0.55, 0.72, 0.86),
	"meteor": Color(0.92, 0.32, 0.24),
	"volcano": Color(0.95, 0.42, 0.12),
}

# Palette / theme colors (cohesive dark theme).
const COL_BG: Color = Color(0.086, 0.098, 0.129, 0.94)
const COL_BG_2: Color = Color(0.129, 0.145, 0.184, 0.96)
const COL_BORDER: Color = Color(0.24, 0.27, 0.33, 1.0)
const COL_ACCENT: Color = Color(0.33, 0.70, 0.98, 1.0)
const COL_ACCENT_DIM: Color = Color(0.33, 0.70, 0.98, 0.22)
const COL_TEXT: Color = Color(0.90, 0.92, 0.95, 1.0)
const COL_TEXT_DIM: Color = Color(0.62, 0.66, 0.72, 1.0)
const COL_TEXT_HEADING: Color = Color(0.98, 0.99, 1.0, 1.0)

var _armed_kind: String = ""

var _theme: Theme
var _palette_group: ButtonGroup

var _status_panel: PanelContainer
var _inspector_panel: PanelContainer
var _palette_panel: PanelContainer

var _status_label: Label
var _readout_label: Label
var _inspector_title: Label
var _inspector_lines: VBoxContainer

var _ui_panels: Array[Control] = []


func _ready() -> void:
	layer = 100
	_theme = _build_theme()

	# Root fills the screen but ignores mouse so empty areas fall through to the 3D scene.
	var root: Control = Control.new()
	root.name = "HudRoot"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _theme
	add_child(root)

	_build_status_bar(root)
	_build_inspector(root)
	_build_palette(root)

	clear_inspector()
	set_status("Ready")
	set_process(true)


func _process(_delta: float) -> void:
	var fps: int = int(round(Engine.get_frames_per_second()))
	var entity_count: int = 0
	var tree: SceneTree = get_tree()
	if tree != null:
		entity_count = tree.get_nodes_in_group("selectable").size()
	_readout_label.text = "%d FPS   |   %d entities" % [fps, entity_count]


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


func show_inspector(payload: Dictionary) -> void:
	if _inspector_title == null:
		return
	var title: String = String(payload.get("title", "Entity"))
	_inspector_title.text = title
	_inspector_title.add_theme_color_override("font_color", COL_TEXT_HEADING)

	_clear_children(_inspector_lines)
	var lines: Array = payload.get("lines", [])
	if lines.is_empty():
		var empty: Label = _make_line_label("(no details)", COL_TEXT_DIM)
		_inspector_lines.add_child(empty)
	else:
		for entry in lines:
			_inspector_lines.add_child(_make_line_label(str(entry), COL_TEXT))


func clear_inspector() -> void:
	if _inspector_title == null:
		return
	_inspector_title.text = "Inspector"
	_inspector_title.add_theme_color_override("font_color", COL_TEXT_DIM)
	_clear_children(_inspector_lines)
	var hint: Label = _make_line_label("Click an entity to inspect.", COL_TEXT_DIM)
	_inspector_lines.add_child(hint)


## True when the given (global) screen position sits over an interactive HUD panel,
## so world clicks can be suppressed by the caller.
func is_pointer_over_ui(pos: Vector2) -> bool:
	for panel in _ui_panels:
		if panel == null or not is_instance_valid(panel):
			continue
		if not panel.visible:
			continue
		if panel.get_global_rect().has_point(pos):
			return true
	return false


## The currently armed spawn kind ("" when in select/cursor mode).
func armed_kind() -> String:
	return _armed_kind


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build_status_bar(root: Control) -> void:
	_status_panel = PanelContainer.new()
	_status_panel.name = "StatusBar"
	_status_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_status_panel.offset_left = 12.0
	_status_panel.offset_right = -12.0
	_status_panel.offset_top = 12.0
	_status_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_status_panel)

	var margin: MarginContainer = _make_margin(14, 8)
	_status_panel.add_child(margin)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	margin.add_child(row)

	var badge: Label = Label.new()
	badge.text = "VOXEL SIM"
	badge.add_theme_color_override("font_color", COL_ACCENT)
	badge.add_theme_font_size_override("font_size", 14)
	row.add_child(badge)

	_status_label = Label.new()
	_status_label.text = "Ready"
	_status_label.add_theme_color_override("font_color", COL_TEXT)
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_status_label)

	_readout_label = Label.new()
	_readout_label.text = "0 FPS   |   0 entities"
	_readout_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_readout_label.add_theme_color_override("font_color", COL_TEXT_DIM)
	row.add_child(_readout_label)

	_ui_panels.append(_status_panel)


func _build_inspector(root: Control) -> void:
	_inspector_panel = PanelContainer.new()
	_inspector_panel.name = "Inspector"
	_inspector_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_inspector_panel.offset_right = -12.0
	_inspector_panel.offset_top = 60.0
	_inspector_panel.offset_left = -292.0
	_inspector_panel.custom_minimum_size = Vector2(280.0, 0.0)
	_inspector_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_inspector_panel)

	var margin: MarginContainer = _make_margin(16, 14)
	_inspector_panel.add_child(margin)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	margin.add_child(col)

	_inspector_title = Label.new()
	_inspector_title.text = "Inspector"
	_inspector_title.add_theme_color_override("font_color", COL_TEXT_HEADING)
	_inspector_title.add_theme_font_size_override("font_size", 17)
	col.add_child(_inspector_title)

	var rule: Control = _make_rule()
	col.add_child(rule)

	_inspector_lines = VBoxContainer.new()
	_inspector_lines.add_theme_constant_override("separation", 4)
	col.add_child(_inspector_lines)

	_ui_panels.append(_inspector_panel)


func _build_palette(root: Control) -> void:
	_palette_group = ButtonGroup.new()
	_palette_group.allow_unpress = true

	_palette_panel = PanelContainer.new()
	_palette_panel.name = "SpawnPalette"
	_palette_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_palette_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_palette_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_palette_panel.offset_bottom = -18.0
	_palette_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_palette_panel)

	var margin: MarginContainer = _make_margin(12, 10)
	_palette_panel.add_child(margin)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	margin.add_child(row)

	# Cursor / select button (disarms the palette).
	var select_btn: Button = Button.new()
	select_btn.text = "Select"
	select_btn.tooltip_text = "Cursor mode: click entities to inspect"
	select_btn.icon = _make_cursor_icon()
	select_btn.custom_minimum_size = Vector2(0.0, 56.0)
	select_btn.focus_mode = Control.FOCUS_NONE
	select_btn.pressed.connect(_on_select_pressed)
	row.add_child(select_btn)

	var sep: VSeparator = VSeparator.new()
	row.add_child(sep)

	for kind in KINDS:
		var btn: Button = Button.new()
		btn.text = String(KIND_LABELS.get(kind, kind))
		btn.tooltip_text = "Arm %s for placement" % String(KIND_LABELS.get(kind, kind))
		btn.icon = _make_kind_icon(KIND_COLORS.get(kind, Color.WHITE))
		btn.toggle_mode = true
		btn.button_group = _palette_group
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(0.0, 56.0)
		btn.set_meta("kind", kind)
		btn.toggled.connect(_on_palette_toggled)
		row.add_child(btn)

	_ui_panels.append(_palette_panel)


# ---------------------------------------------------------------------------
# Interaction
# ---------------------------------------------------------------------------

func _on_palette_toggled(_pressed_state: bool) -> void:
	var pressed_btn: BaseButton = _palette_group.get_pressed_button()
	var current: String = ""
	if pressed_btn != null:
		current = String(pressed_btn.get_meta("kind", ""))
	if current == _armed_kind:
		return
	_armed_kind = current
	if _armed_kind == "":
		set_status("Select mode: click an entity to inspect.")
	else:
		set_status("Armed: %s -- click terrain to place." % String(KIND_LABELS.get(_armed_kind, _armed_kind)))
	spawn_selected.emit(_armed_kind)


func _on_select_pressed() -> void:
	var pressed_btn: BaseButton = _palette_group.get_pressed_button()
	if pressed_btn != null:
		# Fires _on_palette_toggled(false), which emits "" and clears _armed_kind.
		pressed_btn.button_pressed = false
	elif _armed_kind != "":
		_armed_kind = ""
		spawn_selected.emit("")


# ---------------------------------------------------------------------------
# Theme + widget helpers
# ---------------------------------------------------------------------------

func _build_theme() -> Theme:
	var t: Theme = Theme.new()
	t.default_font_size = 15

	var panel_sb: StyleBoxFlat = _panel_stylebox(COL_BG)
	t.set_stylebox("panel", "PanelContainer", panel_sb)

	# Buttons.
	var btn_normal: StyleBoxFlat = _button_stylebox(COL_BG_2, COL_BORDER)
	var btn_hover: StyleBoxFlat = _button_stylebox(Color(0.18, 0.20, 0.25, 0.98), COL_ACCENT.lerp(COL_BORDER, 0.4))
	var btn_pressed: StyleBoxFlat = _button_stylebox(COL_ACCENT_DIM, COL_ACCENT)
	btn_pressed.border_width_left = 2
	btn_pressed.border_width_right = 2
	btn_pressed.border_width_top = 2
	btn_pressed.border_width_bottom = 2
	var btn_focus: StyleBoxFlat = _button_stylebox(Color(0, 0, 0, 0), COL_ACCENT)

	t.set_stylebox("normal", "Button", btn_normal)
	t.set_stylebox("hover", "Button", btn_hover)
	t.set_stylebox("pressed", "Button", btn_pressed)
	t.set_stylebox("hover_pressed", "Button", btn_pressed)
	t.set_stylebox("focus", "Button", btn_focus)
	t.set_stylebox("disabled", "Button", btn_normal)
	t.set_color("font_color", "Button", COL_TEXT)
	t.set_color("font_hover_color", "Button", COL_TEXT_HEADING)
	t.set_color("font_pressed_color", "Button", COL_ACCENT)
	t.set_color("font_hover_pressed_color", "Button", COL_ACCENT)
	t.set_constant("h_separation", "Button", 8)
	t.set_font_size("font_size", "Button", 14)

	t.set_color("font_color", "Label", COL_TEXT)

	var sep_sb: StyleBoxLine = StyleBoxLine.new()
	sep_sb.color = COL_BORDER
	sep_sb.vertical = true
	t.set_stylebox("separator", "VSeparator", sep_sb)

	return t


func _panel_stylebox(bg: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(1)
	sb.border_color = COL_BORDER
	sb.set_content_margin_all(0)
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 8
	return sb


func _button_stylebox(bg: Color, border: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(1)
	sb.border_color = border
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb


func _make_margin(h: int, v: int) -> MarginContainer:
	var m: MarginContainer = MarginContainer.new()
	m.add_theme_constant_override("margin_left", h)
	m.add_theme_constant_override("margin_right", h)
	m.add_theme_constant_override("margin_top", v)
	m.add_theme_constant_override("margin_bottom", v)
	return m


func _make_rule() -> Control:
	var r: ColorRect = ColorRect.new()
	r.color = COL_BORDER
	r.custom_minimum_size = Vector2(0.0, 1.0)
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return r


func _make_line_label(text: String, color: Color) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", 14)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


func _clear_children(node: Node) -> void:
	if node == null:
		return
	for child in node.get_children():
		child.queue_free()
		node.remove_child(child)


# ---------------------------------------------------------------------------
# Icon generation (drawn to an Image -> ImageTexture, no external files)
# ---------------------------------------------------------------------------

func _make_kind_icon(base: Color) -> ImageTexture:
	var s: int = 30
	var img: Image = Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c: Vector2 = Vector2(s / 2.0, s / 2.0)
	var r: float = s / 2.0 - 3.0
	for y in s:
		for x in s:
			var d: float = Vector2(x + 0.5, y + 0.5).distance_to(c)
			if d <= r:
				# Radial shading for a little dimensionality.
				var shade: float = clampf(1.0 - (d / r) * 0.4, 0.0, 1.0)
				img.set_pixel(x, y, Color(base.r * shade, base.g * shade, base.b * shade, 1.0))
			elif d <= r + 1.4:
				img.set_pixel(x, y, Color(0.05, 0.06, 0.08, 0.65))
	return ImageTexture.create_from_image(img)


func _make_cursor_icon() -> ImageTexture:
	var s: int = 30
	var img: Image = Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	# A simple crosshair.
	var mid: int = s / 2
	for i in s:
		img.set_pixel(mid, i, COL_TEXT)
		img.set_pixel(i, mid, COL_TEXT)
	for i in range(mid - 3, mid + 4):
		if i >= 0 and i < s:
			img.set_pixel(i, mid, COL_ACCENT)
			img.set_pixel(mid, i, COL_ACCENT)
	return ImageTexture.create_from_image(img)
