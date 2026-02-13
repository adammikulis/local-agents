extends RefCounted

var _simulation_controller: Node
var _start_year: float = 0.0
var _years_per_tick: float = 1.0
var _start_simulated_seconds: float = 0.0
var _simulated_seconds_per_tick: float = 1.0

var _is_playing: bool = false
var _ticks_per_frame: int = 1
var _current_tick: int = 0
var _fork_index: int = 0
var _simulated_seconds: float = 0.0
var _last_state: Dictionary = {}

func configure(
	simulation_controller: Node,
	start_year: float,
	years_per_tick: float,
	start_simulated_seconds: float,
	simulated_seconds_per_tick: float
) -> void:
	_simulation_controller = simulation_controller
	_start_year = start_year
	_years_per_tick = years_per_tick
	_start_simulated_seconds = start_simulated_seconds
	_simulated_seconds_per_tick = simulated_seconds_per_tick
	_simulated_seconds = maxf(0.0, start_simulated_seconds)

func initialize_from_snapshot(tick: int, auto_play: bool, snapshot: Dictionary) -> void:
	_current_tick = maxi(0, tick)
	_is_playing = auto_play
	_ticks_per_frame = 1
	_simulated_seconds = _seconds_at_tick(_current_tick)
	_last_state = _decorate_state_with_time(snapshot)

func process_frame(living_entity_profiles_provider: Callable) -> Dictionary:
	if not _is_playing:
		return {"state_changed": false, "state_advanced": false, "force_rebuild": false}
	var did_advance := false
	for _i in range(_ticks_per_frame):
		if _advance_tick(living_entity_profiles_provider):
			did_advance = true
	return {
		"state_changed": true,
		"state_advanced": did_advance,
		"force_rebuild": false,
	}

func play() -> Dictionary:
	_is_playing = true
	_ticks_per_frame = 1
	return {"state_changed": true, "state_advanced": false, "force_rebuild": false}

func pause() -> Dictionary:
	_is_playing = false
	return {"state_changed": true, "state_advanced": false, "force_rebuild": false}

func toggle_fast_forward() -> Dictionary:
	_is_playing = true
	_ticks_per_frame = 4 if _ticks_per_frame == 1 else 1
	return {"state_changed": true, "state_advanced": false, "force_rebuild": false}

func rewind_ticks(tick_delta: int) -> Dictionary:
	if _simulation_controller == null or not _simulation_controller.has_method("restore_to_tick"):
		return {"state_changed": false, "state_advanced": false, "force_rebuild": false}
	var target_tick = maxi(0, _current_tick - maxi(0, tick_delta))
	var restored: Dictionary = _simulation_controller.restore_to_tick(target_tick)
	if not bool(restored.get("ok", false)):
		return {"state_changed": true, "state_advanced": false, "force_rebuild": false}
	_current_tick = int(restored.get("tick", target_tick))
	_simulated_seconds = _seconds_at_tick(_current_tick)
	var force_rebuild := false
	if _simulation_controller.has_method("current_snapshot"):
		_last_state = _decorate_state_with_time(_simulation_controller.current_snapshot(_current_tick))
		force_rebuild = true
	return {"state_changed": true, "state_advanced": false, "force_rebuild": force_rebuild}

func fork_branch_from_current_tick() -> Dictionary:
	if _simulation_controller == null or not _simulation_controller.has_method("fork_branch"):
		return {"state_changed": false, "state_advanced": false, "force_rebuild": false}
	_fork_index += 1
	var new_branch = "branch_%02d" % _fork_index
	var forked: Dictionary = _simulation_controller.fork_branch(new_branch, _current_tick)
	var force_rebuild := false
	if bool(forked.get("ok", false)) and _simulation_controller.has_method("current_snapshot"):
		_last_state = _decorate_state_with_time(_simulation_controller.current_snapshot(_current_tick))
		force_rebuild = true
	return {"state_changed": true, "state_advanced": false, "force_rebuild": force_rebuild}

func current_tick() -> int:
	return _current_tick

func simulated_seconds() -> float:
	return _simulated_seconds

func simulated_year() -> float:
	return _year_at_tick(_current_tick)

func ticks_per_frame() -> int:
	return _ticks_per_frame

func is_playing() -> bool:
	return _is_playing

func last_state() -> Dictionary:
	return _last_state

func _advance_tick(living_entity_profiles_provider: Callable) -> bool:
	if _simulation_controller == null or not _simulation_controller.has_method("process_tick"):
		return false
	if living_entity_profiles_provider.is_valid() and _simulation_controller.has_method("set_living_entity_profiles"):
		var profiles = living_entity_profiles_provider.call()
		if profiles != null:
			_simulation_controller.call("set_living_entity_profiles", profiles)
	var next_tick = _current_tick + 1
	var result: Dictionary = _simulation_controller.process_tick(next_tick, 1.0, false)
	if not bool(result.get("ok", false)):
		return false
	_current_tick = next_tick
	_simulated_seconds = _seconds_at_tick(_current_tick)
	var state: Dictionary = result.get("state", {})
	_last_state = _decorate_state_with_time(state)
	return true

func _decorate_state_with_time(state: Dictionary) -> Dictionary:
	if state.is_empty():
		return {}
	var decorated := state.duplicate(true)
	decorated["simulated_year"] = _year_at_tick(_current_tick)
	decorated["simulated_seconds"] = _simulated_seconds
	return decorated

func _year_at_tick(tick: int) -> float:
	return _start_year + float(tick) * _years_per_tick

func _seconds_at_tick(tick: int) -> float:
	return maxf(0.0, _start_simulated_seconds + float(tick) * maxf(0.0001, _simulated_seconds_per_tick))
