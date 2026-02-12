extends RefCounted
class_name LocalAgentsStructureLifecycleSystem

const StructureLifecycleConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/StructureLifecycleConfigResource.gd")
const StructureResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/StructureResource.gd")
const AnchorResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/AnchorResource.gd")

var _config = StructureLifecycleConfigResourceScript.new()
var _anchors: Dictionary = {}
var _structures: Dictionary = {}
var _household_structure_ids: Dictionary = {}
var _last_expand_tick: Dictionary = {}
var _low_access_ticks: Dictionary = {}
var _depletion_ticks: Dictionary = {}
var _last_camp_tick: Dictionary = {}
var _path_extension_emitted: Dictionary = {}

func set_config(config_resource) -> void:
	if config_resource == null:
		_config = StructureLifecycleConfigResourceScript.new()
		return
	_config = config_resource

func ensure_core_anchors(center: Vector3) -> void:
	_ensure_anchor("anchor_water", "water_access", "", center + Vector3(-1.4, 0.0, -0.8))
	_ensure_anchor("anchor_hearth", "hearth", "", center + Vector3(0.0, 0.0, 0.0))
	_ensure_anchor("anchor_storage", "storage", "", center + Vector3(1.3, 0.0, 0.9))

func ensure_household(household_id: String, position: Vector3, tick: int) -> void:
	if household_id.strip_edges() == "":
		return
	var rows: Array = _household_structure_ids.get(household_id, [])
	if not rows.is_empty():
		return
	var structure = StructureResourceScript.new()
	structure.structure_id = "hut_%s_0" % household_id
	structure.structure_type = "hut"
	structure.household_id = household_id
	structure.state = "active"
	structure.position = position
	structure.durability = 1.0
	structure.created_tick = tick
	structure.last_updated_tick = tick
	_structures[structure.structure_id] = structure
	_household_structure_ids[household_id] = [structure.structure_id]
	_last_expand_tick[household_id] = tick
	_low_access_ticks[household_id] = 0
	_depletion_ticks[household_id] = 0
	_last_camp_tick[household_id] = -999999
	_path_extension_emitted[household_id] = false

func step_lifecycle(tick: int, household_members: Dictionary, household_metrics: Dictionary, household_positions: Dictionary, water_snapshot: Dictionary) -> Dictionary:
	var expanded: Array = []
	var abandoned: Array = []
	var camps: Array = []
	var path_extensions: Array = []
	var household_ids = household_members.keys()
	household_ids.sort()
	for household_id_variant in household_ids:
		var household_id = String(household_id_variant)
		var position = household_positions.get(household_id, Vector3.ZERO)
		if position is Vector3:
			ensure_household(household_id, position as Vector3, tick)
		var members = int(household_members.get(household_id, 0))
		var huts = _active_hut_count(household_id)
		var metrics: Dictionary = household_metrics.get(household_id, {})
		var throughput = clampf(float(metrics.get("throughput", 0.0)), 0.0, 1000.0)
		var path_strength = clampf(float(metrics.get("path_strength", 0.0)), 0.0, 1.0)
		var depletion_signal = _resource_depletion_signal(metrics, throughput, path_strength)
		var crowding = float(members) / float(maxi(1, huts))
		if _should_expand(household_id, tick, crowding, throughput, huts):
			var new_structure = _spawn_hut(household_id, position, tick, water_snapshot, huts)
			if new_structure != null:
				expanded.append(new_structure.structure_id)
		var depletion_ticks = _update_depletion_counter(household_id, depletion_signal)
		if _should_emit_path_extension(household_id, depletion_ticks):
			var path_event = {
				"household_id": household_id,
				"depletion_signal": depletion_signal,
				"sustain_ticks": depletion_ticks,
				"target_radius": _suggested_path_extension_radius(household_id),
			}
			path_extensions.append(path_event)
			_path_extension_emitted[household_id] = true
		if _should_spawn_temporary_camp(household_id, tick, depletion_ticks):
			var camp = _spawn_temporary_camp(household_id, position, tick, water_snapshot)
			if camp != null:
				camps.append(camp.to_dict())
				_last_camp_tick[household_id] = tick
		_update_low_access_counter(household_id, throughput, path_strength)
		if _should_abandon(household_id, huts):
			var removed_id = _abandon_latest_hut(household_id, tick)
			if removed_id != "":
				abandoned.append(removed_id)
		if depletion_ticks <= 0:
			_path_extension_emitted[household_id] = false
			_retire_temporary_camps(household_id, tick)
	return {
		"expanded": expanded,
		"abandoned": abandoned,
		"camps": camps,
		"path_extensions": path_extensions,
		"structures": export_structures(),
		"anchors": export_anchors(),
	}

func export_structures() -> Dictionary:
	var by_household: Dictionary = {}
	var household_ids = _household_structure_ids.keys()
	household_ids.sort()
	for household_id_variant in household_ids:
		var household_id = String(household_id_variant)
		var structure_ids: Array = _household_structure_ids.get(household_id, [])
		var rows: Array = []
		for sid_variant in structure_ids:
			var sid = String(sid_variant)
			var structure = _structures.get(sid, null)
			if structure == null:
				continue
			rows.append(structure.to_dict())
		rows.sort_custom(func(a, b):
			return String((a as Dictionary).get("structure_id", "")) < String((b as Dictionary).get("structure_id", ""))
		)
		by_household[household_id] = rows
	return by_household

func export_anchors() -> Array:
	var ids = _anchors.keys()
	ids.sort()
	var rows: Array = []
	for anchor_id_variant in ids:
		var anchor_id = String(anchor_id_variant)
		var anchor = _anchors.get(anchor_id, null)
		if anchor == null:
			continue
		rows.append(anchor.to_dict())
	return rows

func export_runtime_state() -> Dictionary:
	return {
		"last_expand_tick": _last_expand_tick.duplicate(true),
		"low_access_ticks": _low_access_ticks.duplicate(true),
		"depletion_ticks": _depletion_ticks.duplicate(true),
		"last_camp_tick": _last_camp_tick.duplicate(true),
		"path_extension_emitted": _path_extension_emitted.duplicate(true),
	}

func import_lifecycle_state(structures_by_household: Dictionary, anchors: Array, runtime_state: Dictionary = {}) -> void:
	_anchors.clear()
	_structures.clear()
	_household_structure_ids.clear()
	_last_expand_tick = runtime_state.get("last_expand_tick", {}).duplicate(true)
	_low_access_ticks = runtime_state.get("low_access_ticks", {}).duplicate(true)
	_depletion_ticks = runtime_state.get("depletion_ticks", {}).duplicate(true)
	_last_camp_tick = runtime_state.get("last_camp_tick", {}).duplicate(true)
	_path_extension_emitted = runtime_state.get("path_extension_emitted", {}).duplicate(true)
	for anchor_variant in anchors:
		if not (anchor_variant is Dictionary):
			continue
		var row = anchor_variant as Dictionary
		var anchor = AnchorResourceScript.new()
		anchor.from_dict(row)
		if anchor.anchor_id.strip_edges() == "":
			continue
		_anchors[anchor.anchor_id] = anchor
	var household_ids = structures_by_household.keys()
	household_ids.sort_custom(func(a, b): return String(a) < String(b))
	for household_id_variant in household_ids:
		var household_id = String(household_id_variant)
		var rows: Array = structures_by_household.get(household_id, [])
		var ids: Array = []
		for row_variant in rows:
			if not (row_variant is Dictionary):
				continue
			var structure = StructureResourceScript.new()
			structure.from_dict(row_variant as Dictionary)
			if structure.structure_id.strip_edges() == "":
				continue
			_structures[structure.structure_id] = structure
			ids.append(structure.structure_id)
		ids.sort()
		_household_structure_ids[household_id] = ids

func _ensure_anchor(anchor_id: String, anchor_type: String, household_id: String, position: Vector3) -> void:
	if _anchors.has(anchor_id):
		return
	var anchor = AnchorResourceScript.new()
	anchor.anchor_id = anchor_id
	anchor.anchor_type = anchor_type
	anchor.household_id = household_id
	anchor.position = position
	_anchors[anchor_id] = anchor

func _active_hut_count(household_id: String) -> int:
	var count = 0
	for sid_variant in _household_structure_ids.get(household_id, []):
		var sid = String(sid_variant)
		var structure = _structures.get(sid, null)
		if structure == null:
			continue
		if String(structure.state) == "active" and String(structure.structure_type) == "hut":
			count += 1
	return count

func _should_expand(household_id: String, tick: int, crowding: float, throughput: float, huts: int) -> bool:
	if huts >= int(_config.max_huts_per_household):
		return false
	if crowding < float(_config.crowding_members_per_hut_threshold):
		return false
	if throughput < float(_config.throughput_expand_threshold):
		return false
	var last_tick = int(_last_expand_tick.get(household_id, -999999))
	return (tick - last_tick) >= int(_config.expand_cooldown_ticks)

func _update_low_access_counter(household_id: String, throughput: float, path_strength: float) -> void:
	var low_throughput = throughput < float(_config.low_throughput_abandon_threshold)
	var low_path = path_strength < float(_config.low_path_strength_abandon_threshold)
	if low_throughput and low_path:
		_low_access_ticks[household_id] = int(_low_access_ticks.get(household_id, 0)) + 1
	else:
		_low_access_ticks[household_id] = 0

func _resource_depletion_signal(metrics: Dictionary, throughput: float, path_strength: float) -> float:
	var throughput_ratio = clampf(
		throughput / maxf(0.01, float(_config.throughput_expand_threshold)),
		0.0,
		1.0
	)
	var scarcity = 1.0 - throughput_ratio
	var route_fragility = 1.0 - path_strength
	var partial_pressure = clampf(float(metrics.get("partial_delivery_ratio", 0.0)), 0.0, 1.0)
	return clampf(scarcity * 0.55 + route_fragility * 0.25 + partial_pressure * 0.2, 0.0, 1.0)

func _update_depletion_counter(household_id: String, depletion_signal: float) -> int:
	var threshold = float(_config.depletion_signal_threshold)
	var next_ticks = 0
	if depletion_signal >= threshold:
		next_ticks = int(_depletion_ticks.get(household_id, 0)) + 1
	else:
		next_ticks = max(0, int(_depletion_ticks.get(household_id, 0)) - 2)
	_depletion_ticks[household_id] = next_ticks
	return next_ticks

func _should_emit_path_extension(household_id: String, depletion_ticks: int) -> bool:
	if bool(_path_extension_emitted.get(household_id, false)):
		return false
	return depletion_ticks >= int(_config.path_extension_trigger_ticks)

func _should_spawn_temporary_camp(household_id: String, tick: int, depletion_ticks: int) -> bool:
	if depletion_ticks < int(_config.depletion_sustain_ticks):
		return false
	var last = int(_last_camp_tick.get(household_id, -999999))
	if (tick - last) < int(_config.camp_spawn_cooldown_ticks):
		return false
	return _active_temporary_camp_count(household_id) < int(_config.max_temporary_camps_per_household)

func _active_temporary_camp_count(household_id: String) -> int:
	var count = 0
	for sid_variant in _household_structure_ids.get(household_id, []):
		var sid = String(sid_variant)
		var structure = _structures.get(sid, null)
		if structure == null:
			continue
		if String(structure.structure_type) != "camp_temp":
			continue
		if String(structure.state) == "active":
			count += 1
	return count

func _suggested_path_extension_radius(household_id: String) -> float:
	var active_camps = _active_temporary_camp_count(household_id)
	var huts = _active_hut_count(household_id)
	var base = float(_config.hut_start_radius) + float(maxi(0, huts - 1)) * float(_config.hut_ring_step)
	return snappedf(base + float(active_camps + 1) * float(_config.hut_ring_step) * 0.75, 0.01)

func _should_abandon(household_id: String, huts: int) -> bool:
	if huts <= int(_config.min_huts_per_household):
		return false
	return int(_low_access_ticks.get(household_id, 0)) >= int(_config.abandon_sustain_ticks)

func _spawn_hut(household_id: String, base_position_variant, tick: int, water_snapshot: Dictionary, existing_huts: int):
	var base_position = Vector3.ZERO
	if base_position_variant is Vector3:
		base_position = base_position_variant as Vector3
	var ring_index = maxi(0, existing_huts)
	var angle = (float(ring_index) * 1.731) + float((abs(household_id.hash()) % 6283)) * 0.001
	var radius = float(_config.hut_start_radius) + float(ring_index) * float(_config.hut_ring_step)
	var candidate_a = base_position + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
	var candidate_b = base_position + Vector3(cos(angle + 0.8) * radius, 0.0, sin(angle + 0.8) * radius)
	var best = candidate_a
	if _flood_risk(candidate_b, water_snapshot) < _flood_risk(candidate_a, water_snapshot):
		best = candidate_b

	var structure = StructureResourceScript.new()
	structure.structure_id = "hut_%s_%d" % [household_id, existing_huts]
	structure.structure_type = "hut"
	structure.household_id = household_id
	structure.state = "active"
	structure.position = best
	structure.durability = 1.0
	structure.created_tick = tick
	structure.last_updated_tick = tick
	_structures[structure.structure_id] = structure
	var ids: Array = _household_structure_ids.get(household_id, [])
	ids.append(structure.structure_id)
	_household_structure_ids[household_id] = ids
	_last_expand_tick[household_id] = tick
	return structure

func _spawn_temporary_camp(household_id: String, base_position_variant, tick: int, water_snapshot: Dictionary):
	var base_position = Vector3.ZERO
	if base_position_variant is Vector3:
		base_position = base_position_variant as Vector3
	var camp_index = _active_temporary_camp_count(household_id)
	var huts = _active_hut_count(household_id)
	var ring = float(_config.hut_start_radius) + float(maxi(1, huts)) * float(_config.hut_ring_step) * float(_config.camp_ring_multiplier)
	var angle = (float(camp_index + huts + 1) * 2.211) + float((abs((household_id + ":camp").hash()) % 6283)) * 0.001
	var candidate_a = base_position + Vector3(cos(angle) * ring, 0.0, sin(angle) * ring)
	var candidate_b = base_position + Vector3(cos(angle + 0.6) * ring, 0.0, sin(angle + 0.6) * ring)
	var best = candidate_a
	if _flood_risk(candidate_b, water_snapshot) < _flood_risk(candidate_a, water_snapshot):
		best = candidate_b

	var structure = StructureResourceScript.new()
	structure.structure_id = "camp_%s_%d" % [household_id, tick]
	structure.structure_type = "camp_temp"
	structure.household_id = household_id
	structure.state = "active"
	structure.position = best
	structure.durability = 0.7
	structure.created_tick = tick
	structure.last_updated_tick = tick
	_structures[structure.structure_id] = structure
	var ids: Array = _household_structure_ids.get(household_id, [])
	ids.append(structure.structure_id)
	_household_structure_ids[household_id] = ids
	return structure

func _abandon_latest_hut(household_id: String, tick: int) -> String:
	var ids: Array = _household_structure_ids.get(household_id, [])
	if ids.is_empty():
		return ""
	for index in range(ids.size() - 1, -1, -1):
		var sid = String(ids[index])
		var structure = _structures.get(sid, null)
		if structure == null:
			continue
		if String(structure.structure_type) != "hut":
			continue
		if String(structure.state) != "active":
			continue
		structure.state = "abandoned"
		structure.last_updated_tick = tick
		_low_access_ticks[household_id] = 0
		return sid
	return ""

func _retire_temporary_camps(household_id: String, tick: int) -> void:
	for sid_variant in _household_structure_ids.get(household_id, []):
		var sid = String(sid_variant)
		var structure = _structures.get(sid, null)
		if structure == null:
			continue
		if String(structure.structure_type) != "camp_temp":
			continue
		if String(structure.state) != "active":
			continue
		structure.state = "abandoned"
		structure.last_updated_tick = tick

func _flood_risk(world_position: Vector3, water_snapshot: Dictionary) -> float:
	var tile_id = "%d:%d" % [int(round(world_position.x)), int(round(world_position.z))]
	var water_tiles: Dictionary = water_snapshot.get("water_tiles", {})
	var row = water_tiles.get(tile_id, {})
	if not (row is Dictionary):
		return 0.0
	return clampf(float((row as Dictionary).get("flood_risk", 0.0)), 0.0, 1.0)
