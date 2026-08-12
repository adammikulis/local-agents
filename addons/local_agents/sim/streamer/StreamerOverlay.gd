class_name LAStreamerOverlay
extends CanvasLayer


signal enabled_toggled(on: bool)
signal persona_selected(id: String)
signal avatar_selected(flavor: String)
signal visibility_toggled(on: bool)   # master show/hide — the host gates streamer COMPUTE off when hidden

const CAPTION_HOLD: float = 8.0   # seconds a line stays bright before dimming
const FEED_MAX: int = 4           # recent commentary lines kept under the live caption

@onready var _panel: PanelContainer = $StreamerPanel
@onready var _avatar_rect: TextureRect = $StreamerPanel/VBox/AvatarRect
@onready var _caption: Label = $StreamerPanel/VBox/Caption
@onready var _feed: VBoxContainer = $StreamerPanel/VBox/Feed
@onready var _status: Label = $StreamerPanel/VBox/Status
@onready var _check: CheckButton = $StreamerPanel/VBox/Controls/Commentary
@onready var _persona: OptionButton = $StreamerPanel/VBox/Controls/Persona
@onready var _avatar_pick: OptionButton = $StreamerPanel/VBox/AvatarPick
@onready var _chip: Button = $Chip   # tiny restore affordance shown while the streamer is hidden
var _collapsed: bool = false

var _caption_ttl: float = 0.0


func _ready() -> void:
	# Persona rows are data (LAStreamerPersonas.PRESETS); the id rides on item metadata, which no scene
	# format stores, so both pickers get their metadata here.
	for preset in LAStreamerPersonas.PRESETS:
		_persona.add_item(String(preset.get("label", "")))
		_persona.set_item_metadata(_persona.item_count - 1, String(preset.get("id", "")))
	_avatar_pick.set_item_metadata(0, "male")
	_avatar_pick.set_item_metadata(1, "female")


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
	_push_feed(text)


# Roll the just-spoken line into the recent-lines feed (newest at top, bounded). Reads nothing — it is
# fed by the SAME show_line the caption uses, so it never duplicates the director's logic.
func _push_feed(text: String) -> void:
	if _feed == null:
		return
	var line: Label = Label.new()
	line.text = "› " + text
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.custom_minimum_size = Vector2(252.0, 0.0)
	line.add_theme_font_size_override("font_size", 11)
	line.add_theme_color_override("font_color", Color(0.72, 0.66, 0.82))
	_feed.add_child(line)
	_feed.move_child(line, 0)                        # newest at top
	while _feed.get_child_count() > FEED_MAX:         # bounded rolling history
		# remove_child first: a queue_free'd node stays a child until end of frame, so counting alone loops forever.
		var oldest: Node = _feed.get_child(_feed.get_child_count() - 1)
		_feed.remove_child(oldest)
		oldest.queue_free()


func _on_hide_pressed() -> void:
	set_collapsed(true)
	emit_signal("visibility_toggled", false)


func _on_chip_pressed() -> void:
	set_collapsed(false)
	emit_signal("visibility_toggled", true)


## Collapse the whole face-cam to a small restore chip (or expand it back). Visual only — it does NOT
## re-emit visibility_toggled, so the host can drive it (hotkey / persisted state) without a signal loop.
func set_collapsed(on: bool) -> void:
	_collapsed = on
	if _panel != null:
		_panel.visible = not on
	if _chip != null:
		_chip.visible = on


func is_collapsed() -> bool:
	return _collapsed


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
