extends Control
class_name LocalAgentsDemoLauncher

## The friendly front door. Lists every demo from the simplest rung to the
## flagship voxel planet, each with a one-line description and an Open button
## that swaps to its scene. Build the row list once, from data, so adding a new
## demo is one entry here, not new UI wiring.

@onready var list_box: VBoxContainer = %ListBox

# Each demo: title, one-line description, and the scene to open. Ordered from the
# simplest capability to the fullest, so the list reads as a ladder.
const DEMOS: Array = [
	{
		"title": "1. Quickstart",
		"desc": "The smallest 'talk to a local LLM' scene: one Agent node, a prompt box, a reply.",
		"scene": "res://addons/local_agents/examples/AgentQuickstart.tscn",
	},
	{
		"title": "2. Agent drives actions",
		"desc": "The reply becomes game actions: the agent recolors and pulses an orb via enqueue_action.",
		"scene": "res://addons/local_agents/examples/AgentActionsDemo.tscn",
	},
	{
		"title": "3. Two agents converse",
		"desc": "Ada and Ben take turns; every line is recorded in a shared memory graph.",
		"scene": "res://addons/local_agents/examples/AgentConversationDemo.tscn",
	},
	{
		"title": "4. Chat",
		"desc": "A fuller chat UI with model/inference configuration, runtime health, and saved chats.",
		"scene": "res://addons/local_agents/examples/ChatExample.tscn",
	},
	{
		"title": "5. 3D agent",
		"desc": "A talking 3D agent prefab driven by the same runtime, with a setup checklist.",
		"scene": "res://addons/local_agents/examples/Agent3DExample.tscn",
	},
	{
		"title": "6. Graph memory",
		"desc": "The LocalAgentGraph resource (nodes/edges) for structured knowledge. Runs with no model.",
		"scene": "res://addons/local_agents/examples/GraphExample.tscn",
	},
	{
		"title": "Play the planet (flagship)",
		"desc": "The emergent voxel ecosystem: one material substrate, herds, disasters, and a local-LLM streamer.",
		"scene": "res://addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn",
	},
]

func _ready() -> void:
	for demo_variant in DEMOS:
		var demo: Dictionary = demo_variant
		_add_row(demo)

func _add_row(demo: Dictionary) -> void:
	var scene_path: String = String(demo.get("scene", ""))
	var exists: bool = ResourceLoader.exists(scene_path)

	var panel: PanelContainer = PanelContainer.new()
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)

	var text_box: VBoxContainer = VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title: Label = Label.new()
	title.text = String(demo.get("title", "Demo"))
	var desc: Label = Label.new()
	desc.text = String(demo.get("desc", ""))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_box.add_child(title)
	text_box.add_child(desc)
	row.add_child(text_box)

	var open_button: Button = Button.new()
	open_button.text = "Open" if exists else "Missing"
	open_button.disabled = not exists
	open_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	open_button.pressed.connect(_open_scene.bind(scene_path))
	row.add_child(open_button)

	list_box.add_child(panel)

func _open_scene(scene_path: String) -> void:
	if not ResourceLoader.exists(scene_path):
		push_warning("Demo scene not found: %s" % scene_path)
		return
	get_tree().change_scene_to_file(scene_path)
