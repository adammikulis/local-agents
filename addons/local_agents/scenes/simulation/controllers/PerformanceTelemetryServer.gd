extends Node

signal metrics_updated(metrics: Dictionary)

@export_range(0.05, 2.0, 0.05) var refresh_seconds: float = 0.25
@export var emit_on_ready: bool = true
@export var simulation_controller_path: NodePath = NodePath("../SimulationController")
@export var world_simulation_path: NodePath = NodePath("..")

var _accum: float = 0.0
var _simulation_controller: Node
var _world_simulation: Node

func _ready() -> void:
	add_to_group("performance_telemetry_server")
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	_simulation_controller = get_node_or_null(simulation_controller_path)
	_world_simulation = get_node_or_null(world_simulation_path)
	if emit_on_ready:
		_emit_metrics()

func _process(delta: float) -> void:
	_accum += maxf(0.0, delta)
	var interval := maxf(0.05, refresh_seconds)
	if _accum < interval:
		return
	_accum -= interval
	_emit_metrics()

func force_emit() -> void:
	_emit_metrics()

func _emit_metrics() -> void:
	var payload := {
		"fps": int(round(float(Performance.get_monitor(Performance.TIME_FPS)))),
		"memory_static_bytes": float(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"memory_vram_bytes": float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)),
		"object_count": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"primitives": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
	}
	var destruction_runtime: Dictionary = {}
	if _world_simulation != null and _world_simulation.has_method("native_voxel_dispatch_runtime"):
		var runtime_variant = _world_simulation.call("native_voxel_dispatch_runtime")
		if runtime_variant is Dictionary:
			destruction_runtime = (runtime_variant as Dictionary).duplicate(true)
	if _simulation_controller != null and _simulation_controller.has_method("runtime_backend_metrics"):
		var runtime_backend_metrics: Dictionary = _simulation_controller.call("runtime_backend_metrics")
		runtime_backend_metrics["destruction_pipeline"] = destruction_runtime
		payload["runtime_backends"] = runtime_backend_metrics
		payload["runtime_backend_metrics"] = runtime_backend_metrics
	elif not destruction_runtime.is_empty():
		var runtime_backends := {"destruction_pipeline": destruction_runtime}
		payload["runtime_backends"] = runtime_backends
		payload["runtime_backend_metrics"] = runtime_backends
	emit_signal("metrics_updated", payload)
