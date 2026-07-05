class_name LAStreamerOverlay
extends CanvasLayer

## Lower-right "face-cam" overlay for the streamer/commentator: a live 3D avatar portrait, the current
## commentary caption, an enable checkbox, and a personality picker. Self-contained CanvasLayer built
## in code (same convention as DebugPanel/SpawnPaletteHud). The PanelContainer's default STOP mouse
## filter consumes clicks over its rect, so toggling the UI never leaks a world-click (meteor drop)
## to the sim behind it.
##
## Emits `enabled_toggled(on)` and `persona_selected(id)`; the world wires those to the director.
## (Explicit types only — project rule: no ':=' inferred typing.)

signal enabled_toggled(on: bool)
signal persona_selected(id: String)
signal avatar_selected(flavor: String)

const CAPTION_HOLD: float = 8.0   # seconds a line stays bright before dimming

var _panel: PanelContainer = null
var _avatar_rect: TextureRect = null
var _caption: Label = null
var _status: Label = null
var _check: CheckButton = null
var _persona: OptionButton = null
var _avatar_pick: OptionButton = null

var _caption_ttl: float = 0.0


func _ready() -> void:
	layer = 90
	_build_ui()


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.name = "StreamerPanel"
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_panel.offset_right = -14.0
	_panel.offset_bottom = -14.0
	_panel.custom_minimum_size = Vector2(268.0, 0.0)

	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.10, 0.88)
	style.border_color = Color(0.55, 0.20, 0.65, 0.9)   # streamer purple accent
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(8.0)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	_panel.add_child(vbox)

	# --- LIVE badge + avatar portrait ---
	var badge: Label = Label.new()
	badge.text = "● LIVE"
	badge.add_theme_font_size_override("font_size", 12)
	badge.add_theme_color_override("font_color", Color(0.95, 0.25, 0.30))
	vbox.add_child(badge)

	_avatar_rect = TextureRect.new()
	_avatar_rect.custom_minimum_size = Vector2(252.0, 210.0)
	_avatar_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_avatar_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	vbox.add_child(_avatar_rect)

	# --- caption ---
	_caption = Label.new()
	_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_caption.custom_minimum_size = Vector2(252.0, 48.0)
	_caption.add_theme_font_size_override("font_size", 14)
	_caption.text = "Warming up the stream…"
	vbox.add_child(_caption)

	# --- controls: enable + persona ---
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	vbox.add_child(row)

	_check = CheckButton.new()
	_check.text = "Commentary"
	_check.button_pressed = true
	_check.add_theme_font_size_override("font_size", 12)
	_check.toggled.connect(_on_check_toggled)
	row.add_child(_check)

	_persona = OptionButton.new()
	_persona.add_theme_font_size_override("font_size", 12)
	_persona.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for preset in LAStreamerPersonas.PRESETS:
		_persona.add_item(String(preset.get("label", "")))
		_persona.set_item_metadata(_persona.item_count - 1, String(preset.get("id", "")))
	_persona.item_selected.connect(_on_persona_selected)
	row.add_child(_persona)

	# --- avatar (streamer) picker ---
	_avatar_pick = OptionButton.new()
	_avatar_pick.add_theme_font_size_override("font_size", 12)
	_avatar_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_avatar_pick.add_item("Ryan (M)")
	_avatar_pick.set_item_metadata(0, "male")
	_avatar_pick.add_item("Nova (F)")
	_avatar_pick.set_item_metadata(1, "female")
	_avatar_pick.item_selected.connect(_on_avatar_selected)
	vbox.add_child(_avatar_pick)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 10)
	_status.add_theme_color_override("font_color", Color(0.6, 0.62, 0.68))
	_status.text = ""
	vbox.add_child(_status)


## Bind the live avatar texture (the avatar node owns the SubViewport and must be in the tree already).
func bind_avatar(avatar: Node) -> void:
	if avatar != null and avatar.has_method("get_texture"):
		var tex = avatar.get_texture()
		if tex != null:
			_avatar_rect.texture = tex


func show_line(text: String) -> void:
	if _caption == null:
		return
	_caption.text = text
	_caption.modulate.a = 1.0
	_caption_ttl = CAPTION_HOLD


func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


func set_default_persona(id: String) -> void:
	if _persona == null:
		return
	for i in range(_persona.item_count):
		if String(_persona.get_item_metadata(i)) == id:
			_persona.select(i)
			return


func _on_check_toggled(pressed: bool) -> void:
	emit_signal("enabled_toggled", pressed)
	if _panel != null:
		_avatar_rect.modulate.a = 1.0 if pressed else 0.35


func _on_persona_selected(index: int) -> void:
	emit_signal("persona_selected", String(_persona.get_item_metadata(index)))


func set_default_avatar(flavor: String) -> void:
	if _avatar_pick == null:
		return
	for i in range(_avatar_pick.item_count):
		if String(_avatar_pick.get_item_metadata(i)) == flavor:
			_avatar_pick.select(i)
			return


func _on_avatar_selected(index: int) -> void:
	emit_signal("avatar_selected", String(_avatar_pick.get_item_metadata(index)))


func _process(delta: float) -> void:
	if _caption_ttl > 0.0:
		_caption_ttl -= delta
		if _caption_ttl <= 0.0 and _caption != null:
			_caption.modulate.a = 0.45   # dim old lines so the freshest reads as current
