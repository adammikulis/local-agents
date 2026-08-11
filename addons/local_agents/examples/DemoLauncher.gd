extends Control
class_name LADemoLauncher

## The friendly front door: every demo, simplest first, each with an Open button.
##
## The list is not in this file. It is scanned from `examples/demos/*.tres`, one LocalAgentDemoEntry
## per demo, following the `creatures/species/*.json` precedent. Drop a resource in the directory and
## a row appears, so adding a demo needs no GDScript edit. Each entry holds a `res://` path
## rather than a PackedScene, so painting the menu costs one file check per row instead of loading
## every demo scene. A renamed scene is caught by scripts/check_demo_catalog.sh, which fails the
## build rather than leaving a button labelled "Missing".
##
## Rows are still built in code, deliberately: their number and their enabled or disabled state
## depend on what is installed on this machine, which a .tscn cannot express. The scene owns the
## shell (title, subtitle, status label, scroll, %ListBox) and this script owns only the dynamic
## part.
##
## (Explicit types only. The project rule bans ':=' inferred typing.)

const Status: GDScript = preload("res://addons/local_agents/runtime/AgentStatus.gd")

## Every .tres directly in here is a catalogue entry. scripts/check_demo_catalog.sh keeps it honest.
const CATALOG_DIR: String = "res://addons/local_agents/examples/demos"

## Pass this after `--` to print the catalogue as JSON and quit, instead of sitting there as a UI:
##   godot --headless addons/local_agents/examples/DemoLauncher.tscn -- --catalog-report
## A launcher cannot be clicked headless, so this is how a run proves the rows really were built and
## which ones this machine can actually open. scripts/check_demo_catalog.sh answers the static half
## of the same question (is the catalogue well-formed) by reading the .tres files as text.
const REPORT_FLAG: String = "--catalog-report"

@export_group("Row colours")
## Description text under each title.
@export_color_no_alpha var description_color: Color = Color(0.72, 0.74, 0.78)
## The "why is this greyed out" line on a row that cannot run here.
@export_color_no_alpha var blocked_color: Color = Color(0.95, 0.72, 0.4)

@onready var list_box: VBoxContainer = %ListBox


func _ready() -> void:
	# One check() for the whole list. It re-probes the filesystem, the ClassDB and the extension
	# loader on every call (see AgentStatus.check), so per-row calls would pay for that N times.
	var state: Dictionary = Status.check()
	var entries: Array[LocalAgentDemoEntry] = load_catalog()
	var position: int = 0
	for entry in entries:
		position += 1
		_add_row(position, entry, state)
	if OS.get_cmdline_user_args().has(REPORT_FLAG):
		_print_report(entries, state)


## Every entry in CATALOG_DIR, sorted by `order`. Static so a test or an editor tool can ask for the
## catalogue without instancing the launcher scene.
static func load_catalog() -> Array[LocalAgentDemoEntry]:
	var entries: Array[LocalAgentDemoEntry] = []
	var dir: DirAccess = DirAccess.open(CATALOG_DIR)
	if dir == null:
		push_warning("Demo catalogue directory missing: %s" % CATALOG_DIR)
		return entries
	for file_name in dir.get_files():
		# An exported build renames converted resources to "<name>.tres.remap"; load() still wants
		# the original name. Stripping the suffix is what makes the scan work outside the editor.
		var entry_name: String = String(file_name).trim_suffix(".remap")
		if not entry_name.ends_with(".tres"):
			continue
		var path: String = "%s/%s" % [CATALOG_DIR, entry_name]
		var resource: Resource = ResourceLoader.load(path)
		if resource == null:
			# With `scene_path` a plain String, the entry file itself has to be broken to land here:
			# a corrupt .tres, or one whose script reference is gone. A moved or renamed demo scene
			# is caught by scripts/check_demo_catalog.sh instead.
			push_warning("Demo entry failed to load: %s" % path)
			continue
		if not (resource is LocalAgentDemoEntry):
			push_warning("Not a LocalAgentDemoEntry, ignoring: %s" % path)
			continue
		entries.append(resource as LocalAgentDemoEntry)
	entries.sort_custom(_by_order)
	return entries


static func _by_order(a: LocalAgentDemoEntry, b: LocalAgentDemoEntry) -> bool:
	return a.order < b.order


## "" when this demo can run here. Otherwise it is the one sentence that says why it cannot, and what
## to do about it. `state` is a LocalAgentStatus.check() result.
static func gate_reason(entry: LocalAgentDemoEntry, state: Dictionary) -> String:
	if entry.scene_path.strip_edges() == "":
		return "This catalogue entry has no scene assigned."
	if not ResourceLoader.exists(entry.scene_path):
		return "Its scene is missing: %s" % entry.scene_path
	if entry.requires_voxel_backend and not bool(state["voxel_backend_ok"]):
		return "Needs the godot_voxel GDExtension (addons/zylann.voxel/), which is not installed."
	if entry.requires_model:
		var blockers: PackedStringArray = state["blockers"]
		if blockers.is_empty():
			return ""
		# BLOCK_MODEL_NOT_LOADED is not a reason to stop anyone opening a demo. The weights are on
		# disk and the demo loads them itself. It is also only ever the last blocker: check() appends
		# it in the `elif` arm of the model test, after the extension and autoload checks, so any
		# genuinely hard blocker is blockers[0] and `next_step` is already the right sentence for it.
		if blockers[0] == Status.BLOCK_MODEL_NOT_LOADED:
			return ""
		return String(state["next_step"])
	return ""


func _add_row(position: int, entry: LocalAgentDemoEntry, state: Dictionary) -> void:
	var reason: String = gate_reason(entry, state)
	var runnable: bool = reason == ""

	var panel: PanelContainer = PanelContainer.new()
	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	margin.add_child(row)

	var text_box: VBoxContainer = VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.add_theme_constant_override("separation", 4)

	# The number comes from the sort position, never from the title, so inserting a rung renumbers
	# the whole ladder for free instead of leaving hand-typed "3." labels lying about their place.
	var title: Label = Label.new()
	title.text = "%d. %s" % [position, entry.title]
	text_box.add_child(title)

	if entry.description != "":
		var description: Label = Label.new()
		description.text = entry.description
		description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		description.add_theme_color_override("font_color", description_color)
		text_box.add_child(description)

	if not runnable:
		var blocked: Label = Label.new()
		blocked.text = reason
		blocked.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		blocked.add_theme_color_override("font_color", blocked_color)
		text_box.add_child(blocked)

	row.add_child(text_box)

	var open_button: Button = Button.new()
	open_button.text = "Open" if runnable else "Unavailable"
	open_button.disabled = not runnable
	open_button.tooltip_text = reason
	open_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	open_button.custom_minimum_size = Vector2(120.0, 0.0)
	if runnable:
		open_button.pressed.connect(_open.bind(entry.scene_path))
	row.add_child(open_button)

	list_box.add_child(panel)


# Loaded HERE, on click, not when the menu opens. Holding PackedScene references in the catalogue
# made painting a twelve-row list load twelve demo scenes and every script they touch.
func _open(scene_path: String) -> void:
	var packed: PackedScene = load(scene_path) as PackedScene
	if packed == null:
		push_error("Demo scene could not be loaded: %s" % scene_path)
		return
	get_tree().change_scene_to_packed(packed)


func _print_report(entries: Array[LocalAgentDemoEntry], state: Dictionary) -> void:
	var rows: Array = []
	for entry in entries:
		var reason: String = gate_reason(entry, state)
		rows.append({
			"order": entry.order,
			"title": entry.title,
			"scene": entry.scene_path,
			"requires_model": entry.requires_model,
			"requires_voxel_backend": entry.requires_voxel_backend,
			"open": reason == "",
			"reason": reason,
		})
	print("DEMO_CATALOG=%s" % JSON.stringify({
		"entries": rows.size(),
		"model_path": String(state["model_path"]),
		"voxel_backend_ok": bool(state["voxel_backend_ok"]),
		"blockers": state["blockers"],
		"demos": rows,
	}))
	get_tree().quit()
