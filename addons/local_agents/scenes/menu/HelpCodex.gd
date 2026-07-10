class_name LAHelpCodex
extends Control

## LAHelpCodex — the browsable in-game manual: a left-hand list of core-mechanic entries and a right-hand
## detail pane (title + screenshot + a short written mini-guide) for the selected one. Aimed at a player who
## finished the campaign, stepped away, and wants to re-acquaint from the screen — distinct from the one-time
## guided tutorial. Self-contained and embeddable: the main-menu Help screen and the in-sim pause overlay both
## drop one in as a tab. Screenshots live under res://docs/help-img/ and load gracefully (a missing image just
## shows a caption, never a crash). Content is sentence-case data — no per-entry code. (Explicit types only.)

const ACCENT: Color = Color(0.55, 0.72, 1.0)
const TEXT: Color = Color(0.90, 0.92, 0.95)
const TEXT_DIM: Color = Color(0.62, 0.66, 0.72)
const PANEL_BG: Color = Color(0.09, 0.11, 0.15, 1.0)
const BORDER: Color = Color(0.30, 0.36, 0.46, 1.0)

const IMG_DIR: String = "res://docs/help-img/"

## The mini-guides. Each is pure data: a nav title, the screenshot filename (under IMG_DIR; "" = none), and
## a short body. Order is the reading order in the nav list.
const ENTRIES: Array = [
	{
		"title": "Spawn & caretaker tools",
		"image": "ecosystem.png",
		"body": "The palette along the bottom is your caretaker toolkit. The left cluster spawns life — plants, trees, rabbits, foxes, birds, vultures, villagers and fish; the right cluster seeds disasters. Click a button (or press its number key) to arm it, then click the terrain to place. Hold and drag to paint a whole radius at once, and use the brush keys to size that radius. Click the crosshair, or press Esc, to return to select mode.",
	},
	{
		"title": "Natural disasters",
		"image": "disaster.png",
		"body": "Disasters are not scripted set-pieces — each is just matter given the physics to misbehave. A volcano is pressure escaping through rock; a meteor is momentum; a flood, quake, tornado, storm and hurricane all fall out of the same shared field of heat, pressure, water and wind. Seed one from the disasters cluster and watch how the world reacts: fire spreads downwind, herds stampede from a strike, predators scatter. Weathering one is also a campaign goal.",
	},
	{
		"title": "Time control",
		"image": "ecosystem.png",
		"body": "Press Esc to pause and open the pause menu. Its time-speed row runs the simulation faster — up to sixteen steps per rendered frame — so slow, emergent processes like geology, forest succession and climate drift compress from hours into seconds. Drop back to 1x whenever you want to watch a single moment unfold at normal pace.",
	},
	{
		"title": "Camera & the overview unlocks",
		"image": "solar.png",
		"body": "Drag to rotate the planet; scroll to zoom. The view-controls bar at the top switches camera modes: Orbit keeps the camera fixed in world, Geosync rides the planet's spin locked over one region, and Fly is a free-flight drone. Auto-spin turns the planet in front of you. In a campaign, Geosync and the pulled-back Solar-system overview are earned unlocks — the overview, which frames the planet and its sun together, is the final reward.",
	},
	{
		"title": "Campaign goals",
		"image": "ecosystem.png",
		"body": "A new campaign hands you a ladder of objectives, tracked live from the world's own telemetry — no busywork. Rally a herd of twelve, grow the world to a hundred and seventy creatures, raise a bloodline to its third generation, then weather a natural disaster and survey the heavens. Each objective you clear unlocks new spawns or camera powers. Sandbox mode turns the ladder off and unlocks everything for free play.",
	},
	{
		"title": "Creatures & the thought inspector",
		"image": "inspector.png",
		"body": "Every creature is driven by a local language model running on your machine — no cloud, no network. Click a creature to select it and open the inspector: it shows the animal's state, needs and, where available, the reasoning behind its current decision. The same local models also drive the optional streamer overlay that narrates your world. Toggle the streamer, the HUD and the field overlays from the interface hotkeys.",
	},
	{
		"title": "Difficulty & quality settings",
		"image": "",
		"body": "The Settings screen on the main menu tunes three groups. Difficulty picks a preset — peaceful, normal or harsh — that seeds how often disasters strike and how extreme the climate swings, both of which you can then nudge by hand. Quality picks a performance preset — low, medium or high — mapping to grid resolution, actor budget and effects level; drop it to low if your GPU struggles. Audio sets the master, music and sfx volumes.",
	},
]

var _detail_title: Label = null
var _detail_image: TextureRect = null
var _detail_caption: Label = null
var _detail_body: Label = null
var _nav_group: ButtonGroup = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	if not ENTRIES.is_empty():
		_show_entry(0)


func _build() -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 14)
	add_child(row)

	# --- Left: nav list of entry titles (scrollable, exclusive toggle group) ---
	var nav_scroll: ScrollContainer = ScrollContainer.new()
	nav_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	nav_scroll.custom_minimum_size = Vector2(210.0, 0.0)
	nav_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(nav_scroll)

	var nav: VBoxContainer = VBoxContainer.new()
	nav.add_theme_constant_override("separation", 4)
	nav.custom_minimum_size = Vector2(198.0, 0.0)
	nav.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav_scroll.add_child(nav)

	_nav_group = ButtonGroup.new()
	for i in ENTRIES.size():
		var entry: Dictionary = ENTRIES[i]
		var btn: Button = Button.new()
		btn.text = String(entry.get("title", ""))
		btn.toggle_mode = true
		btn.button_group = _nav_group
		btn.focus_mode = Control.FOCUS_ALL
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.custom_minimum_size = Vector2(0.0, 38.0)
		btn.pressed.connect(_show_entry.bind(i))
		nav.add_child(btn)

	# --- Right: detail pane (title, screenshot, body) ---
	var detail_panel: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.set_corner_radius_all(8)
	style.set_border_width_all(1)
	style.border_color = BORDER
	style.set_content_margin_all(16.0)
	detail_panel.add_theme_stylebox_override("panel", style)
	detail_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(detail_panel)

	var detail: VBoxContainer = VBoxContainer.new()
	detail.add_theme_constant_override("separation", 12)
	detail_panel.add_child(detail)

	_detail_title = Label.new()
	_detail_title.add_theme_color_override("font_color", ACCENT)
	_detail_title.add_theme_font_size_override("font_size", 20)
	detail.add_child(_detail_title)

	_detail_image = TextureRect.new()
	_detail_image.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_detail_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_detail_image.custom_minimum_size = Vector2(0.0, 240.0)
	_detail_image.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_child(_detail_image)

	_detail_caption = Label.new()
	_detail_caption.add_theme_color_override("font_color", TEXT_DIM)
	_detail_caption.add_theme_font_size_override("font_size", 11)
	_detail_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	detail.add_child(_detail_caption)

	var body_scroll: ScrollContainer = ScrollContainer.new()
	body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail.add_child(body_scroll)

	_detail_body = Label.new()
	_detail_body.add_theme_color_override("font_color", TEXT)
	_detail_body.add_theme_font_size_override("font_size", 14)
	_detail_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_scroll.add_child(_detail_body)


func _show_entry(index: int) -> void:
	if index < 0 or index >= ENTRIES.size():
		return
	var entry: Dictionary = ENTRIES[index]
	_detail_title.text = String(entry.get("title", ""))
	_detail_body.text = String(entry.get("body", ""))

	# Reflect the selection in the nav group (so a code-driven _show_entry(0) also highlights the button).
	var buttons: Array[BaseButton] = _nav_group.get_buttons()
	if index < buttons.size():
		buttons[index].set_pressed_no_signal(true)

	var image_name: String = String(entry.get("image", ""))
	var tex: Texture2D = _load_image(image_name) if image_name != "" else null
	if tex != null:
		_detail_image.texture = tex
		_detail_image.visible = true
		_detail_caption.text = ""
		_detail_caption.visible = false
	else:
		_detail_image.texture = null
		_detail_image.visible = false
		_detail_caption.text = "(screenshot unavailable)" if image_name != "" else ""
		_detail_caption.visible = image_name != ""


## Load a screenshot by filename under IMG_DIR. Prefers the imported texture; falls back to reading the raw
## PNG off disk (headless / un-imported). Returns null on any failure so a missing image degrades gracefully.
static func _load_image(image_name: String) -> Texture2D:
	var path: String = IMG_DIR + image_name
	if ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is Texture2D:
			return res as Texture2D
	var abs: String = ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(abs):
		var img: Image = Image.new()
		if img.load(abs) == OK and not img.is_empty():
			return ImageTexture.create_from_image(img)
	return null
