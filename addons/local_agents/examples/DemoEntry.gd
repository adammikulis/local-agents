@tool
extends Resource
class_name LocalAgentDemoEntry


@export_range(0, 999, 1) var order: int = 0

@export var title: String = ""

## One or two sentences: what this demo shows that the rung above it did not.
@export_multiline var description: String = ""

@export_file("*.tscn") var scene_path: String = ""

@export var requires_model: bool = false

@export var requires_voxel_backend: bool = false
