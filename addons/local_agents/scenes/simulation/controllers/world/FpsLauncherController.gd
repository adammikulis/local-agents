extends Node
class_name FpsLauncherController

const DEFAULT_PROJECTILE_SCENE = preload("res://addons/local_agents/scenes/simulation/actors/FpsLauncherProjectile.tscn")

@export var projectile_scene: PackedScene = DEFAULT_PROJECTILE_SCENE
@export_range(1.0, 300.0, 0.5) var launch_speed: float = 60.0
@export_range(0.1, 20.0, 0.1) var projectile_ttl_seconds: float = 4.0
@export_range(0.1, 5.0, 0.1) var spawn_distance: float = 0.8
@export_range(0.01, 2.0, 0.01) var cooldown_seconds: float = 0.15
@export_range(1, 256, 1) var max_active_projectiles: int = 24

var _camera: Camera3D = null
var _spawn_parent: Node3D = null
var _cooldown_remaining: float = 0.0
var _active_projectiles: Array[RigidBody3D] = []

func configure(active_camera: Camera3D, spawn_parent: Node3D) -> void:
	_camera = active_camera
	_spawn_parent = spawn_parent

func step(delta: float) -> void:
	_cooldown_remaining = maxf(0.0, _cooldown_remaining - delta)
	_prune_inactive()

func try_fire_from_screen_center() -> bool:
	if _camera == null or not is_instance_valid(_camera):
		return false
	if _spawn_parent == null or not is_instance_valid(_spawn_parent):
		return false
	if _cooldown_remaining > 0.0:
		return false
	_prune_inactive()
	if _active_projectiles.size() >= maxi(1, max_active_projectiles):
		return false
	if projectile_scene == null:
		return false
	var projectile_node := projectile_scene.instantiate()
	if not (projectile_node is RigidBody3D):
		return false
	var projectile := projectile_node as RigidBody3D
	var viewport := _camera.get_viewport()
	if viewport == null:
		return false
	var center := viewport.get_visible_rect().size * 0.5
	var ray_origin := _camera.project_ray_origin(center)
	var ray_direction := _camera.project_ray_normal(center).normalized()
	projectile.global_position = ray_origin + ray_direction * spawn_distance
	projectile.linear_velocity = ray_direction * launch_speed
	projectile.continuous_cd = true
	if projectile.has_method("set_ttl_seconds"):
		projectile.call("set_ttl_seconds", projectile_ttl_seconds)
	_spawn_parent.add_child(projectile)
	_active_projectiles.append(projectile)
	projectile.tree_exited.connect(_on_projectile_tree_exited.bind(projectile), CONNECT_ONE_SHOT)
	_cooldown_remaining = cooldown_seconds
	return true

func _prune_inactive() -> void:
	for i in range(_active_projectiles.size() - 1, -1, -1):
		var projectile := _active_projectiles[i]
		if projectile == null or not is_instance_valid(projectile):
			_active_projectiles.remove_at(i)

func _on_projectile_tree_exited(projectile: RigidBody3D) -> void:
	_active_projectiles.erase(projectile)
