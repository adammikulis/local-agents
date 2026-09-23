extends Control
class_name LADemoLauncher


const Status: GDScript = preload("res://addons/local_agents/runtime/AgentStatus.gd")

## Every .tres directly in here is a catalogue entry. scripts/check_demo_catalog.sh keeps it honest.
const CATALOG_DIR: String = "res://addons/local_agents/examples/demos"

const REPORT_FLAG: String = "--catalog-report"

@export_group("Rows")
## Instanced once per catalogue entry, in `order`.
@export var row_scene: PackedScene

@onready var list_box: VBoxContainer = %ListBox


func _ready() -> void:
	# One check() for the whole list. It re-probes the filesystem, the ClassDB and the extension
	# loader on every call (see AgentStatus.check), so per-row calls would pay for that N times.
	var state: Dictionary = Status.check()
	var number: int = 0
	for entry in load_catalog():
		number += 1
		_add_row(number, entry, state)
	if OS.get_cmdline_user_args().has(REPORT_FLAG):
		_print_report(state)


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
		if blockers[0] == Status.BLOCK_MODEL_NOT_LOADED:
			return ""
		return String(state["next_step"])
	return ""


func _add_row(number: int, entry: LocalAgentDemoEntry, state: Dictionary) -> void:
	var row: LADemoRow = row_scene.instantiate() as LADemoRow
	row.entry = entry
	row.number = number
	row.blocked_reason = gate_reason(entry, state)
	row.launched.connect(_open)
	list_box.add_child(row)


# Loaded HERE, on click, not when the menu opens. Holding PackedScene references in the catalogue
# made painting a twelve-row list load twelve demo scenes and every script they touch.
func _open(entry: LocalAgentDemoEntry) -> void:
	var packed: PackedScene = load(entry.scene_path) as PackedScene
	if packed == null:
		push_error("Demo scene could not be loaded: %s" % entry.scene_path)
		return
	get_tree().change_scene_to_packed(packed)


## The rows this launcher drew, read back off the list.
func _print_report(state: Dictionary) -> void:
	var rows: Array = []
	for row: LADemoRow in list_box.get_children():
		rows.append({
			"order": row.entry.order,
			"title": row.entry.title,
			"scene": row.entry.scene_path,
			"requires_model": row.entry.requires_model,
			"requires_voxel_backend": row.entry.requires_voxel_backend,
			"open": row.blocked_reason == "",
			"reason": row.blocked_reason,
		})
	print("DEMO_CATALOG=%s" % JSON.stringify({
		"entries": rows.size(),
		"model_path": String(state["model_path"]),
		"voxel_backend_ok": bool(state["voxel_backend_ok"]),
		"blockers": state["blockers"],
		"demos": rows,
	}))
	get_tree().quit()
