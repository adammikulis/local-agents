class_name LASpawnPaletteHud
extends CanvasLayer


signal spawn_selected(kind: String)
## Re-exposed from the audio menu; VoxelWorld listens to gate its live mood feed.
signal music_auto_adapt_changed(on: bool)

## The groups this world's living things join; the status row counts them.
const LIVING_GROUPS: Array[String] = ["creature", "fish", "plant", "tree"]

# The palette is split into two visible clusters. Order within each drives the number hotkeys
# (LIFE -> 1..8, IMPACT -> Shift+1..8). A meteor is the only thing the player can cause: weather and
# geology are observed, never spawned.
const FLORA_KINDS: PackedStringArray = ["plant", "tree"]
const LIFE_KINDS: PackedStringArray = [
	"plant", "tree", "rabbit", "fox", "bird", "vulture", "villager", "fish",
]
const IMPACT_KINDS: PackedStringArray = [
	"meteor",
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
}

# Emoji glyph per kind, drawn in HudTheme's PaletteButton font. Swapping a glyph needs its codepoint added
# to the pyftsubset build in assets/fonts/.
const KIND_SYMBOLS: Dictionary = {
	"plant": "🌱",
	"tree": "🌲",
	"rabbit": "🐇",
	"fox": "🦊",
	"bird": "🐦",
	"vulture": "🦅",
	"villager": "🧑",
	"fish": "🐟",
	"meteor": "☄",
}

# HudTheme.tres type variations.
const STYLE_TITLE: StringName = &"InspectorTitle"
const STYLE_TITLE_IDLE: StringName = &"InspectorTitleIdle"
const STYLE_LINE: StringName = &"InspectorLine"
const STYLE_HINT: StringName = &"InspectorHint"
const STYLE_BADGE: StringName = &"HotkeyBadge"
const STYLE_BADGE_LOCKED: StringName = &"HotkeyBadgeLocked"

@export_group("Palette")
## Instanced once per offered kind; its HotkeyBadge child carries the key.
@export var palette_button: PackedScene
## The off-screen stage a spawn button's model is rendered in for its thumbnail.
@export var thumbnail_studio: PackedScene

@onready var _status_panel: PanelContainer = $HudRoot/StatusBar
@onready var _inspector_panel: PanelContainer = $HudRoot/Inspector
@onready var _palette_panel: PanelContainer = $HudRoot/SpawnPalette
@onready var _audio_holder: PanelContainer = $HudRoot/AudioToggle
@onready var _status_label: Label = $HudRoot/StatusBar/Margin/Row/Status
@onready var _readout_label: Label = $HudRoot/StatusBar/Margin/Row/Readout
@onready var _inspector_title: Label = $HudRoot/Inspector/Margin/Col/Title
@onready var _inspector_lines: VBoxContainer = $HudRoot/Inspector/Margin/Col/Lines
@onready var _select_button: Button = $HudRoot/SpawnPalette/Margin/Row/SelectBtn
@onready var _life_cluster: HBoxContainer = $HudRoot/SpawnPalette/Margin/Row/LifeCluster
@onready var _disaster_cluster: HBoxContainer = $HudRoot/SpawnPalette/Margin/Row/DisasterCluster
@onready var _audio_panel: LAAudioMenuPanel = $HudRoot/AudioMenu
@onready var _audio_button: Button = $HudRoot/AudioToggle/Margin/AudioButton

var _armed_kind: String = ""

var _palette_group: ButtonGroup
var _kind_buttons: Dictionary[String, Button] = {}

var _perf_detail: bool = false      # DEBUG-panel "Detailed perf": expands the FPS readout
var _ui_panels: Array[Control] = []


func _ready() -> void:
	_select_button.pressed.connect(_on_select_pressed)
	_audio_button.toggled.connect(_on_audio_button_toggled)
	_audio_panel.auto_adapt_changed.connect(_on_audio_auto_adapt_changed)

	_build_palette_buttons()
	_ui_panels = [_status_panel, _inspector_panel, _palette_panel, _audio_panel, _audio_holder]

	clear_inspector()
	set_status("Ready")
	set_process(true)

	# Reveal palette entries as their spawn capabilities are earned (campaign). No-op with no progression.
	var prog: LAGameProgression = LAGameProgression.active()
	if prog != null:
		prog.capability_unlocked.connect(func(_id: String) -> void: _refresh_palette_locks())


func _process(_delta: float) -> void:
	var fps: int = int(round(Engine.get_frames_per_second()))
	# THE ROW IS THE WORLD'S POPULATION, and a world holding no living thing has no row. What lives cannot
	# be counted off what can be clicked, which counts the moon.
	var alive: int = 0
	var tree: SceneTree = get_tree()
	if tree != null:
		for grp in LIVING_GROUPS:
			alive += tree.get_node_count_in_group(grp)
	var ents: String = "   |   %d alive" % alive if alive > 0 else ""
	if _perf_detail:
		var frame_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		var phys_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		var field_ms: float = LASimReport.gauge_cur("field_ms")
		var draws: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		_readout_label.text = "%d FPS  %.1fms   |   field %.1f  phys %.1f  draws %d%s" % [fps, frame_ms, field_ms, phys_ms, draws, ents]
	else:
		_readout_label.text = "%d FPS%s" % [fps, ents]


## DEBUG-panel toggle: show the detailed perf breakdown (frame/field/physics ms + draw calls) in the readout.
func set_perf_detail(on: bool) -> void:
	_perf_detail = on


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
	_inspector_title.theme_type_variation = STYLE_TITLE

	_clear_children(_inspector_lines)
	var lines: Array = payload.get("lines", [])
	if lines.is_empty():
		var empty: Label = _make_line_label("(no details)", STYLE_HINT)
		_inspector_lines.add_child(empty)
	else:
		for entry in lines:
			_inspector_lines.add_child(_make_line_label(str(entry), STYLE_LINE))


func clear_inspector() -> void:
	if _inspector_title == null:
		return
	_inspector_title.text = "Inspector"
	_inspector_title.theme_type_variation = STYLE_TITLE_IDLE
	_clear_children(_inspector_lines)
	var hint: Label = _make_line_label("Click an entity to inspect.", STYLE_HINT)
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
		set_status("%s is locked. Earn it in the campaign." % String(KIND_LABELS.get(kind, kind)))
		return
	var btn: Button = _kind_buttons.get(kind)
	if btn == null:
		# No button: this world holds nothing that kind is made of, so the hotkey says so rather than nothing.
		set_status("There are no %s in this world." % String(KIND_LABELS.get(kind, kind)).to_lower())
		return
	btn.button_pressed = true                   # -> _on_palette_toggled emits the kind


## Wire the audio menu to the live audio director.
func set_audio_director(director: LAAudioDirector) -> void:
	if _audio_panel != null:
		_audio_panel.bind(director)


## Show/hide the entire HUD overlay (spawn palette + inspector + status bar). Bound to the H hotkey via the
## shared registry; the 3D world keeps rendering underneath.
func toggle_visible() -> void:
	visible = not visible


## Show/hide the audio menu (bound to the HUD button and the KEY_M hotkey).
func toggle_audio_menu() -> void:
	if _audio_panel == null:
		return
	var showing: bool = not _audio_panel.visible
	_audio_panel.visible = showing
	if _audio_button != null:
		_audio_button.button_pressed = showing


# ---------------------------------------------------------------------------
# Palette buttons (one per kind, from the kind lists)
# ---------------------------------------------------------------------------

func _build_palette_buttons() -> void:
	_palette_group = ButtonGroup.new()
	_palette_group.allow_unpress = true

	# Each kind is offered only where its own kingdom lives in this world; with neither, the cluster
	# goes entirely, caption and all.
	_life_cluster.visible = LAWorldOffers.has_life() or LAWorldOffers.has_flora()
	for kind in LIFE_KINDS:
		var alive: bool = LAWorldOffers.has_flora() if FLORA_KINDS.has(kind) \
			else LAWorldOffers.offers_species(kind)
		if alive:
			_add_kind_button(_life_cluster, kind)
	# A rock from space needs a world that can answer for its fall, its heat and its crater.
	_disaster_cluster.visible = LAWorldOffers.has_impacts()
	if _disaster_cluster.visible:
		for kind in IMPACT_KINDS:
			_add_kind_button(_disaster_cluster, kind)
	# Nothing to place: the panel goes, not just its contents.
	_palette_panel.visible = _life_cluster.visible or _disaster_cluster.visible

	# What this world let the palette offer, for scripts/check_meteor_offer.sh.
	print('SPAWN_PALETTE={"panel":%s,"life":%s,"impact":%s,"kinds":%s}' % [
		str(_palette_panel.visible).to_lower(), str(_life_cluster.visible).to_lower(),
		str(_disaster_cluster.visible).to_lower(), JSON.stringify(_kind_buttons.keys())])

	# Swap the life/prop buttons' emoji glyphs for isometric renders of their actual models
	# (async: renders in the off-screen thumbnail studio over the next few frames).
	_generate_thumbnails()


## An icon-only spawn button instanced from `palette_button`: the kind's emoji glyph, a name+hotkey tooltip,
## the hotkey on its badge, and a place in the shared exclusive group.
func _add_kind_button(cluster: HBoxContainer, kind: String) -> void:
	var label: String = String(KIND_LABELS.get(kind, kind))
	var hotkey: String = LAHotkeyRegistry.spawn_label(kind)
	var btn: Button = palette_button.instantiate() as Button
	btn.text = String(KIND_SYMBOLS.get(kind, ""))
	if hotkey.is_empty():
		btn.tooltip_text = "Arm %s for placement" % label
	else:
		btn.tooltip_text = "%s  (%s)\nRight-click terrain to place" % [label, hotkey]
	btn.button_group = _palette_group
	btn.toggled.connect(_on_palette_toggled)
	var badge: Label = btn.get_node("HotkeyBadge") as Label
	badge.text = hotkey
	badge.visible = not hotkey.is_empty()
	cluster.add_child(btn)
	_kind_buttons[kind] = btn
	_apply_lock(kind)


## Campaign gating: an entry the player has not earned is disabled and its badge dimmed (sandbox / no
## progression = all on).
func _apply_lock(kind: String) -> void:
	var btn: Button = _kind_buttons[kind]
	var unlocked: bool = LAGameProgression.spawn_unlocked(kind)
	btn.disabled = not unlocked
	(btn.get_node("HotkeyBadge") as Label).theme_type_variation = STYLE_BADGE if unlocked else STYLE_BADGE_LOCKED


## Wired to the progression's capability_unlocked signal; a no-op when no progression instance exists.
func _refresh_palette_locks() -> void:
	for kind: String in _kind_buttons:
		_apply_lock(kind)


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
		current = String(_kind_buttons.find_key(pressed_btn))
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


func _make_line_label(text: String, style: StringName) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.theme_type_variation = style
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


func _clear_children(node: Node) -> void:
	if node == null:
		return
	for child in node.get_children():
		child.queue_free()
		node.remove_child(child)


# The "tree" button spawns a mixed forest; show the oak as its representative render.
func _thumb_model_id(kind: String) -> String:
	return "tree_oak" if kind == "tree" else kind


# Render each life/prop button's model to an isometric thumbnail and swap it in for the emoji.
# Runs across frames (SubViewport needs a draw); no-ops in headless (blank readback).
func _generate_thumbnails() -> void:
	# Off-screen 3D rendering needs a real display server; headless keeps the emoji glyphs.
	if DisplayServer.get_name() == "headless":
		return
	for kind in LIFE_KINDS:
		var model_id: String = _thumb_model_id(kind)
		if LAActorModels.path(model_id).is_empty():
			continue
		var btn: Button = _kind_buttons.get(kind)
		if btn == null:
			continue
		var tex: ImageTexture = await _render_thumbnail(model_id)
		if tex != null and is_instance_valid(btn):
			btn.text = ""                    # drop the emoji glyph
			btn.icon = tex
			btn.expand_icon = true


# Pose the model in the thumbnail studio, let it draw, and read the framebuffer back into an
# ImageTexture. Returns null if it couldn't render.
func _render_thumbnail(model_id: String) -> ImageTexture:
	var def: Dictionary = LAActorModels.get_def(model_id)
	var model: Node3D = LAModelVisual.build(
		String(def.get("path", "")), 1.0, "center",
		float(def.get("yaw", 0.0)), LAActorModels.tint(model_id))
	if model == null:
		return null
	LAModelVisual.recolor(model, LAActorModels.recolor(model_id))   # match the in-world foliage fix

	var studio: SubViewport = thumbnail_studio.instantiate() as SubViewport
	studio.add_child(model)
	add_child(studio)

	# Two frames so the SubViewport actually draws before we read it back.
	await get_tree().process_frame
	await get_tree().process_frame

	var img: Image = studio.get_texture().get_image()
	studio.queue_free()
	if img == null or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)
