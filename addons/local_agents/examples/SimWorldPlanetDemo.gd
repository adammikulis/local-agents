extends Node3D

## Library demo — a whole cubed-sphere PLANET with a living ecology from a single LocalAgentSimWorld node, with NO
## game shell (no HUD, menus, disasters, save system or streamer). This is the "standalone planet" story:
## LocalAgentSimWorld composes the planet body, the MaterialField, the ecology and the spawn, and this scene just
## frames it with a camera and adds a LocalAgentDemoHarness so `-- --run-frames=N` prints SIM_WORLD_REPORT then
## quits. (Explicit types only — project rule: no ':=' inferred typing.)

const SimWorldScript: GDScript = preload("res://addons/local_agents/sim/SimWorld.gd")

@export_group("Planet")
## Mean radius of the planet in world units. The camera frames itself from this.
@export_range(20.0, 2000.0, 1.0, "suffix:m") var radius: float = 180.0
## Per-cube-face field resolution. Higher = a finer simulation grid but more GPU cost.
@export_range(8, 64, 1) var grid_res: int = 16

var _sim = null
var _harness_frames: int = 0


func _ready() -> void:
	_sim = SimWorldScript.new()
	_sim.name = "SimWorld"
	_sim.world_type = LocalAgentSimWorld.WorldType.SPHERE
	_sim.radius = radius
	_sim.grid_res = grid_res
	add_child(_sim)
	_build_camera()
	_add_harness()


func _build_camera() -> void:
	var cam: Camera3D = Camera3D.new()
	cam.position = Vector3(0.0, 0.0, radius * 2.6)
	cam.far = maxf(4000.0, radius * 12.0)
	cam.current = true
	add_child(cam)
	var light: DirectionalLight3D = DirectionalLight3D.new()
	light.rotation = Vector3(-0.6, 0.5, 0.0)
	add_child(light)


# The shared headless harness: `-- --run-frames=N` prints SIM_WORLD_REPORT={...} and quits. It lives on the
# demo, not inside LocalAgentSimWorld — a reusable library node has no business owning a process exit.
func _add_harness() -> void:
	var harness: LocalAgentDemoHarness = LocalAgentDemoHarness.new()
	harness.name = "DemoHarness"
	harness.report_prefix = "SIM_WORLD"
	harness.report_source = self
	add_child(harness)


func demo_harness_configured(frames: int, _shoot: String) -> void:
	_harness_frames = frames


# The payload LocalAgentDemoHarness prints at the end of a `--run-frames=N` run.
func demo_report() -> Dictionary:
	var kind: String = "SPHERE" if _sim.world_type == LocalAgentSimWorld.WorldType.SPHERE else "FLAT"
	# NOTE: `_spawned` is read reflectively because LocalAgentSimWorld exposes no public accessor for it.
	# A `has_spawned() -> bool` on that facade would be the right home — see the report to the coordinator.
	var spawned: bool = bool(_sim.get("_spawned"))
	return {
		"world_type": kind,
		"frames": _harness_frames,
		"creatures": get_tree().get_nodes_in_group("creature").size(),
		"plants": get_tree().get_nodes_in_group("plant").size(),
		"spawned": spawned,
	}
