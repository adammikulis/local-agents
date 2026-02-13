extends RefCounted
class_name LocalAgentsGeologyController

const LegacyVolcanicControllerScript = preload("res://addons/local_agents/scenes/simulation/app/controllers/VoxelVolcanicController.gd")

var _legacy = LegacyVolcanicControllerScript.new()

func set_seed(seed: int) -> void:
	_legacy.set_seed(seed)

func reset() -> void:
	_legacy.reset()

func clear_pending_rebake() -> void:
	_legacy.clear_pending_rebake()

func pending_state() -> Dictionary:
	return _legacy.pending_state()

func spawn_manual_vent_at(world_snapshot: Dictionary, tx: int, tz: int, sim_tick: int, island_growth: float) -> Dictionary:
	return _legacy.spawn_manual_vent_at(world_snapshot, tx, tz, sim_tick, island_growth)

func try_spawn_new_vent(world_snapshot: Dictionary, sim_tick: int) -> Dictionary:
	return _legacy.try_spawn_new_vent(world_snapshot, sim_tick)

func find_volcano_by_tile_id(world_snapshot: Dictionary, tile_id: String) -> Dictionary:
	return _legacy.find_volcano_by_tile_id(world_snapshot, tile_id)

func step(world_snapshot: Dictionary, sim_tick: int, tick_duration: float, ticks_per_frame: int, eruption_interval: float, new_vent_chance: float, island_growth: float, manual_eruption_active: bool, manual_selected_vent_tile_id: String, hydrology_rebake_every_events: int, hydrology_rebake_max_seconds: float, spawn_lava_plume: Callable) -> Dictionary:
	return _legacy.step(world_snapshot, sim_tick, tick_duration, ticks_per_frame, eruption_interval, new_vent_chance, island_growth, manual_eruption_active, manual_selected_vent_tile_id, hydrology_rebake_every_events, hydrology_rebake_max_seconds, spawn_lava_plume)
