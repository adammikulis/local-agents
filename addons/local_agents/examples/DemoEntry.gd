@tool
extends Resource
class_name LocalAgentDemoEntry


@export_range(0, 999, 1) var order: int = 0

## Row heading, e.g. "Two agents converse". Do not number it. The launcher prefixes the position
## itself, so a hand-typed "3." would go stale the moment a rung is inserted above it.
@export var title: String = ""

## One or two sentences: what this demo shows that the rung above it did not.
@export_multiline var description: String = ""

## The scene the Open button runs. A path, loaded on click rather than when the menu opens, and the
## note above says why. check_demo_catalog.sh fails the build if it does not resolve.
@export_file("*.tscn") var scene_path: String = ""

@export var requires_model: bool = false

## Set when the demo needs the godot_voxel GDExtension (addons/zylann.voxel/). In practice that means
## any demo that builds a cubed-sphere planet. The launcher greys the row out when `ClassDB` has no
## VoxelLodTerrain.
@export var requires_voxel_backend: bool = false
