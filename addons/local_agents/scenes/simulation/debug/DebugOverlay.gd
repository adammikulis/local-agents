extends Node3D

@export var show_paths: bool = true
@export var show_resources: bool = true
@export var show_conflicts: bool = true
@export var show_smell: bool = true

@onready var path_root: Node3D = $PathDebug
@onready var resource_root: Node3D = $ResourceDebug
@onready var conflict_root: Node3D = $ConflictDebug
@onready var smell_root: Node3D = $SmellDebug

func set_visibility_flags(paths: bool, resources: bool, conflicts: bool, smell: bool = true) -> void:
	show_paths = paths
	show_resources = resources
	show_conflicts = conflicts
	show_smell = smell
	path_root.visible = show_paths
	resource_root.visible = show_resources
	conflict_root.visible = show_conflicts
	smell_root.visible = show_smell
