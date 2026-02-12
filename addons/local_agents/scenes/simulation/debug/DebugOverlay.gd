extends Node3D

@export var show_paths: bool = true
@export var show_resources: bool = true
@export var show_conflicts: bool = true
@export var show_smell: bool = true
@export var show_wind: bool = true
@export var show_temperature: bool = true

@onready var path_root: Node3D = get_node_or_null("PathDebug")
@onready var resource_root: Node3D = get_node_or_null("ResourceDebug")
@onready var conflict_root: Node3D = get_node_or_null("ConflictDebug")
@onready var smell_root: Node3D = get_node_or_null("SmellDebug")
@onready var wind_root: Node3D = get_node_or_null("WindDebug")
@onready var temperature_root: Node3D = get_node_or_null("TemperatureDebug")

func set_visibility_flags(paths: bool, resources: bool, conflicts: bool, smell: bool = true, wind: bool = true, temperature: bool = true) -> void:
	show_paths = paths
	show_resources = resources
	show_conflicts = conflicts
	show_smell = smell
	show_wind = wind
	show_temperature = temperature
	if path_root != null:
		path_root.visible = show_paths
	if resource_root != null:
		resource_root.visible = show_resources
	if conflict_root != null:
		conflict_root.visible = show_conflicts
	if smell_root != null:
		smell_root.visible = show_smell
	if wind_root != null:
		wind_root.visible = show_wind
	if temperature_root != null:
		temperature_root.visible = show_temperature
