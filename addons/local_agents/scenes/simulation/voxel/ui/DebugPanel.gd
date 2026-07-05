class_name LADebugPanel
extends CanvasLayer

## The left-docked DEBUG MENU. A collapsible column of toggles grouped into: field VIEWS (temperature
## heatmap, wind arrows, scent), type HIGHLIGHTS (light up every rabbit/fox/bird/…/nest so you can find
## them at a glance), overlay PATHS (each creature's intended heading), and PERF toggles (shadows, SSAO).
## It owns no state — each toggle just emits a signal VoxelWorld wires to the terrain shader, the debug
## overlay, or the environment. (Explicit types only — no ':=' inferred typing.)

signal view_toggled(view: String, on: bool)          # "temp" | "wind" | "scent"
signal highlight_toggled(group: String, on: bool)    # a "species_*" or "nest" group
signal paths_toggled(on: bool)
signal perf_toggled(key: String, on: bool)           # "shadows" | "ssao"

# Highlight rows: display label -> scene group to light up.
const HIGHLIGHTS: Array = [
	["Rabbits", "species_rabbit"], ["Foxes", "species_fox"], ["Birds", "species_bird"],
	["Vultures", "species_vulture"], ["Villagers", "species_villager"], ["Fish", "species_fish"],
	["Plants", "species_plant"], ["Nests", "nest"],
]

var _body: VBoxContainer = null
var _collapsed: bool = false


func _ready() -> void:
	layer = 50
	var panel: PanelContainer = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(10.0, 120.0)
	panel.custom_minimum_size = Vector2(172.0, 0.0)
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.11, 0.82)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(8.0)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	panel.add_child(col)

	# Header with a collapse toggle.
	var header: Button = Button.new()
	header.text = "▾  DEBUG"
	header.flat = true
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.add_theme_font_size_override("font_size", 13)
	header.pressed.connect(_toggle_collapsed)
	col.add_child(header)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 2)
	col.add_child(_body)

	_add_section("VIEWS")
	_add_check("Temperature", func(on: bool) -> void: view_toggled.emit("temp", on))
	_add_check("Wind", func(on: bool) -> void: view_toggled.emit("wind", on))
	_add_check("Scent", func(on: bool) -> void: view_toggled.emit("scent", on))

	_add_section("HIGHLIGHT")
	for row in HIGHLIGHTS:
		var group: String = row[1]
		_add_check(row[0], func(on: bool) -> void: highlight_toggled.emit(group, on))

	_add_section("OVERLAY")
	_add_check("Intended paths", func(on: bool) -> void: paths_toggled.emit(on))

	_add_section("PERF")
	var shadows: CheckButton = _add_check("Sun shadows", func(on: bool) -> void: perf_toggled.emit("shadows", on))
	shadows.button_pressed = true                    # on by default (matches the scene)
	var ssao: CheckButton = _add_check("SSAO", func(on: bool) -> void: perf_toggled.emit("ssao", on))
	ssao.button_pressed = true


func _toggle_collapsed() -> void:
	_collapsed = not _collapsed
	_body.visible = not _collapsed


func _add_section(title: String) -> void:
	var lbl: Label = Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Color(0.6, 0.68, 0.8))
	var m: MarginContainer = MarginContainer.new()
	m.add_theme_constant_override("margin_top", 4)
	m.add_child(lbl)
	_body.add_child(m)


func _add_check(label: String, cb: Callable) -> CheckButton:
	var c: CheckButton = CheckButton.new()
	c.text = label
	c.add_theme_font_size_override("font_size", 12)
	c.toggled.connect(cb)
	_body.add_child(c)
	return c
