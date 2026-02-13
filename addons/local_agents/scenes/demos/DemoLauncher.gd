extends Control

const DEMO_SCENES := [
	{"id": "ages_world", "label": "Ages World (Main Sim)", "path": "res://addons/local_agents/scenes/simulation/AgesWorld.tscn"},
	{"id": "worldgen_voxel", "label": "Voxel Worldgen Demo", "path": "res://addons/local_agents/scenes/demos/VoxelWorldDemo.tscn"},
	{"id": "world_simulation", "label": "World Simulation (Legacy)", "path": "res://addons/local_agents/scenes/simulation/WorldSimulation.tscn"},
	{"id": "plant_rabbit", "label": "Plant/Rabbit Field", "path": "res://addons/local_agents/scenes/simulation/PlantRabbitField.tscn"},
	{"id": "agent_3d", "label": "Agent 3D Demo", "path": "res://addons/local_agents/examples/Agent3DExample.tscn"},
	{"id": "chat", "label": "Chat Demo", "path": "res://addons/local_agents/examples/ChatExample.tscn"},
]

@onready var _list: VBoxContainer = %DemoList
@onready var _status: Label = %StatusLabel

func _ready() -> void:
	_build_list()
	_status.text = "Select a demo scene."

func _build_list() -> void:
	for child in _list.get_children():
		child.queue_free()
	for row in DEMO_SCENES:
		var button := Button.new()
		button.text = String(row.get("label", "Demo"))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(func(): _open_scene(String(row.get("path", ""))))
		_list.add_child(button)

func _open_scene(path: String) -> void:
	if path.strip_edges() == "":
		_status.text = "Invalid demo path"
		return
	if not ResourceLoader.exists(path):
		_status.text = "Scene not found: %s" % path
		return
	var err = get_tree().change_scene_to_file(path)
	if err != OK:
		_status.text = "Failed to open scene (%d): %s" % [err, path]
