extends Node3D

@onready var simulation_controller: Node = $SimulationController
@onready var environment_controller: Node3D = $EnvironmentController
@onready var settlement_controller: Node3D = $SettlementController
@onready var villager_controller: Node3D = $VillagerController
@onready var culture_controller: Node3D = $CultureController
@onready var debug_overlay_root: Node3D = $DebugOverlayRoot
@onready var simulation_hud: CanvasLayer = $SimulationHud
@export var world_seed_text: String = "neolithic_vertical_slice"
@export var auto_generate_on_ready: bool = true
@export var auto_play_on_ready: bool = true

var _is_playing: bool = false
var _ticks_per_frame: int = 1
var _current_tick: int = 0
var _fork_index: int = 0
var _last_state: Dictionary = {}

func _ready() -> void:
	if simulation_hud != null:
		simulation_hud.play_pressed.connect(_on_hud_play_pressed)
		simulation_hud.pause_pressed.connect(_on_hud_pause_pressed)
		simulation_hud.fast_forward_pressed.connect(_on_hud_fast_forward_pressed)
		simulation_hud.rewind_pressed.connect(_on_hud_rewind_pressed)
		simulation_hud.fork_pressed.connect(_on_hud_fork_pressed)
	if has_node("EcologyController"):
		var ecology_controller = get_node("EcologyController")
		if ecology_controller.has_method("set_debug_overlay"):
			ecology_controller.call("set_debug_overlay", debug_overlay_root)
	if not auto_generate_on_ready:
		return
	if simulation_controller.has_method("configure"):
		simulation_controller.configure(world_seed_text, false, false)
	if not simulation_controller.has_method("configure_environment"):
		return
	var setup: Dictionary = simulation_controller.configure_environment()
	if not bool(setup.get("ok", false)):
		return
	if environment_controller.has_method("apply_generation_data"):
		environment_controller.apply_generation_data(
			setup.get("environment", {}),
			setup.get("hydrology", {})
		)
	if settlement_controller.has_method("spawn_initial_settlement"):
		settlement_controller.spawn_initial_settlement(setup.get("spawn", {}))
	_current_tick = 0
	_is_playing = auto_play_on_ready
	if simulation_controller.has_method("current_snapshot"):
		_last_state = simulation_controller.current_snapshot(0)
	_refresh_hud()

func _process(_delta: float) -> void:
	if not _is_playing:
		return
	for _i in range(_ticks_per_frame):
		_advance_tick()
	_refresh_hud()

func _advance_tick() -> void:
	if not simulation_controller.has_method("process_tick"):
		return
	var next_tick = _current_tick + 1
	var result: Dictionary = simulation_controller.process_tick(next_tick, 1.0)
	if bool(result.get("ok", false)):
		_current_tick = next_tick
		_last_state = result.get("state", {}).duplicate(true)

func _on_hud_play_pressed() -> void:
	_is_playing = true
	_ticks_per_frame = 1
	_refresh_hud()

func _on_hud_pause_pressed() -> void:
	_is_playing = false
	_refresh_hud()

func _on_hud_fast_forward_pressed() -> void:
	_is_playing = true
	_ticks_per_frame = 4 if _ticks_per_frame == 1 else 1
	_refresh_hud()

func _on_hud_rewind_pressed() -> void:
	if not simulation_controller.has_method("restore_to_tick"):
		return
	var target_tick = maxi(0, _current_tick - 24)
	var restored: Dictionary = simulation_controller.restore_to_tick(target_tick)
	if bool(restored.get("ok", false)):
		_current_tick = int(restored.get("tick", target_tick))
		if simulation_controller.has_method("current_snapshot"):
			_last_state = simulation_controller.current_snapshot(_current_tick)
	_refresh_hud()

func _on_hud_fork_pressed() -> void:
	if not simulation_controller.has_method("fork_branch"):
		return
	_fork_index += 1
	var new_branch = "branch_%02d" % _fork_index
	var forked: Dictionary = simulation_controller.fork_branch(new_branch, _current_tick)
	if bool(forked.get("ok", false)):
		if simulation_controller.has_method("current_snapshot"):
			_last_state = simulation_controller.current_snapshot(_current_tick)
	_refresh_hud()

func _refresh_hud() -> void:
	if simulation_hud == null:
		return
	var branch_id = "main"
	if simulation_controller.has_method("get_active_branch_id"):
		branch_id = String(simulation_controller.get_active_branch_id())
	var mode = "playing" if _is_playing else "paused"
	simulation_hud.set_status_text("Tick %d | Branch %s | %s x%d" % [_current_tick, branch_id, mode, _ticks_per_frame])

	var structures = 0
	var oral_events = int((_last_state.get("oral_transfer_events", []) as Array).size())
	var ritual_events = int((_last_state.get("ritual_events", []) as Array).size())
	var structures_by_household: Dictionary = _last_state.get("settlement_structures", {})
	for household_id in structures_by_household.keys():
		structures += int((structures_by_household.get(household_id, []) as Array).size())

	var belief_conflicts = _active_belief_conflicts(_current_tick)
	var detail_lines: Array[String] = []
	detail_lines.append("Structures: %d | Oral events: %d | Ritual events: %d | Belief conflicts: %d" % [structures, oral_events, ritual_events, belief_conflicts])
	if branch_id != "main" and simulation_controller.has_method("branch_diff"):
		var diff: Dictionary = simulation_controller.branch_diff("main", branch_id, maxi(0, _current_tick - 48), _current_tick)
		if bool(diff.get("ok", false)):
			var pop_delta = int(diff.get("population_delta", 0))
			var belief_delta = int(diff.get("belief_divergence", 0))
			var culture_delta = float(diff.get("culture_continuity_score_delta", 0.0))
			detail_lines.append("Diff vs main: pop %+d | belief %+d | culture %+0.3f" % [pop_delta, belief_delta, culture_delta])
	var details_text = "\n".join(detail_lines)
	if simulation_hud.has_method("set_details_text"):
		simulation_hud.set_details_text(details_text)

func _active_belief_conflicts(tick: int) -> int:
	if not simulation_controller.has_method("get_backstory_service"):
		return 0
	var service = simulation_controller.get_backstory_service()
	if service == null:
		return 0
	var villagers: Dictionary = _last_state.get("villagers", {})
	var ids = villagers.keys()
	ids.sort_custom(func(a, b): return String(a) < String(b))
	if ids.is_empty():
		return 0
	var npc_id = String(ids[0])
	var world_day = int(tick / 24)
	var result: Dictionary = service.get_belief_truth_conflicts(npc_id, world_day, 8)
	if not bool(result.get("ok", false)):
		return 0
	return int((result.get("conflicts", []) as Array).size())
