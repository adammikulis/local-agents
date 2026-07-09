extends CanvasLayer

## LAVoxelViewControls — the small on-screen view-controls cluster the input controller hosts:
##   [Planet | Solar System]   ·   [Free | Geosync]   ·   [Auto-spin]
## Planet/Solar switches the camera between the close planet orbit and the pulled-back solar-system overview
## (planet + visible sun); Free/Geosync switches the rotation mode (camera fixed in world vs riding the
## planet's spin, locked over one region); Auto-spin is the free-mode "planet turns in front of you" option.
## Buttons call straight back into the host (LAVoxelInputController); refresh() mirrors the host state.
## Anchored top-centre, below the status bar, clear of the left DEBUG panel and the right Inspector.
## (Explicit types only — no ':=' inferred typing.)

const PANEL_BG: Color = Color(0.05, 0.07, 0.11, 0.9)
const ACCENT: Color = Color(0.55, 0.72, 1.0)

var _host = null
var _planet_btn: Button = null
var _solar_btn: Button = null
var _free_btn: Button = null
var _geo_btn: Button = null
var _spin_btn: Button = null


func _init() -> void:
	layer = 120


func setup(host) -> void:
	_host = host
	_build_ui()


func _build_ui() -> void:
	var root: Control = Control.new()
	root.set_anchors_preset(Control.PRESET_TOP_WIDE)
	root.offset_top = 44.0
	root.offset_bottom = 96.0
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var row: HBoxContainer = HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_TOP_WIDE)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(row)

	var panel: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.set_corner_radius_all(8)
	style.set_border_width_all(1)
	style.border_color = ACCENT
	style.set_content_margin_all(6.0)
	panel.add_theme_stylebox_override("panel", style)
	row.add_child(panel)

	var box: HBoxContainer = HBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)

	var view_group: ButtonGroup = ButtonGroup.new()
	_planet_btn = _make_button("Planet", view_group, box)
	_planet_btn.pressed.connect(func() -> void: _host.set_solar_view(false))
	_solar_btn = _make_button("Solar System", view_group, box)
	_solar_btn.pressed.connect(func() -> void: _host.set_solar_view(true))

	_add_divider(box)

	var rot_group: ButtonGroup = ButtonGroup.new()
	_free_btn = _make_button("Free", rot_group, box)
	_free_btn.pressed.connect(func() -> void: _host.set_geosync(false))
	_geo_btn = _make_button("Geosync", rot_group, box)
	_geo_btn.pressed.connect(func() -> void: _host.set_geosync(true))

	_add_divider(box)

	_spin_btn = _make_button("Auto-spin", null, box)
	_spin_btn.toggled.connect(func(on: bool) -> void: _host.set_auto_spin(on))


func _make_button(text: String, group: ButtonGroup, parent: Control) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0.0, 30.0)
	if group != null:
		b.button_group = group
	parent.add_child(b)
	return b


func _add_divider(parent: Control) -> void:
	var sep: Label = Label.new()
	sep.text = "·"
	sep.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	parent.add_child(sep)


## Mirror the host's camera-mode state onto the buttons (no-signal so it doesn't re-fire the callbacks).
func refresh(solar_view: bool, geosync: bool, auto_spin: bool) -> void:
	if _planet_btn == null:
		return
	_planet_btn.set_pressed_no_signal(not solar_view)
	_solar_btn.set_pressed_no_signal(solar_view)
	_free_btn.set_pressed_no_signal(not geosync)
	_geo_btn.set_pressed_no_signal(geosync)
	_spin_btn.set_pressed_no_signal(auto_spin)
