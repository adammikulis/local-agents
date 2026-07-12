extends Node3D

## Library demo — a whole cubed-sphere PLANET with a living ecology from a single LASimWorld node, with NO
## game shell (no HUD, menus, disasters, save system or streamer). This is the "standalone planet" story:
## LASimWorld composes the planet body, the MaterialField, the ecology and the spawn, and this scene just
## frames it with a camera. LASimWorld owns its own `--run-frames=N` headless harness (prints SIM_WORLD_REPORT
## then quits). (Explicit types only — project rule: no ':=' inferred typing.)

const SimWorldScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/SimWorld.gd")

@export var radius: float = 180.0
@export_range(8, 64, 1) var grid_res: int = 16

var _sim = null


func _ready() -> void:
	_sim = SimWorldScript.new()
	_sim.name = "SimWorld"
	_sim.world_type = LASimWorld.WorldType.SPHERE
	_sim.radius = radius
	_sim.grid_res = grid_res
	add_child(_sim)
	_build_camera()


func _build_camera() -> void:
	var cam: Camera3D = Camera3D.new()
	cam.position = Vector3(0.0, 0.0, radius * 2.6)
	cam.far = maxf(4000.0, radius * 12.0)
	cam.current = true
	add_child(cam)
	var light: DirectionalLight3D = DirectionalLight3D.new()
	light.rotation = Vector3(-0.6, 0.5, 0.0)
	add_child(light)
