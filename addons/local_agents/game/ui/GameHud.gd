class_name LAGameHud
extends CanvasLayer

## LAGameHud — the gamified overlay that turns the sim's own systems into a light game layer. It READS
## everything and drives nothing:
##   • the current OBJECTIVE + a progress bar toward its threshold + the stage ("Stage 2 / 4"), from the
##     campaign progression system (LAGameProgression.current_progress());
##   • transient UNLOCK TOASTS with a milestone chime, off the progression's capability_unlocked /
##     objective_completed signals (audio via the static LAVoxelAudioController.chime resolver);
##   • a light "how's my planet doing" SUMMARY corner — a few live figures pulled from the ONE telemetry
##     source (LASimReport.snapshot(): population, biomass, top generation).
##
## SANDBOX (gating off): the objective/stage panel is hidden and a subtle "Sandbox" tag stands in — the
## summary stays. All panels ignore the mouse (display-only), so it never steals world clicks or covers the
## spawn palette's interactivity.
##
## Cheap by construction: it updates on the two progression signals plus a slow 0.5 s timer (a couple of
## telemetry reads a second), never per frame. Wired into VoxelWorld with one add_child line. A `toggle()` /
## `set_hud_visible()` API is exposed for a later hotkey binding. (Explicit types only — no ':=' inferred typing.)

## How often the objective progress + summary figures refresh (seconds). Matches the progression evaluator's
## own cadence — a handful of cheap telemetry reads per second, never per frame.
const REFRESH_INTERVAL: float = 0.5

# Cohesive dark theme, matched to the spawn-palette HUD so the two read as one interface.
const COL_BG: Color = Color(0.086, 0.098, 0.129, 0.94)
const COL_BG_2: Color = Color(0.129, 0.145, 0.184, 0.96)
const COL_BORDER: Color = Color(0.24, 0.27, 0.33, 1.0)
const COL_ACCENT: Color = Color(0.33, 0.70, 0.98, 1.0)
const COL_GOLD: Color = Color(1.0, 0.82, 0.36, 1.0)          # reward / milestone highlight
const COL_TEXT: Color = Color(0.90, 0.92, 0.95, 1.0)
const COL_TEXT_DIM: Color = Color(0.62, 0.66, 0.72, 1.0)
const COL_TEXT_HEADING: Color = Color(0.98, 0.99, 1.0, 1.0)

# Friendly labels for the capabilities worth a headline toast (the view unlocks — the spawn unlocks are
# already surfaced by the palette lighting up, so they don't each need a toast). Config over a branch.
const NOTABLE_CAP_LABELS: Dictionary = {
	"view_geosync": "Geosync view",
	"view_solar": "Solar-system view",
}

var _progression: LAGameProgression = null
var _connected: bool = false

var _objective_panel: PanelContainer
var _sandbox_tag: PanelContainer
var _objective_title: Label
var _stage_label: Label
var _progress_bar: ProgressBar
var _progress_value: Label

var _summary_pop: Label
var _summary_biomass: Label
var _summary_gen: Label

var _toast_column: VBoxContainer


func _ready() -> void:
	layer = 96                     # just under the spawn palette (100) so its buttons stay on top
	var root: Control = Control.new()
	root.name = "GameHudRoot"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_build_objective_panel(root)
	_build_sandbox_tag(root)
	_build_summary(root)
	_build_toast_column(root)

	_connect_progression()
	_refresh()

	var timer: Timer = Timer.new()
	timer.wait_time = REFRESH_INTERVAL
	timer.autostart = true
	timer.timeout.connect(_refresh)
	add_child(timer)
	print("GAME_HUD={ready:true, progression:%s}" % str(_progression != null))


# ---------------------------------------------------------------------------
# Public API (a later hotkey binding drives these — VoxelInputController owns the key)
# ---------------------------------------------------------------------------

## Show/hide the whole gamified overlay.
func set_hud_visible(on: bool) -> void:
	visible = on


## Flip overlay visibility (bind to a hotkey).
func toggle() -> void:
	visible = not visible


## Alias of toggle() — matches the toggle_visible() shape the spawn-palette HUD exposes so the H-key
## handler can flip both HUDs through one call name.
func toggle_visible() -> void:
	toggle()


# ---------------------------------------------------------------------------
# Progression wiring
# ---------------------------------------------------------------------------

## Resolve the live progression singleton and subscribe to its unlock signals (idempotent — retried from the
## timer tick if the singleton was not up yet at _ready).
func _connect_progression() -> void:
	if _connected:
		return
	_progression = LAGameProgression.active()
	if _progression == null:
		return
	_progression.capability_unlocked.connect(_on_capability_unlocked)
	_progression.objective_completed.connect(_on_objective_completed)
	_connected = true


func _on_capability_unlocked(id: String) -> void:
	# Headline toast only for the notable (view) unlocks; spawn unlocks are surfaced by the palette itself.
	if not NOTABLE_CAP_LABELS.has(id):
		return
	_spawn_toast("Unlocked: %s!" % String(NOTABLE_CAP_LABELS[id]), COL_GOLD)
	_chime()


func _on_objective_completed(_id: String) -> void:
	var title: String = String(_last_objective_title)
	if title.is_empty():
		_spawn_toast("Objective complete!", COL_ACCENT)
	else:
		_spawn_toast("Objective complete: %s" % title, COL_ACCENT)
	_chime()
	_refresh()


func _chime() -> void:
	# Static resolver finds the live audio director by group — no controller reference needed. Safe no-op
	# when audio is unavailable (headless / muted bus).
	LAVoxelAudioController.chime(get_tree())


# ---------------------------------------------------------------------------
# Live refresh (slow timer)
# ---------------------------------------------------------------------------

var _last_objective_title: String = ""

func _refresh() -> void:
	_connect_progression()
	_refresh_objective()
	_refresh_summary()


func _refresh_objective() -> void:
	if _progression == null:
		_objective_panel.visible = false
		_sandbox_tag.visible = false
		return
	var p: Dictionary = _progression.current_progress()
	if bool(p.get("sandbox", false)):
		_objective_panel.visible = false
		_sandbox_tag.visible = true
		return
	_sandbox_tag.visible = false
	_objective_panel.visible = true

	var total: int = int(p.get("stages_total", 0))
	if bool(p.get("done", false)):
		_objective_title.text = "All objectives complete — survey the heavens"
		_objective_title.add_theme_color_override("font_color", COL_GOLD)
		_stage_label.text = "Stage %d / %d" % [total, total]
		_progress_bar.visible = false
		_progress_value.visible = false
		_last_objective_title = ""
		return

	_last_objective_title = String(p.get("title", ""))
	_objective_title.text = _last_objective_title
	_objective_title.add_theme_color_override("font_color", COL_TEXT_HEADING)
	_stage_label.text = "Stage %d / %d" % [int(p.get("stage", 1)), total]
	_progress_bar.visible = true
	_progress_value.visible = true
	_progress_bar.value = float(p.get("ratio", 0.0))
	var value: float = float(p.get("value", 0.0))
	var threshold: float = float(p.get("threshold", 0.0))
	_progress_value.text = "%s / %s" % [_fmt_num(value), _fmt_num(threshold)]


func _refresh_summary() -> void:
	var snap: Dictionary = LASimReport.snapshot()
	var creatures: int = int(snap.get("creatures", 0))
	var biomass: float = float(snap.get("biomass_total", 0.0))
	var top_gen: int = int(snap.get("max_generation", 0))
	_summary_pop.text = "%d" % creatures
	_summary_biomass.text = _fmt_num(biomass)
	# generation index is 0-based (founders = gen 0); show it as a human "Gen N" count.
	_summary_gen.text = "Gen %d" % (top_gen + 1)


# ---------------------------------------------------------------------------
# Toasts
# ---------------------------------------------------------------------------

## A juicy-but-tasteful transient notification: fades + slides in, holds, fades out, then frees itself.
func _spawn_toast(text: String, accent: Color) -> void:
	if _toast_column == null:
		return
	var panel: PanelContainer = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _toast_stylebox(accent))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.modulate = Color(1, 1, 1, 0)

	var margin: MarginContainer = _make_margin(16, 10)
	panel.add_child(margin)
	var label: Label = Label.new()
	label.text = text
	label.add_theme_color_override("font_color", COL_TEXT_HEADING)
	label.add_theme_font_size_override("font_size", 17)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	margin.add_child(label)

	_toast_column.add_child(panel)
	print("GAME_HUD_TOAST={text:\"%s\"}" % text)

	# Fade + drop in, hold, fade out — then remove. Position offset gives a gentle slide.
	panel.position = Vector2(0, -8)
	var tw: Tween = create_tween()
	tw.set_parallel(true)
	tw.tween_property(panel, "modulate:a", 1.0, 0.30)
	tw.tween_property(panel, "position:y", 0.0, 0.30).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.chain().tween_interval(2.4)
	tw.chain().tween_property(panel, "modulate:a", 0.0, 0.6)
	tw.chain().tween_callback(panel.queue_free)


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build_objective_panel(root: Control) -> void:
	_objective_panel = PanelContainer.new()
	_objective_panel.name = "Objective"
	_objective_panel.add_theme_stylebox_override("panel", _panel_stylebox(COL_BG))
	_objective_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_objective_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_objective_panel.offset_top = 104.0     # clear of the top-center view-controls bar (occupies y 44..96)
	_objective_panel.custom_minimum_size = Vector2(300.0, 0.0)
	_objective_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_objective_panel)

	var margin: MarginContainer = _make_margin(18, 12)
	_objective_panel.add_child(margin)
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	margin.add_child(col)

	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	col.add_child(header)

	var caption: Label = Label.new()
	caption.text = "Objective"
	caption.add_theme_color_override("font_color", COL_ACCENT)
	caption.add_theme_font_size_override("font_size", 12)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(caption)

	_stage_label = Label.new()
	_stage_label.text = "Stage 1 / 4"
	_stage_label.add_theme_color_override("font_color", COL_TEXT_DIM)
	_stage_label.add_theme_font_size_override("font_size", 12)
	_stage_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(_stage_label)

	_objective_title = Label.new()
	_objective_title.text = "…"
	_objective_title.add_theme_color_override("font_color", COL_TEXT_HEADING)
	_objective_title.add_theme_font_size_override("font_size", 17)
	_objective_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_objective_title)

	var bar_row: HBoxContainer = HBoxContainer.new()
	bar_row.add_theme_constant_override("separation", 10)
	col.add_child(bar_row)

	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 1.0
	_progress_bar.value = 0.0
	_progress_bar.show_percentage = false
	_progress_bar.custom_minimum_size = Vector2(240.0, 10.0)
	_progress_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_progress_bar.add_theme_stylebox_override("background", _bar_stylebox(COL_BG_2, COL_BORDER))
	_progress_bar.add_theme_stylebox_override("fill", _bar_fill_stylebox(COL_ACCENT))
	bar_row.add_child(_progress_bar)

	_progress_value = Label.new()
	_progress_value.text = "0 / 0"
	_progress_value.add_theme_color_override("font_color", COL_TEXT_DIM)
	_progress_value.add_theme_font_size_override("font_size", 13)
	bar_row.add_child(_progress_value)


func _build_sandbox_tag(root: Control) -> void:
	_sandbox_tag = PanelContainer.new()
	_sandbox_tag.name = "SandboxTag"
	_sandbox_tag.add_theme_stylebox_override("panel", _panel_stylebox(Color(COL_BG.r, COL_BG.g, COL_BG.b, 0.72)))
	_sandbox_tag.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_sandbox_tag.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_sandbox_tag.offset_top = 104.0     # clear of the top-center view-controls bar
	_sandbox_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sandbox_tag.visible = false
	root.add_child(_sandbox_tag)

	var margin: MarginContainer = _make_margin(14, 6)
	_sandbox_tag.add_child(margin)
	var label: Label = Label.new()
	label.text = "Sandbox"
	label.add_theme_color_override("font_color", COL_TEXT_DIM)
	label.add_theme_font_size_override("font_size", 13)
	margin.add_child(label)


func _build_summary(root: Control) -> void:
	# Right side, below the inspector — the spawn palette owns the wide center-bottom and the left column is
	# taken by the audio toggle + debug panel, so the upper-right is the clear corner.
	var panel: PanelContainer = PanelContainer.new()
	panel.name = "Summary"
	panel.add_theme_stylebox_override("panel", _panel_stylebox(COL_BG))
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.offset_right = -12.0
	panel.offset_top = 168.0
	panel.custom_minimum_size = Vector2(180.0, 0.0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)

	var margin: MarginContainer = _make_margin(16, 12)
	panel.add_child(margin)
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	margin.add_child(col)

	var caption: Label = Label.new()
	caption.text = "Planet"
	caption.add_theme_color_override("font_color", COL_ACCENT)
	caption.add_theme_font_size_override("font_size", 12)
	col.add_child(caption)

	_summary_pop = _add_summary_row(col, "Population")
	_summary_biomass = _add_summary_row(col, "Biomass")
	_summary_gen = _add_summary_row(col, "Bloodline")


## One "label ….. value" row in the summary; returns the value Label so the timer can update it.
func _add_summary_row(col: VBoxContainer, name: String) -> Label:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	col.add_child(row)

	var key: Label = Label.new()
	key.text = name
	key.add_theme_color_override("font_color", COL_TEXT_DIM)
	key.add_theme_font_size_override("font_size", 14)
	key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(key)

	var value: Label = Label.new()
	value.text = "0"
	value.add_theme_color_override("font_color", COL_TEXT_HEADING)
	value.add_theme_font_size_override("font_size", 14)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value)
	return value


func _build_toast_column(root: Control) -> void:
	_toast_column = VBoxContainer.new()
	_toast_column.name = "Toasts"
	_toast_column.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_toast_column.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast_column.offset_top = 210.0     # stacked just below the objective panel
	_toast_column.alignment = BoxContainer.ALIGNMENT_CENTER
	_toast_column.add_theme_constant_override("separation", 8)
	_toast_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_toast_column)


# ---------------------------------------------------------------------------
# Style + format helpers
# ---------------------------------------------------------------------------

## Compact number formatting for summary/progress figures (1240 -> "1.2k").
func _fmt_num(v: float) -> String:
	var a: float = absf(v)
	if a >= 1000000.0:
		return "%.1fM" % (v / 1000000.0)
	if a >= 1000.0:
		return "%.1fk" % (v / 1000.0)
	return "%d" % int(round(v))


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


func _toast_stylebox(accent: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = COL_BG_2
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(2)
	sb.border_color = accent
	sb.set_content_margin_all(0)
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 10
	return sb


func _bar_stylebox(bg: Color, border: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(5)
	sb.set_border_width_all(1)
	sb.border_color = border
	return sb


func _bar_fill_stylebox(fill: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_corner_radius_all(5)
	return sb


func _make_margin(h: int, v: int) -> MarginContainer:
	var m: MarginContainer = MarginContainer.new()
	m.add_theme_constant_override("margin_left", h)
	m.add_theme_constant_override("margin_right", h)
	m.add_theme_constant_override("margin_top", v)
	m.add_theme_constant_override("margin_bottom", v)
	return m
