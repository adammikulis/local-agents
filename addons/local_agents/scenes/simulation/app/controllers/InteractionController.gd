extends RefCounted
class_name LocalAgentsInteractionController

const FeatureQueryScript = preload("res://addons/local_agents/scenes/simulation/app/controllers/VoxelFeatureQuery.gd")
const CameraControllerScript = preload("res://addons/local_agents/scenes/simulation/app/controllers/VoxelDemoCameraController.gd")

var feature_query = FeatureQueryScript.new()
var camera_controller = CameraControllerScript.new()

func configure_camera(camera: Camera3D) -> void:
	camera_controller.configure(camera)

func process_camera(delta: float) -> void:
	camera_controller.process(delta)

func handle_camera_input(event: InputEvent) -> bool:
	return camera_controller.handle_input(event)

func tile_from_screen_position(camera: Camera3D, world_snapshot: Dictionary, screen_pos: Vector2) -> Vector2i:
	if camera == null or world_snapshot.is_empty():
		return Vector2i(-1, -1)
	var origin = camera.project_ray_origin(screen_pos)
	var direction = camera.project_ray_normal(screen_pos)
	if absf(direction.y) <= 0.00001:
		return Vector2i(-1, -1)
	var t = -origin.y / direction.y
	if t <= 0.0:
		return Vector2i(-1, -1)
	var hit = origin + direction * t
	var width = int(world_snapshot.get("width", 0))
	var height = int(world_snapshot.get("height", 0))
	var tx = clampi(int(floor(hit.x)), 0, maxi(0, width - 1))
	var tz = clampi(int(floor(hit.z)), 0, maxi(0, height - 1))
	if tx < 0 or tz < 0 or tx >= width or tz >= height:
		return Vector2i(-1, -1)
	return Vector2i(tx, tz)
