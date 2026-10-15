class_name LAGameHud
extends CanvasLayer

# Capabilities worth a headline toast. Spawn unlocks are surfaced by the palette lighting up instead.
const NOTABLE_CAP_LABELS: Dictionary = {
	"view_geosync": "Geosync view",
	"view_solar": "Solar-system view",
}

# HudTheme.tres type variations.
const STYLE_TITLE: StringName = &"HeadingLabel"
const STYLE_TITLE_DONE: StringName = &"GoldLabel"
const STYLE_TOAST_OBJECTIVE: StringName = &"ToastObjective"
const STYLE_TOAST_UNLOCK: StringName = &"ToastUnlock"
const STYLE_TOAST_TEXT: StringName = &"ToastText"

@onready var _objective_panel: PanelContainer = $GameHudRoot/Objective
@onready var _sandbox_tag: PanelContainer = $GameHudRoot/SandboxTag
@onready var _objective_title: Label = $GameHudRoot/Objective/Margin/Col/Title
@onready var _stage_label: Label = $GameHudRoot/Objective/Margin/Col/Header/Stage
@onready var _progress_bar: ProgressBar = $GameHudRoot/Objective/Margin/Col/BarRow/Bar
@onready var _progress_value: Label = $GameHudRoot/Objective/Margin/Col/BarRow/Value
@onready var _summary_pop: Label = $GameHudRoot/Summary/Margin/Col/PopulationRow/Value
@onready var _summary_biomass: Label = $GameHudRoot/Summary/Margin/Col/BiomassRow/Value
@onready var _summary_gen: Label = $GameHudRoot/Summary/Margin/Col/BloodlineRow/Value
@onready var _toast_column: VBoxContainer = $GameHudRoot/Toasts
@onready var _refresh_timer: Timer = $RefreshTimer
@onready var _summary_col: VBoxContainer = $GameHudRoot/Summary/Margin/Col

var _rung_readout: LAProcessRungReadout = null
var _test_mass_readout: LATestMassReadout = null

var _progression: LAGameProgression = null
var _connected: bool = false
var _last_objective_title: String = ""


func _ready() -> void:
	_refresh_timer.timeout.connect(_refresh)
	# A world with no life has no population, no biomass and no bloodline; the rows go with them.
	if not LAWorldOffers.has_life():
		for row in ["PopulationRow", "BiomassRow", "BloodlineRow"]:
			var n: Node = _summary_col.get_node_or_null(NodePath(row))
			if n is CanvasItem:
				(n as CanvasItem).visible = false
	_connect_progression()
	_refresh()
	print("GAME_HUD={ready:true, progression:%s}" % str(_progression != null))


## The probe readout, built only for a world that solves a gravity field for one to fall through.
func set_test_masses(probes: Node, drop: Callable) -> void:
	if probes == null or not probes.has_method("active") or not probes.active():
		return
	_test_mass_readout = LATestMassReadout.new()
	_test_mass_readout.setup(probes)
	_test_mass_readout.drop_requested.connect(drop)
	_summary_col.add_child(_test_mass_readout)


## Show/hide the whole gamified overlay; the H hotkey flips both HUDs through this name.
func toggle_visible() -> void:
	visible = not visible


# ---------------------------------------------------------------------------
# Progression wiring
# ---------------------------------------------------------------------------

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
	if not NOTABLE_CAP_LABELS.has(id):
		return
	_spawn_toast("Unlocked: %s!" % String(NOTABLE_CAP_LABELS[id]), STYLE_TOAST_UNLOCK)
	_chime()


func _on_objective_completed(_id: String) -> void:
	var title: String = _last_objective_title
	if title.is_empty():
		_spawn_toast("Objective complete!", STYLE_TOAST_OBJECTIVE)
	else:
		_spawn_toast("Objective complete: %s" % title, STYLE_TOAST_OBJECTIVE)
	_chime()
	_refresh()


func _chime() -> void:
	# Static resolver finds the live audio director by group; a no-op when audio is unavailable.
	LAVoxelAudioController.chime(get_tree())


# ---------------------------------------------------------------------------
# Live refresh (scene RefreshTimer)
# ---------------------------------------------------------------------------

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
		_objective_title.text = "All objectives complete: survey the heavens"
		_objective_title.theme_type_variation = STYLE_TITLE_DONE
		_stage_label.text = "Stage %d / %d" % [total, total]
		_progress_bar.visible = false
		_progress_value.visible = false
		_last_objective_title = ""
		return

	_last_objective_title = String(p.get("title", ""))
	_objective_title.text = _last_objective_title
	_objective_title.theme_type_variation = STYLE_TITLE
	_stage_label.text = "Stage %d / %d" % [int(p.get("stage", 1)), total]
	_progress_bar.visible = true
	_progress_value.visible = true
	_progress_bar.value = float(p.get("ratio", 0.0))
	var value: float = float(p.get("value", 0.0))
	var threshold: float = float(p.get("threshold", 0.0))
	_progress_value.text = "%s / %s" % [_fmt_num(value), _fmt_num(threshold)]


func _refresh_summary() -> void:
	if _rung_readout == null:
		_rung_readout = LAProcessRungReadout.new()
		_summary_col.add_child(_rung_readout)
	_rung_readout.refresh()
	if _test_mass_readout != null:
		_test_mass_readout.refresh()
	var snap: Dictionary = LASimReport.snapshot(true)
	var creatures: int = int(snap.get("creatures", 0))
	var top_gen: int = int(snap.get("max_generation", 0))
	_summary_pop.text = "%d" % creatures
	_summary_biomass.text = _fmt_num(float(snap["biomass_total"])) if snap.has("biomass_total") else "—"
	# generation index is 0-based (founders = gen 0); show it as a human "Gen N" count.
	_summary_gen.text = "Gen %d" % (top_gen + 1)


## A transient notification: fades + slides in, holds, fades out, then frees itself.
func _spawn_toast(text: String, style: StringName) -> void:
	if _toast_column == null:
		return
	var panel: PanelContainer = PanelContainer.new()
	panel.theme_type_variation = style
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.modulate = Color(1, 1, 1, 0)

	var margin: MarginContainer = _make_margin(16, 10)
	panel.add_child(margin)
	var label: Label = Label.new()
	label.text = text
	label.theme_type_variation = STYLE_TOAST_TEXT
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	margin.add_child(label)

	_toast_column.add_child(panel)
	print("GAME_HUD_TOAST={text:\"%s\"}" % text)

	panel.position = Vector2(0, -8)
	var tw: Tween = create_tween()
	tw.set_parallel(true)
	tw.tween_property(panel, "modulate:a", 1.0, 0.30)
	tw.tween_property(panel, "position:y", 0.0, 0.30).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.chain().tween_interval(2.4)
	tw.chain().tween_property(panel, "modulate:a", 0.0, 0.6)
	tw.chain().tween_callback(panel.queue_free)


## Compact number formatting for summary/progress figures (1240 -> "1.2k").
func _fmt_num(v: float) -> String:
	var a: float = absf(v)
	if a >= 1000000.0:
		return "%.1fM" % (v / 1000000.0)
	if a >= 1000.0:
		return "%.1fk" % (v / 1000.0)
	return "%d" % int(round(v))


func _make_margin(h: int, v: int) -> MarginContainer:
	var m: MarginContainer = MarginContainer.new()
	m.add_theme_constant_override("margin_left", h)
	m.add_theme_constant_override("margin_right", h)
	m.add_theme_constant_override("margin_top", v)
	m.add_theme_constant_override("margin_bottom", v)
	return m
