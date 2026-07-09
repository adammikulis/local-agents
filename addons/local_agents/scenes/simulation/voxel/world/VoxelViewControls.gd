extends CanvasLayer

## LAVoxelViewControls — the small on-screen view-controls cluster the input controller hosts:
##   [Planet | Solar System]   ·   [Orbit | Geosync | Fly]   ·   [Auto-spin]
## Planet/Solar switches the camera between the close planet orbit and the pulled-back solar-system overview
## (planet + visible sun); Orbit/Geosync/Fly switches the camera mode (camera fixed in world · riding the
## planet's spin locked over one region · free-flight drone); Auto-spin is the orbit-mode "planet turns in
## front of you" option. Buttons call straight back into the host (LAVoxelInputController); refresh() mirrors
## the host state. Anchored top-centre, below the status bar, clear of the left DEBUG panel and right Inspector.
## (Explicit types only — no ':=' inferred typing.)

const PANEL_BG: Color = Color(0.05, 0.07, 0.11, 0.9)
const ACCENT: Color = Color(0.55, 0.72, 1.0)

var _host = null
var _planet_btn: Button = null
var _solar_btn: Button = null
var _orbit_btn: Button = null
var _geo_btn: Button = null
var _fly_btn: Button = null
var _spin_btn: Button = null
var _geo_hotkey: String = ""      # cached registry key labels folded into the gated tooltips
var _solar_hotkey: String = ""


func _init() -> void:
	layer = 120


func setup(host) -> void:
	_host = host
	_build_ui()
	_apply_locks()
	# Re-enable a button the instant its capability is earned (campaign). No-op when no progression exists.
	var prog: LAGameProgression = LAGameProgression.active()
	if prog != null:
		prog.capability_unlocked.connect(func(_id: String) -> void: _apply_locks())


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

	# Hotkey hint per view action, read from the shared registry so a tooltip and the controls-reference
	# screen never disagree about which key drives a mode.
	var solar_key: String = LAHotkeyRegistry.key_for_action("view_solar")
	var geo_key: String = LAHotkeyRegistry.key_for_action("view_geosync")
	var fly_key: String = LAHotkeyRegistry.key_for_action("view_fly")
	var spin_key: String = LAHotkeyRegistry.key_for_action("view_auto_spin")

	var view_group: ButtonGroup = ButtonGroup.new()
	_planet_btn = _make_button("Planet", view_group, box)
	_planet_btn.tooltip_text = "Close planet view  (%s toggles the overview)" % solar_key
	_planet_btn.pressed.connect(func() -> void: _host.set_solar_view(false))
	_solar_btn = _make_button("Solar System", view_group, box)
	_solar_btn.pressed.connect(func() -> void: _host.set_solar_view(true))

	_add_divider(box)

	var rot_group: ButtonGroup = ButtonGroup.new()
	_orbit_btn = _make_button("Orbit", rot_group, box)
	_orbit_btn.tooltip_text = "Orbit — camera stays fixed in world; drag to rotate"
	_orbit_btn.pressed.connect(func() -> void: _host.set_orbit_mode())
	_geo_btn = _make_button("Geosync", rot_group, box)
	_geo_btn.pressed.connect(func() -> void: _host.set_geosync(true))
	_fly_btn = _make_button("Fly", rot_group, box)
	_fly_btn.tooltip_text = "Fly — free-flight drone  (%s)" % fly_key
	_fly_btn.pressed.connect(func() -> void: _host.set_fly(true))

	_add_divider(box)

	_spin_btn = _make_button("Auto-spin", null, box)
	_spin_btn.tooltip_text = "Turn the planet in front of you  (%s)" % spin_key
	_spin_btn.toggled.connect(func(on: bool) -> void: _host.set_auto_spin(on))
	# Geosync / Solar tooltips (which fold in the campaign-lock state) are set by _apply_locks() below.
	_geo_hotkey = geo_key
	_solar_hotkey = solar_key


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


## Grey out the view-mode buttons whose capability is not yet earned (campaign). Geosync and the solar-system
## overview are gated unlocks; orbit stays available from the start. Sandbox / no progression = all enabled.
func _apply_locks() -> void:
	if _geo_btn == null:
		return
	_geo_btn.disabled = not LAGameProgression.cap_unlocked("view_geosync")
	_solar_btn.disabled = not LAGameProgression.cap_unlocked("view_solar")
	_geo_btn.tooltip_text = ("Geosync — ride the planet's spin over one region  (%s)" % _geo_hotkey) if not _geo_btn.disabled else "Geosync — locked (earn it in the campaign)"
	_solar_btn.tooltip_text = ("Solar-system overview — planet + sun  (%s)" % _solar_hotkey) if not _solar_btn.disabled else "Solar System — locked (campaign capstone)"


## Mirror the host's camera-mode state onto the buttons (no-signal so it doesn't re-fire the callbacks).
func refresh(solar_view: bool, geosync: bool, fly: bool, auto_spin: bool) -> void:
	if _planet_btn == null:
		return
	_planet_btn.set_pressed_no_signal(not solar_view)
	_solar_btn.set_pressed_no_signal(solar_view)
	_orbit_btn.set_pressed_no_signal(not geosync and not fly)
	_geo_btn.set_pressed_no_signal(geosync)
	_fly_btn.set_pressed_no_signal(fly)
	_spin_btn.set_pressed_no_signal(auto_spin)
