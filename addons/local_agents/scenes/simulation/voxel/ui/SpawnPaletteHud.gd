class_name LASpawnPaletteHud
extends CanvasLayer

## In-code HUD for the voxel simulation: a bottom-center spawn palette, a right-side
## inspector panel, and a top status bar. The Control tree and Theme are built in _ready().
## The palette buttons are icon-only emoji glyphs rendered with a small bundled emoji font
## (addons/local_agents/assets/fonts/emoji.ttf, a subset of Noto Color Emoji); everything
## else uses the engine default font and procedurally-drawn styleboxes/icons.

signal spawn_selected(kind: String)
## Re-exposed from the audio menu; VoxelWorld listens to gate its live mood feed.
signal music_auto_adapt_changed(on: bool)

const AudioMenuPanelScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/AudioMenuPanel.gd")
const EMOJI_FONT_PATH: String = "res://addons/local_agents/assets/fonts/emoji.ttf"

# Spawn-button thumbnails: each life/prop button shows a small isometric render of the actual
# model it spawns (built once at startup into an off-screen SubViewport). Disaster buttons have
# no representative model, so they keep their emoji glyph.
const THUMB_PX: int = 64

# The palette is split into two visible clusters. Order within each drives the number hotkeys
# (LIFE -> 1..7, DISASTER -> Shift+1..5); KINDS is kept as the flat union for lookups/back-compat.
const LIFE_KINDS: PackedStringArray = [
	"plant", "tree", "rabbit", "fox", "bird", "vulture", "villager", "fish",
]
const DISASTER_KINDS: PackedStringArray = [
	"meteor", "volcano", "lightning", "earthquake", "flood", "tornado", "thunderstorm", "hurricane",
]
const KINDS: PackedStringArray = [
	"plant", "tree", "rabbit", "fox", "bird", "vulture", "villager", "fish",
	"meteor", "volcano", "lightning", "earthquake", "flood", "tornado", "thunderstorm", "hurricane",
]

const KIND_LABELS: Dictionary = {
	"plant": "Plant",
	"tree": "Tree",
	"rabbit": "Rabbit",
	"fox": "Fox",
	"bird": "Bird",
	"vulture": "Vulture",
	"villager": "Villager",
	"fish": "Fish",
	"meteor": "Meteor",
	"volcano": "Volcano",
	"lightning": "Lightning",
	"earthquake": "Quake",
	"flood": "Flood",
	"tornado": "Tornado",
	"thunderstorm": "Storm",
	"hurricane": "Hurricane",
}

# Emoji glyph per kind (self-colored by the emoji font). Literal UTF-8 glyphs -- trivially
# tunable: swap a glyph here and add its codepoint to the pyftsubset build in assets/fonts/.
const KIND_SYMBOLS: Dictionary = {
	"plant": "🌱",      # seedling
	"tree": "🌲",       # evergreen (forest brush)
	"rabbit": "🐇",     # rabbit
	"fox": "🦊",        # fox
	"bird": "🐦",       # bird
	"vulture": "🦅",    # eagle (stands in for vulture)
	"villager": "🧑",   # person
	"fish": "🐟",       # fish
	"meteor": "☄",      # comet
	"volcano": "🌋",    # volcano
	"lightning": "⚡",   # high voltage
	"earthquake": "🏚", # derelict house (shaken ground)
	"flood": "🌊",      # water wave
	"tornado": "🌪",    # tornado
	"thunderstorm": "⛈", # cloud with lightning + rain
	"hurricane": "🌀",  # cyclone
}

# Shown in tooltips so the keyboard shortcut is discoverable (see VoxelWorld._unhandled_input).
# "⇧" is the shift glyph (U+21E7).
const KIND_HOTKEYS: Dictionary = {
	"plant": "1", "tree": "2", "rabbit": "3", "fox": "4",
	"bird": "5", "vulture": "6", "villager": "7", "fish": "8",
	"meteor": "⇧1", "volcano": "⇧2", "lightning": "⇧3",
	"earthquake": "⇧4", "flood": "⇧5", "tornado": "⇧6",
	"thunderstorm": "⇧7", "hurricane": "⇧8",
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
var _emoji_font: FontFile
var _palette_group: ButtonGroup
var _kind_buttons: Dictionary = {}       # kind -> Button, so thumbnails can be filled in async

var _status_panel: PanelContainer
var _inspector_panel: PanelContainer
var _palette_panel: PanelContainer

var _status_label: Label
var _readout_label: Label
var _inspector_title: Label
var _inspector_lines: VBoxContainer

var _audio_panel: LAAudioMenuPanel
var _audio_button: Button

var _ui_panels: Array[Control] = []


func _ready() -> void:
	layer = 100
	_emoji_font = _load_emoji_font()
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
	_build_audio_menu(root)

	clear_inspector()
	set_status("Ready")
	set_process(true)

	# Reveal palette entries as their spawn capabilities are earned (campaign). No-op when no progression exists.
	var prog: LAGameProgression = LAGameProgression.active()
	if prog != null:
		prog.capability_unlocked.connect(func(_id: String) -> void: _refresh_palette_locks())


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


## Programmatically arm a kind (used by VoxelWorld's keyboard hotkeys). Drives the palette
## button group so the visual toggle state and _armed_kind stay in sync; "" returns to Select.
func arm_kind(kind: String) -> void:
	if _palette_group == null:
		return
	if kind == "":
		var pressed: BaseButton = _palette_group.get_pressed_button()
		if pressed != null:
			pressed.button_pressed = false          # -> _on_palette_toggled emits ""
		elif _armed_kind != "":
			_armed_kind = ""
			spawn_selected.emit("")
		return
	# Campaign gating: refuse to arm a spawn the player has not earned (also blocks the number hotkeys).
	if not LAGameProgression.spawn_unlocked(kind):
		set_status("%s is locked — earn it in the campaign." % String(KIND_LABELS.get(kind, kind)))
		return
	for btn in _palette_group.get_buttons():
		if String(btn.get_meta("kind", "")) == kind:
			btn.button_pressed = true               # -> _on_palette_toggled emits the kind
			return


## Wire the audio menu to the live audio director.
func set_audio_director(director: LocalAgentsAudioDirector) -> void:
	if _audio_panel != null:
		_audio_panel.bind(director)


## Show/hide the audio menu (bound to the HUD button and the KEY_M hotkey).
func toggle_audio_menu() -> void:
	if _audio_panel == null:
		return
	var showing: bool = not _audio_panel.visible
	_audio_panel.visible = showing
	if _audio_button != null:
		_audio_button.button_pressed = showing


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

	# Cursor / select button (disarms the palette). Icon-only crosshair; Esc also triggers it.
	var select_btn: Button = Button.new()
	select_btn.tooltip_text = "Select  (Esc)\nCursor mode: click entities to inspect"
	select_btn.icon = _make_cursor_icon()
	select_btn.custom_minimum_size = Vector2(52.0, 56.0)
	select_btn.focus_mode = Control.FOCUS_NONE
	select_btn.pressed.connect(_on_select_pressed)
	row.add_child(select_btn)

	# Two visible clusters, each captioned: Life | Disasters.
	row.add_child(_make_cluster(_palette_group, "LIFE", LIFE_KINDS))
	row.add_child(_make_cluster(_palette_group, "DISASTERS", DISASTER_KINDS))

	_ui_panels.append(_palette_panel)

	# Swap the life/prop buttons' emoji glyphs for isometric renders of their actual models
	# (async: renders into an off-screen SubViewport over the next few frames).
	_generate_thumbnails()


## A captioned cluster: a leading VSeparator, a small dim caption label, then one icon-only
## toggle button per kind (all sharing the palette's exclusive ButtonGroup).
func _make_cluster(group: ButtonGroup, caption: String, kinds: PackedStringArray) -> HBoxContainer:
	var cluster: HBoxContainer = HBoxContainer.new()
	cluster.add_theme_constant_override("separation", 6)

	cluster.add_child(VSeparator.new())

	var cap: Label = Label.new()
	cap.text = caption
	cap.add_theme_color_override("font_color", COL_TEXT_DIM)
	cap.add_theme_font_size_override("font_size", 11)
	cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cluster.add_child(cap)

	for kind in kinds:
		cluster.add_child(_make_kind_button(group, kind))
	return cluster


## An icon-only spawn button: the kind's emoji glyph (bundled emoji font), a name+hotkey
## tooltip, joined to the shared exclusive group and tagged with its "kind" meta. Falls back
## to the text label if the emoji font failed to load, so a button is never blank.
func _make_kind_button(group: ButtonGroup, kind: String) -> Button:
	var label: String = String(KIND_LABELS.get(kind, kind))
	var hotkey: String = String(KIND_HOTKEYS.get(kind, ""))
	var btn: Button = Button.new()
	if _emoji_font != null:
		btn.text = String(KIND_SYMBOLS.get(kind, ""))
		btn.add_theme_font_override("font", _emoji_font)
		btn.add_theme_font_size_override("font_size", 22)
	else:
		btn.text = label
	if hotkey.is_empty():
		btn.tooltip_text = "Arm %s for placement" % label
	else:
		btn.tooltip_text = "%s  (%s)\nRight-click terrain to place" % [label, hotkey]
	btn.toggle_mode = true
	btn.button_group = group
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(52.0, 56.0)
	btn.set_meta("kind", kind)
	btn.toggled.connect(_on_palette_toggled)
	# Campaign gating: hide-by-disable the entries the player has not earned yet (sandbox / no progression = all on).
	btn.disabled = not LAGameProgression.spawn_unlocked(kind)
	_kind_buttons[kind] = btn
	return btn


## Re-enable each palette entry whose spawn capability is now unlocked (campaign). Wired to the progression's
## capability_unlocked signal; a no-op when no progression instance exists.
func _refresh_palette_locks() -> void:
	for kind in _kind_buttons:
		var btn: Button = _kind_buttons[kind]
		if btn != null and is_instance_valid(btn):
			btn.disabled = not LAGameProgression.spawn_unlocked(String(kind))


func _build_audio_menu(root: Control) -> void:
	# The menu panel itself (hidden until toggled).
	_audio_panel = AudioMenuPanelScript.new()
	_audio_panel.name = "AudioMenu"
	root.add_child(_audio_panel)
	_audio_panel.auto_adapt_changed.connect(_on_audio_auto_adapt_changed)
	_ui_panels.append(_audio_panel)

	# A small toggle button anchored top-left, below the status bar.
	var holder: PanelContainer = PanelContainer.new()
	holder.name = "AudioToggle"
	holder.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	holder.offset_left = 12.0
	holder.offset_top = 60.0
	holder.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(holder)

	var margin: MarginContainer = _make_margin(6, 4)
	holder.add_child(margin)

	_audio_button = Button.new()
	_audio_button.text = "♪ Audio"
	_audio_button.tooltip_text = "Audio & music menu (M)"
	_audio_button.toggle_mode = true
	_audio_button.focus_mode = Control.FOCUS_NONE
	_audio_button.toggled.connect(_on_audio_button_toggled)
	margin.add_child(_audio_button)

	_ui_panels.append(holder)


# ---------------------------------------------------------------------------
# Interaction
# ---------------------------------------------------------------------------

func _on_audio_button_toggled(pressed_state: bool) -> void:
	if _audio_panel != null:
		_audio_panel.visible = pressed_state


func _on_audio_auto_adapt_changed(on: bool) -> void:
	music_auto_adapt_changed.emit(on)

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

## Load the bundled emoji subset for the palette symbols. Uses load_dynamic_font so it works
## straight from the raw .ttf with no editor import step. Returns null on any failure, and the
## palette then falls back to text labels so a button is never blank.
func _load_emoji_font() -> FontFile:
	if not FileAccess.file_exists(EMOJI_FONT_PATH):
		push_warning("SpawnPaletteHud: emoji font missing at %s -- palette falls back to text." % EMOJI_FONT_PATH)
		return null
	var f: FontFile = FontFile.new()
	var err: int = f.load_dynamic_font(EMOJI_FONT_PATH)
	if err != OK:
		push_warning("SpawnPaletteHud: failed to load emoji font (err %d)." % err)
		return null
	return f


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
	t.set_color("font_disabled_color", "Button", Color(COL_TEXT_DIM.r, COL_TEXT_DIM.g, COL_TEXT_DIM.b, 0.35))
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

	# --- Controls used by the audio menu (OptionButton, HSlider, CheckButton, etc.) ---
	# OptionButton reuses the Button styleboxes plus a styled dropdown popup.
	t.set_stylebox("normal", "OptionButton", btn_normal)
	t.set_stylebox("hover", "OptionButton", btn_hover)
	t.set_stylebox("pressed", "OptionButton", btn_pressed)
	t.set_stylebox("focus", "OptionButton", btn_focus)
	t.set_stylebox("disabled", "OptionButton", btn_normal)
	t.set_color("font_color", "OptionButton", COL_TEXT)
	t.set_color("font_hover_color", "OptionButton", COL_TEXT_HEADING)
	t.set_font_size("font_size", "OptionButton", 13)

	var popup_sb: StyleBoxFlat = _panel_stylebox(COL_BG_2)
	popup_sb.set_content_margin_all(4)
	t.set_stylebox("panel", "PopupMenu", popup_sb)
	t.set_color("font_color", "PopupMenu", COL_TEXT)
	t.set_color("font_hover_color", "PopupMenu", COL_TEXT_HEADING)
	var popup_hover: StyleBoxFlat = StyleBoxFlat.new()
	popup_hover.bg_color = COL_ACCENT_DIM
	popup_hover.set_corner_radius_all(4)
	t.set_stylebox("hover", "PopupMenu", popup_hover)

	# HSlider: a thin track with a bright round grabber.
	var slider_track: StyleBoxFlat = StyleBoxFlat.new()
	slider_track.bg_color = COL_BG_2
	slider_track.set_corner_radius_all(3)
	slider_track.content_margin_top = 3
	slider_track.content_margin_bottom = 3
	t.set_stylebox("slider", "HSlider", slider_track)
	var slider_fill: StyleBoxFlat = StyleBoxFlat.new()
	slider_fill.bg_color = COL_ACCENT_DIM
	slider_fill.set_corner_radius_all(3)
	t.set_stylebox("grabber_area", "HSlider", slider_fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", slider_fill)
	var grabber: ImageTexture = _make_grabber_icon()
	t.set_icon("grabber", "HSlider", grabber)
	t.set_icon("grabber_highlight", "HSlider", grabber)
	t.set_icon("grabber_disabled", "HSlider", grabber)

	# CheckButton (toggle switch) — text color; keep default engine on/off icons.
	t.set_color("font_color", "CheckButton", COL_TEXT)
	t.set_color("font_hover_color", "CheckButton", COL_TEXT_HEADING)
	t.set_font_size("font_size", "CheckButton", 13)
	var transparent: StyleBoxEmpty = StyleBoxEmpty.new()
	t.set_stylebox("normal", "CheckButton", transparent)
	t.set_stylebox("hover", "CheckButton", transparent)
	t.set_stylebox("pressed", "CheckButton", transparent)
	t.set_stylebox("focus", "CheckButton", transparent)

	# ScrollContainer / GridContainer inherit sensible defaults; give the scrollbar a subtle grabber.
	var scroll_grabber: StyleBoxFlat = StyleBoxFlat.new()
	scroll_grabber.bg_color = COL_BORDER
	scroll_grabber.set_corner_radius_all(3)
	t.set_stylebox("grabber", "VScrollBar", scroll_grabber)
	t.set_stylebox("grabber_highlight", "VScrollBar", scroll_grabber)
	t.set_stylebox("grabber_pressed", "VScrollBar", scroll_grabber)

	return t


## A small round grabber texture for the volume/parameter sliders (no external assets).
func _make_grabber_icon() -> ImageTexture:
	var s: int = 16
	var img: Image = Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c: Vector2 = Vector2(s / 2.0, s / 2.0)
	var r: float = s / 2.0 - 1.0
	for y in s:
		for x in s:
			var d: float = Vector2(x + 0.5, y + 0.5).distance_to(c)
			if d <= r - 3.0:
				img.set_pixel(x, y, COL_ACCENT)
			elif d <= r:
				img.set_pixel(x, y, COL_TEXT_HEADING)
	return ImageTexture.create_from_image(img)


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
# Model thumbnails (isometric off-screen render per spawnable model)
# ---------------------------------------------------------------------------

# The "tree" button spawns a mixed forest; show the oak as its representative render.
func _thumb_model_id(kind: String) -> String:
	return "tree_oak" if kind == "tree" else kind


# Render each life/prop button's model to an isometric thumbnail and swap it in for the emoji.
# Runs across frames (SubViewport needs a draw); no-ops gracefully in headless (blank readback).
func _generate_thumbnails() -> void:
	# Off-screen 3D rendering needs a real display server; headless keeps the emoji glyphs.
	if DisplayServer.get_name() == "headless":
		return
	for kind in LIFE_KINDS:
		var model_id: String = _thumb_model_id(kind)
		if LAActorModels.path(model_id).is_empty():
			continue
		var btn: Button = _kind_buttons.get(kind, null)
		if btn == null:
			continue
		var tex: ImageTexture = await _render_thumbnail(model_id)
		if tex != null and is_instance_valid(btn):
			btn.text = ""                    # drop the emoji glyph
			btn.icon = tex
			btn.expand_icon = true


# Build the model in an isolated SubViewport under an orthographic isometric camera, let it draw,
# and read the framebuffer back into an ImageTexture. Returns null if it couldn't render.
func _render_thumbnail(model_id: String) -> ImageTexture:
	var def: Dictionary = LAActorModels.get_def(model_id)
	var model: Node3D = LAModelVisual.build(
		String(def.get("path", "")), 1.0, "center",
		float(def.get("yaw", 0.0)), LAActorModels.tint(model_id))
	if model == null:
		return null
	LAModelVisual.recolor(model, LAActorModels.recolor(model_id))   # match the in-world foliage fix

	var sv: SubViewport = SubViewport.new()
	sv.size = Vector2i(THUMB_PX, THUMB_PX)
	sv.transparent_bg = true
	sv.own_world_3d = true
	sv.msaa_3d = Viewport.MSAA_4X
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	var cam: Camera3D = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 1.5
	# Models face -Z (their nose); view from the -Z side for a 3/4 front portrait.
	cam.position = Vector3(1.4, 1.15, -1.7)
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.64, 0.68)
	env.ambient_light_energy = 1.0
	cam.environment = env
	sv.add_child(cam)

	var light: DirectionalLight3D = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45.0, 40.0, 0.0)
	light.light_energy = 1.3
	sv.add_child(light)

	sv.add_child(model)
	add_child(sv)
	cam.look_at(Vector3.ZERO, Vector3.UP)   # aim once the camera is inside the tree

	# Two frames so the SubViewport actually draws before we read it back.
	await get_tree().process_frame
	await get_tree().process_frame

	var img: Image = sv.get_texture().get_image()
	sv.queue_free()
	if img == null or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------------------
# Icon generation (drawn to an Image -> ImageTexture, no external files)
# ---------------------------------------------------------------------------

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
