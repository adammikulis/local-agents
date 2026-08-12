class_name LAHelpCodex
extends Control


const IMG_DIR: String = "res://docs/help-img/"

## The mini-guides. Each is pure data: a nav title, the screenshot filename (under IMG_DIR; "" = none), and
## a short body. Order is the reading order in the nav list.
const ENTRIES: Array = [
	{
		"title": "Spawn & caretaker tools",
		"image": "ecosystem.png",
		"body": "The palette along the bottom is your caretaker toolkit. The left cluster spawns life: plants, trees, rabbits, foxes, birds, vultures, villagers and fish. The right cluster aims a meteor, the one thing that really does arrive from outside. Click a button (or press its number key) to arm it, then click the terrain to place. Hold and drag to paint a whole radius at once, and use the brush keys to size that radius. Click the crosshair, or press Esc, to return to select mode.",
	},
	{
		"title": "Weather and geology",
		"image": "disaster.png",
		"body": "Weather and geology cannot be spawned. An eruption is molten rock that reached the surface; a storm is a low the wind and pressure field grew; lightning fires when a cloud charges to breakdown. The game watches for these in the field and marks them where it finds them. The one thing you can aim is a meteor, because a rock really does arrive from outside. Watch how the world reacts: fire spreads downwind, herds stampede from a strike, predators scatter. Weathering a phenomenon is also a campaign goal.",
	},
	{
		"title": "Time control",
		"image": "ecosystem.png",
		"body": "Press Esc to pause and open the pause menu. Its time-speed row runs the simulation faster (up to sixteen steps per rendered frame), so slow, emergent processes like geology, forest succession and climate drift compress from hours into seconds. Drop back to 1x whenever you want to watch a single moment unfold at normal pace.",
	},
	{
		"title": "Camera & the overview unlocks",
		"image": "solar.png",
		"body": "Drag to rotate the planet; scroll to zoom. The view-controls bar at the top switches camera modes: Orbit keeps the camera fixed in world, Geosync rides the planet's spin locked over one region, and Fly is a free-flight drone. Auto-spin turns the planet in front of you. In a campaign, Geosync and the pulled-back Solar-system overview are earned unlocks. The overview, which frames the planet and its sun together, is the final reward.",
	},
	{
		"title": "Campaign goals",
		"image": "ecosystem.png",
		"body": "A new campaign hands you a ladder of objectives, tracked live from the world's own telemetry, with no busywork. Rally a herd of twelve, grow the world to a hundred and seventy creatures, raise a bloodline to its third generation, then weather a natural disaster and survey the heavens. Each objective you clear unlocks new spawns or camera powers. Sandbox mode turns the ladder off and unlocks everything for free play.",
	},
	{
		"title": "Creatures & the thought inspector",
		"image": "inspector.png",
		"body": "Every creature is driven by a local language model running on your machine, with no cloud and no network. Click a creature to select it and open the inspector: it shows the animal's state, needs and, where available, the reasoning behind its current decision. The same local models also drive the optional streamer overlay that narrates your world. Toggle the streamer, the HUD and the field overlays from the interface hotkeys.",
	},
	{
		"title": "Quality & audio settings",
		"image": "",
		"body": "The Settings screen on the main menu tunes two groups. Quality picks a performance preset (low, medium or high) mapping to grid resolution, actor budget and effects level. Drop it to low if your GPU struggles. Audio sets the master, music and sfx volumes.",
	},
]

@onready var _nav: VBoxContainer = $Row/NavScroll/Nav
@onready var _detail_title: Label = $Row/DetailPanel/Detail/Title
@onready var _detail_image: TextureRect = $Row/DetailPanel/Detail/Image
@onready var _detail_caption: Label = $Row/DetailPanel/Detail/Caption
@onready var _detail_body: Label = $Row/DetailPanel/Detail/BodyScroll/Body

var _nav_group: ButtonGroup = null


func _ready() -> void:
	_build_nav()
	if not ENTRIES.is_empty():
		_show_entry(0)


# One toggle button per ENTRIES row, in an exclusive group.
func _build_nav() -> void:
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
		_nav.add_child(btn)


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
