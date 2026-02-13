extends RefCounted
class_name LocalAgentsHydrologySystem

const HydrologyComputeBackendScript = preload("res://addons/local_agents/simulation/HydrologyComputeBackend.gd")
const HydrologySystemHelpersScript = preload("res://addons/local_agents/simulation/hydrology/HydrologySystemHelpers.gd")
const MaterialFlowNativeStageHelpersScript = preload("res://addons/local_agents/simulation/material_flow/MaterialFlowNativeStageHelpers.gd")
const NativeComputeBridgeScript = preload("res://addons/local_agents/simulation/controller/NativeComputeBridge.gd")
const _IDLE_CADENCE := 8
const _NATIVE_STAGE_NAME := "hydrology_step"

var _compute_requested: bool = false
var _compute_active: bool = false
var _compute_backend = HydrologyComputeBackendScript.new()
var _ordered_tile_ids: Array[String] = []
var _native_environment_stage_dispatch_enabled: bool = false
var _native_view_metrics: Dictionary = {}

func set_compute_enabled(enabled: bool) -> void:
    _compute_requested = enabled
    if not enabled:
        _compute_active = false

func is_compute_active() -> bool:
    return _compute_active

func set_native_environment_stage_dispatch_enabled(enabled: bool) -> void:
    _native_environment_stage_dispatch_enabled = enabled

func set_native_view_metrics(metrics: Dictionary) -> void:
    _native_view_metrics = MaterialFlowNativeStageHelpersScript.sanitize_native_view_metrics(metrics)

func build_network(world_data: Dictionary, config) -> Dictionary:
    var width = int(world_data.get("width", 0))
    var height = int(world_data.get("height", 0))
    var tiles: Array = world_data.get("tiles", [])
    var flow_map: Dictionary = world_data.get("flow_map", {})
    var springs: Dictionary = world_data.get("springs", {})
    var water_table: Dictionary = world_data.get("water_table", {})
    if not flow_map.is_empty():
        return _build_network_from_flow_map(flow_map, tiles, springs, water_table, config)

    var by_xy: Dictionary = {}
    var by_id: Dictionary = {}
    for row_variant in tiles:
        if not (row_variant is Dictionary):
            continue
        var row: Dictionary = row_variant
        var x = int(row.get("x", 0))
        var y = int(row.get("y", 0))
        var tile_id = String(row.get("tile_id", "%d:%d" % [x, y]))
        by_xy["%d:%d" % [x, y]] = row
        by_id[tile_id] = row

    var sources: Array = []
    var spring_all: Array = springs.get("all", [])
    var spring_ids: Dictionary = {}
    for spring_variant in spring_all:
        if not (spring_variant is Dictionary):
            continue
        var spring_row = spring_variant as Dictionary
        var spring_id = String(spring_row.get("tile_id", ""))
        if spring_id == "":
            continue
        spring_ids[spring_id] = spring_row
        sources.append(spring_id)
    for row_variant in tiles:
        var row: Dictionary = row_variant
        var tile_id = String(row.get("tile_id", ""))
        if tile_id == "":
            continue
        if spring_ids.has(tile_id):
            continue
        if float(row.get("elevation", 0.0)) >= float(config.spring_elevation_threshold) and float(row.get("moisture", 0.0)) >= float(config.spring_moisture_threshold):
            sources.append(tile_id)
    sources = HydrologySystemHelpersScript.dedupe_sorted_strings(sources)

    var flow_by_tile: Dictionary = {}
    var segments: Array = []
    var max_steps = maxi(4, width + height)

    for source_id in sources:
        var current_id = source_id
        var visited: Dictionary = {}
        for step in range(max_steps):
            if visited.has(current_id):
                break
            visited[current_id] = true
            flow_by_tile[current_id] = float(flow_by_tile.get(current_id, 0.0)) + 1.0
            var next_id = HydrologySystemHelpersScript.next_downhill_tile(current_id, by_id, by_xy)
            if next_id == "":
                break
            segments.append({"from": current_id, "to": next_id})
            current_id = next_id

    var water_tiles: Dictionary = {}
    for row_variant in tiles:
        var row: Dictionary = row_variant
        var tile_id = String(row.get("tile_id", ""))
        var flow = float(flow_by_tile.get(tile_id, 0.0))
        var moisture = float(row.get("moisture", 0.0))
        var depth = clampf(float(row.get("water_table_depth", 99.0)), 0.0, 99.0)
        var pressure = clampf(float(row.get("hydraulic_pressure", 0.0)), 0.0, 1.0)
        var recharge = clampf(float(row.get("groundwater_recharge", 0.0)), 0.0, 1.0)
        var spring_row = spring_ids.get(tile_id, {})
        var spring_discharge = clampf(float((spring_row as Dictionary).get("discharge", 0.0)) if spring_row is Dictionary else 0.0, 0.0, 8.0)
        var groundwater = clampf(1.0 - (depth / 12.0), 0.0, 1.0)
        var perennial = clampf((flow / 5.0) * 0.45 + moisture * 0.14 + groundwater * 0.16 + pressure * 0.12 + recharge * 0.08 + spring_discharge * 0.05, 0.0, 1.0)
        var flood_risk = clampf((flow - float(config.floodplain_flow_threshold) + 1.0) / 4.0 + spring_discharge * 0.03, 0.0, 1.0)
        water_tiles[tile_id] = {
            "flow": flow,
            "water_reliability": perennial,
            "flood_risk": flood_risk,
            "water_table_depth": depth,
            "hydraulic_pressure": pressure,
            "groundwater_recharge": recharge,
            "spring_discharge": spring_discharge,
        }

    segments.sort_custom(func(a, b):
        var a_key = "%s>%s" % [String(a.get("from", "")), String(a.get("to", ""))]
        var b_key = "%s>%s" % [String(b.get("from", "")), String(b.get("to", ""))]
        return a_key < b_key
    )

    var result = {
        "schema_version": 1,
        "source_tiles": sources,
        "segments": segments,
        "water_tiles": water_tiles,
        "total_flow_index": HydrologySystemHelpersScript.total_flow(flow_by_tile),
        "springs": springs,
        "water_table": water_table,
    }
    _refresh_compute_backend_from_snapshots(world_data, result)
    return result

func step(
    tick: int,
    delta: float,
    environment_snapshot: Dictionary,
    hydrology_snapshot: Dictionary,
    weather_snapshot: Dictionary,
    local_activity: Dictionary = {}
) -> Dictionary:
    if environment_snapshot.is_empty() or hydrology_snapshot.is_empty():
        return {
            "environment": environment_snapshot,
            "hydrology": hydrology_snapshot,
            "changed": false,
            "changed_tiles": [],
        }
    var tile_index: Dictionary = environment_snapshot.get("tile_index", {})
    var water_tiles: Dictionary = hydrology_snapshot.get("water_tiles", {})
    if tile_index.is_empty() or water_tiles.is_empty():
        return {
            "environment": environment_snapshot,
            "hydrology": hydrology_snapshot,
            "changed": false,
            "changed_tiles": [],
        }
    var weather_tiles: Dictionary = weather_snapshot.get("tile_index", {})
    var weather_buffers: Dictionary = weather_snapshot.get("buffers", {})
    var weather_rain: PackedFloat32Array = weather_buffers.get("rain", PackedFloat32Array())
    var weather_wetness: PackedFloat32Array = weather_buffers.get("wetness", PackedFloat32Array())
    var weather_buffer_ok = weather_rain.size() > 0 and weather_wetness.size() == weather_rain.size()
    var width = int(environment_snapshot.get("width", 0))
    var seed = int(hydrology_snapshot.get("seed", 0))
    var changed_map: Dictionary = {}
    var native_step = _step_native_environment_stage(
        tick,
        delta,
        environment_snapshot,
        hydrology_snapshot,
        weather_snapshot,
        local_activity
    )
    if not native_step.is_empty():
        return native_step

    var tile_ids = water_tiles.keys()
    tile_ids.sort_custom(func(a, b): return String(a) < String(b))
    var use_compute = _compute_active and _ordered_tile_ids.size() == tile_ids.size()
    if use_compute:
        var compute_result = _step_compute(
            tick,
            delta,
            seed,
            width,
            tile_index,
            water_tiles,
            local_activity,
            weather_tiles,
            weather_snapshot,
            weather_rain,
            weather_wetness,
            weather_buffer_ok
        )
        if not compute_result.is_empty():
            var compute_changed: Array = compute_result.get("changed_tiles", [])
            if not compute_changed.is_empty():
                HydrologySystemHelpersScript.sync_tiles(environment_snapshot, tile_index)
            hydrology_snapshot["water_tiles"] = water_tiles
            hydrology_snapshot["tick"] = tick
            return {
                "environment": environment_snapshot,
                "hydrology": hydrology_snapshot,
                "changed": not compute_changed.is_empty(),
                "changed_tiles": compute_changed,
            }
        _compute_active = false

    for tile_id_variant in tile_ids:
        var tile_id = String(tile_id_variant)
        if not tile_index.has(tile_id):
            continue
        var tile_row = tile_index.get(tile_id, {})
        var water_row = water_tiles.get(tile_id, {})
        if not (tile_row is Dictionary) or not (water_row is Dictionary):
            continue
        var activity = maxf(
            clampf(float(local_activity.get(tile_id, 0.0)), 0.0, 1.0),
            HydrologySystemHelpersScript.coastal_activity_bonus(tile_row as Dictionary)
        )
        var cadence = HydrologySystemHelpersScript.cadence_for_activity(activity, _IDLE_CADENCE)
        if cadence > 1 and not HydrologySystemHelpersScript.should_step_tile(tile_id, tick, cadence, seed):
            continue
        var local_dt = maxf(0.0, delta) * float(cadence)
        var weather = HydrologySystemHelpersScript.weather_at_tile(tile_id, weather_tiles, weather_snapshot, weather_rain, weather_wetness, weather_buffer_ok, width)
        var rain = clampf(float(weather.get("rain", 0.0)), 0.0, 1.0)
        var wetness = clampf(float(weather.get("wetness", rain)), 0.0, 1.0)
        var tile = tile_row as Dictionary
        var water = (water_row as Dictionary).duplicate(true)
        var moisture = clampf(float(tile.get("moisture", 0.5)), 0.0, 1.0)
        var elevation = clampf(float(tile.get("elevation", 0.5)), 0.0, 1.0)
        var slope = clampf(float(tile.get("slope", 0.0)), 0.0, 1.0)
        var heat = clampf(float(tile.get("heat_load", 0.0)), 0.0, 1.5)
        var spring_discharge = clampf(float(water.get("spring_discharge", 0.0)), 0.0, 8.0)
        var prev_depth = clampf(float(water.get("water_table_depth", tile.get("water_table_depth", 8.0))), 0.0, 99.0)
        var prev_pressure = clampf(float(water.get("hydraulic_pressure", tile.get("hydraulic_pressure", 0.0))), 0.0, 1.0)
        var prev_recharge = clampf(float(water.get("groundwater_recharge", tile.get("groundwater_recharge", 0.0))), 0.0, 1.0)
        var prev_flow = maxf(0.0, float(water.get("flow", 0.0)))

        var runoff = clampf((slope * 0.55 + rain * 0.45) * (0.7 + wetness * 0.3), 0.0, 1.0)
        var infiltration = clampf((0.06 + moisture * 0.2 + wetness * 0.22 + rain * 0.1) * (1.0 - slope * 0.45), 0.0, 1.0)
        var evap_loss = clampf(0.01 + heat * 0.05 + (1.0 - moisture) * 0.025, 0.0, 0.2)
        var recharge = clampf(prev_recharge * 0.92 + infiltration * local_dt - runoff * 0.015 * local_dt - evap_loss * 0.05 * local_dt, 0.0, 1.0)
        var pressure = clampf(prev_pressure * 0.9 + recharge * 0.1 * local_dt + spring_discharge * 0.01 - runoff * 0.03 * local_dt, 0.0, 1.0)
        var target_depth = clampf(8.0 + elevation * 10.0 - recharge * 7.5 - pressure * 4.5 - spring_discharge * 0.9 + heat * 1.9, 0.0, 99.0)
        var depth = lerpf(prev_depth, target_depth, clampf(0.12 * local_dt, 0.0, 1.0))
        var groundwater = clampf(1.0 - (depth / 12.0), 0.0, 1.0)
        var flow = maxf(0.0, prev_flow * 0.93 + rain * 0.45 * local_dt + runoff * 0.38 + groundwater * 0.35 + spring_discharge * 0.2)
        var flow_norm = 1.0 - exp(-flow * 0.18)
        var reliability = clampf(flow_norm * 0.48 + groundwater * 0.19 + moisture * 0.14 + recharge * 0.11 + pressure * 0.08, 0.0, 1.0)
        var flood_risk = clampf(float(water.get("flood_risk", 0.0)) * 0.9 + rain * 0.2 + runoff * 0.26 + pressure * 0.14 + spring_discharge * 0.03, 0.0, 1.0)

        water["flow"] = flow
        water["water_reliability"] = reliability
        water["flood_risk"] = flood_risk
        water["water_table_depth"] = depth
        water["hydraulic_pressure"] = pressure
        water["groundwater_recharge"] = recharge
        water_tiles[tile_id] = water

        var tile_changed = (
            absf(depth - prev_depth) > 0.01
            or absf(pressure - prev_pressure) > 0.004
            or absf(recharge - prev_recharge) > 0.004
        )
        if not tile_changed:
            continue
        tile["water_table_depth"] = depth
        tile["hydraulic_pressure"] = pressure
        tile["groundwater_recharge"] = recharge
        tile["moisture"] = clampf(moisture * 0.985 + reliability * 0.015, 0.0, 1.0)
        tile_index[tile_id] = tile
        changed_map[tile_id] = true

    var changed_tiles: Array = []
    for tile_id_variant in changed_map.keys():
        changed_tiles.append(String(tile_id_variant))
    changed_tiles.sort_custom(func(a, b): return String(a) < String(b))
    if not changed_tiles.is_empty():
        HydrologySystemHelpersScript.sync_tiles(environment_snapshot, tile_index)
    hydrology_snapshot["water_tiles"] = water_tiles
    hydrology_snapshot["tick"] = tick
    return {
        "environment": environment_snapshot,
        "hydrology": hydrology_snapshot,
        "changed": not changed_tiles.is_empty(),
        "changed_tiles": changed_tiles,
    }

func _refresh_compute_backend_from_snapshots(environment_snapshot: Dictionary, hydrology_snapshot: Dictionary) -> void:
    _ordered_tile_ids.clear()
    var tile_index: Dictionary = environment_snapshot.get("tile_index", {})
    var water_tiles: Dictionary = hydrology_snapshot.get("water_tiles", {})
    if tile_index.is_empty() or water_tiles.is_empty():
        _compute_active = false
        return
    var ids = water_tiles.keys()
    ids.sort_custom(func(a, b): return String(a) < String(b))
    var base_moisture := PackedFloat32Array()
    var base_elevation := PackedFloat32Array()
    var base_slope := PackedFloat32Array()
    var base_heat := PackedFloat32Array()
    var spring_discharge := PackedFloat32Array()
    var flow := PackedFloat32Array()
    var reliability := PackedFloat32Array()
    var flood_risk := PackedFloat32Array()
    var water_depth := PackedFloat32Array()
    var pressure := PackedFloat32Array()
    var recharge := PackedFloat32Array()
    base_moisture.resize(ids.size())
    base_elevation.resize(ids.size())
    base_slope.resize(ids.size())
    base_heat.resize(ids.size())
    spring_discharge.resize(ids.size())
    flow.resize(ids.size())
    reliability.resize(ids.size())
    flood_risk.resize(ids.size())
    water_depth.resize(ids.size())
    pressure.resize(ids.size())
    recharge.resize(ids.size())
    for i in range(ids.size()):
        var tile_id = String(ids[i])
        _ordered_tile_ids.append(tile_id)
        var tile_row = tile_index.get(tile_id, {})
        var water_row = water_tiles.get(tile_id, {})
        base_moisture[i] = clampf(float((tile_row as Dictionary).get("moisture", 0.5)) if tile_row is Dictionary else 0.5, 0.0, 1.0)
        base_elevation[i] = clampf(float((tile_row as Dictionary).get("elevation", 0.5)) if tile_row is Dictionary else 0.5, 0.0, 1.0)
        base_slope[i] = clampf(float((tile_row as Dictionary).get("slope", 0.0)) if tile_row is Dictionary else 0.0, 0.0, 1.0)
        base_heat[i] = clampf(float((tile_row as Dictionary).get("heat_load", 0.0)) if tile_row is Dictionary else 0.0, 0.0, 1.5)
        spring_discharge[i] = clampf(float((water_row as Dictionary).get("spring_discharge", 0.0)) if water_row is Dictionary else 0.0, 0.0, 8.0)
        flow[i] = maxf(0.0, float((water_row as Dictionary).get("flow", 0.0)) if water_row is Dictionary else 0.0)
        reliability[i] = clampf(float((water_row as Dictionary).get("water_reliability", 0.0)) if water_row is Dictionary else 0.0, 0.0, 1.0)
        flood_risk[i] = clampf(float((water_row as Dictionary).get("flood_risk", 0.0)) if water_row is Dictionary else 0.0, 0.0, 1.0)
        water_depth[i] = clampf(float((water_row as Dictionary).get("water_table_depth", 8.0)) if water_row is Dictionary else 8.0, 0.0, 99.0)
        pressure[i] = clampf(float((water_row as Dictionary).get("hydraulic_pressure", 0.0)) if water_row is Dictionary else 0.0, 0.0, 1.0)
        recharge[i] = clampf(float((water_row as Dictionary).get("groundwater_recharge", 0.0)) if water_row is Dictionary else 0.0, 0.0, 1.0)
    _compute_active = false
    if _compute_requested:
        _compute_active = _compute_backend.configure(
            base_moisture,
            base_elevation,
            base_slope,
            base_heat,
            spring_discharge,
            flow,
            reliability,
            flood_risk,
            water_depth,
            pressure,
            recharge
        )

func _step_compute(
    tick: int,
    delta: float,
    seed: int,
    width: int,
    tile_index: Dictionary,
    water_tiles: Dictionary,
    local_activity: Dictionary,
    weather_tiles: Dictionary,
    weather_snapshot: Dictionary,
    weather_rain: PackedFloat32Array,
    weather_wetness: PackedFloat32Array,
    weather_buffer_ok: bool
) -> Dictionary:
    var count = _ordered_tile_ids.size()
    if count <= 0:
        return {}
    var rain := PackedFloat32Array()
    var wetness := PackedFloat32Array()
    var activity := PackedFloat32Array()
    rain.resize(count)
    wetness.resize(count)
    activity.resize(count)
    for i in range(count):
        var tile_id = _ordered_tile_ids[i]
        var weather = HydrologySystemHelpersScript.weather_at_tile(tile_id, weather_tiles, weather_snapshot, weather_rain, weather_wetness, weather_buffer_ok, width)
        rain[i] = clampf(float(weather.get("rain", 0.0)), 0.0, 1.0)
        wetness[i] = clampf(float(weather.get("wetness", rain[i])), 0.0, 1.0)
        var tile_row = tile_index.get(tile_id, {})
        var local_act = clampf(float(local_activity.get(tile_id, 0.0)), 0.0, 1.0)
        var coastal_bonus = HydrologySystemHelpersScript.coastal_activity_bonus(tile_row as Dictionary) if tile_row is Dictionary else 0.0
        activity[i] = maxf(local_act, coastal_bonus)
    var gpu = _compute_backend.step(delta, tick, _IDLE_CADENCE, seed, rain, wetness, activity)
    if gpu.is_empty():
        return {}
    var flow: PackedFloat32Array = gpu.get("flow", PackedFloat32Array())
    var reliability: PackedFloat32Array = gpu.get("water_reliability", PackedFloat32Array())
    var flood_risk: PackedFloat32Array = gpu.get("flood_risk", PackedFloat32Array())
    var water_depth: PackedFloat32Array = gpu.get("water_table_depth", PackedFloat32Array())
    var pressure: PackedFloat32Array = gpu.get("hydraulic_pressure", PackedFloat32Array())
    var recharge: PackedFloat32Array = gpu.get("groundwater_recharge", PackedFloat32Array())
    if flow.size() != count or reliability.size() != count or flood_risk.size() != count or water_depth.size() != count or pressure.size() != count or recharge.size() != count:
        return {}
    var changed_tiles: Array = []
    for i in range(count):
        var tile_id = _ordered_tile_ids[i]
        if not water_tiles.has(tile_id):
            continue
        var water_row = water_tiles.get(tile_id, {})
        var tile_row = tile_index.get(tile_id, {})
        if not (water_row is Dictionary) or not (tile_row is Dictionary):
            continue
        var prev_depth = clampf(float((water_row as Dictionary).get("water_table_depth", 8.0)), 0.0, 99.0)
        var prev_pressure = clampf(float((water_row as Dictionary).get("hydraulic_pressure", 0.0)), 0.0, 1.0)
        var prev_recharge = clampf(float((water_row as Dictionary).get("groundwater_recharge", 0.0)), 0.0, 1.0)
        (water_row as Dictionary)["flow"] = maxf(0.0, float(flow[i]))
        (water_row as Dictionary)["water_reliability"] = clampf(float(reliability[i]), 0.0, 1.0)
        (water_row as Dictionary)["flood_risk"] = clampf(float(flood_risk[i]), 0.0, 1.0)
        (water_row as Dictionary)["water_table_depth"] = clampf(float(water_depth[i]), 0.0, 99.0)
        (water_row as Dictionary)["hydraulic_pressure"] = clampf(float(pressure[i]), 0.0, 1.0)
        (water_row as Dictionary)["groundwater_recharge"] = clampf(float(recharge[i]), 0.0, 1.0)
        water_tiles[tile_id] = (water_row as Dictionary)
        var next_depth = float((water_row as Dictionary).get("water_table_depth", prev_depth))
        var next_pressure = float((water_row as Dictionary).get("hydraulic_pressure", prev_pressure))
        var next_recharge = float((water_row as Dictionary).get("groundwater_recharge", prev_recharge))
        if absf(next_depth - prev_depth) > 0.01 or absf(next_pressure - prev_pressure) > 0.004 or absf(next_recharge - prev_recharge) > 0.004:
            (tile_row as Dictionary)["water_table_depth"] = next_depth
            (tile_row as Dictionary)["hydraulic_pressure"] = next_pressure
            (tile_row as Dictionary)["groundwater_recharge"] = next_recharge
            var moisture = clampf(float((tile_row as Dictionary).get("moisture", 0.5)), 0.0, 1.0)
            var rel = clampf(float((water_row as Dictionary).get("water_reliability", 0.0)), 0.0, 1.0)
            (tile_row as Dictionary)["moisture"] = clampf(moisture * 0.985 + rel * 0.015, 0.0, 1.0)
            tile_index[tile_id] = (tile_row as Dictionary)
            changed_tiles.append(tile_id)
    changed_tiles.sort_custom(func(a, b): return String(a) < String(b))
    return {"changed_tiles": changed_tiles}

func _step_native_environment_stage(
    tick: int,
    delta: float,
    environment_snapshot: Dictionary,
    hydrology_snapshot: Dictionary,
    weather_snapshot: Dictionary,
    local_activity: Dictionary
) -> Dictionary:
    if not _native_environment_stage_dispatch_enabled:
        return {}
    var dispatch = NativeComputeBridgeScript.dispatch_environment_stage_call(
        null,
        tick,
        "hydrology",
        _NATIVE_STAGE_NAME,
        MaterialFlowNativeStageHelpersScript.build_environment_stage_payload(
            tick,
            delta,
            environment_snapshot,
            hydrology_snapshot,
            weather_snapshot,
            local_activity,
            _native_view_metrics
        ),
        false
    )
    if not NativeComputeBridgeScript.is_environment_stage_dispatched(dispatch):
        return {}
    var native_result = NativeComputeBridgeScript.environment_stage_result(dispatch)
    if native_result.is_empty():
        return {}
    var native_environment = native_result.get("environment", environment_snapshot)
    var native_hydrology = native_result.get("hydrology", hydrology_snapshot)
    if not (native_environment is Dictionary) or not (native_hydrology is Dictionary):
        return {}
    var env = native_environment as Dictionary
    var hydro = native_hydrology as Dictionary
    var changed_tiles_variant = native_result.get("changed_tiles", [])
    if not (changed_tiles_variant is Array):
        changed_tiles_variant = []
    var changed_tiles: Array = (changed_tiles_variant as Array).duplicate(true)
    changed_tiles.sort_custom(func(a, b): return String(a) < String(b))
    var changed = bool(native_result.get("changed", not changed_tiles.is_empty()))
    hydro["tick"] = tick
    return {
        "environment": env,
        "hydrology": hydro,
        "changed": changed,
        "changed_tiles": changed_tiles,
    }

func _build_network_from_flow_map(flow_map: Dictionary, tiles: Array, springs: Dictionary, water_table: Dictionary, config) -> Dictionary:
    var by_tile: Dictionary = {}
    for row_variant in tiles:
        if not (row_variant is Dictionary):
            continue
        var row = row_variant as Dictionary
        var tile_id = String(row.get("tile_id", ""))
        if tile_id != "":
            by_tile[tile_id] = row

    var rows: Array = flow_map.get("rows", [])
    var max_flow = maxf(0.001, float(flow_map.get("max_flow", 1.0)))
    var segments: Array = []
    var sources: Array = []
    var spring_rows: Array = springs.get("all", [])
    var springs_by_tile: Dictionary = {}
    for spring_variant in spring_rows:
        if not (spring_variant is Dictionary):
            continue
        var spring_row = spring_variant as Dictionary
        var spring_id = String(spring_row.get("tile_id", ""))
        if spring_id == "":
            continue
        springs_by_tile[spring_id] = spring_row
        sources.append(spring_id)
    var water_tiles: Dictionary = {}
    var total_flow = 0.0

    for row_variant in rows:
        if not (row_variant is Dictionary):
            continue
        var row = row_variant as Dictionary
        var tile_id = String(row.get("tile_id", ""))
        if tile_id == "":
            continue
        var downstream = String(row.get("to_tile_id", ""))
        if downstream != "":
            segments.append({"from": tile_id, "to": downstream})
        var accumulation = maxf(0.0, float(row.get("flow_accumulation", 0.0)))
        total_flow += accumulation
        var flow_norm = clampf(accumulation / max_flow, 0.0, 1.0)
        var moisture = clampf(float(row.get("moisture", 0.0)), 0.0, 1.0)
        var tile_row = by_tile.get(tile_id, {})
        var wt_depth = clampf(float((tile_row as Dictionary).get("water_table_depth", 99.0)) if tile_row is Dictionary else 99.0, 0.0, 99.0)
        var wt_pressure = clampf(float((tile_row as Dictionary).get("hydraulic_pressure", 0.0)) if tile_row is Dictionary else 0.0, 0.0, 1.0)
        var wt_recharge = clampf(float((tile_row as Dictionary).get("groundwater_recharge", 0.0)) if tile_row is Dictionary else 0.0, 0.0, 1.0)
        var spring_row = springs_by_tile.get(tile_id, {})
        var spring_discharge = clampf(float((spring_row as Dictionary).get("discharge", 0.0)) if spring_row is Dictionary else 0.0, 0.0, 8.0)
        var groundwater = clampf(1.0 - (wt_depth / 12.0), 0.0, 1.0)
        var reliability = clampf(flow_norm * 0.58 + moisture * 0.14 + groundwater * 0.14 + wt_pressure * 0.09 + wt_recharge * 0.05 + spring_discharge * 0.04, 0.0, 1.0)
        var flood_risk = clampf((flow_norm - 0.55) * 2.1 + spring_discharge * 0.04, 0.0, 1.0)
        water_tiles[tile_id] = {
            "flow": accumulation,
            "water_reliability": reliability,
            "flood_risk": flood_risk,
            "water_table_depth": wt_depth,
            "hydraulic_pressure": wt_pressure,
            "groundwater_recharge": wt_recharge,
            "spring_discharge": spring_discharge,
        }

        var tile = tile_row
        var tile_elevation = 0.0
        if tile is Dictionary:
            tile_elevation = float((tile as Dictionary).get("elevation", 0.0))
        var elevation = clampf(float(row.get("elevation", tile_elevation)), 0.0, 1.0)
        if not springs_by_tile.has(tile_id) and elevation >= float(config.spring_elevation_threshold) and moisture >= float(config.spring_moisture_threshold):
            sources.append(tile_id)

    if sources.is_empty():
        var ranked: Array = rows.duplicate(true)
        ranked.sort_custom(func(a, b):
            var af = float((a as Dictionary).get("flow_accumulation", 0.0))
            var bf = float((b as Dictionary).get("flow_accumulation", 0.0))
            if is_equal_approx(af, bf):
                return String((a as Dictionary).get("tile_id", "")) < String((b as Dictionary).get("tile_id", ""))
            return af > bf
        )
        for i in range(mini(8, ranked.size())):
            var row = ranked[i] as Dictionary
            var tile_id = String(row.get("tile_id", ""))
            if tile_id != "":
                sources.append(tile_id)
    sources = HydrologySystemHelpersScript.dedupe_sorted_strings(sources)

    segments.sort_custom(func(a, b):
        var a_key = "%s>%s" % [String(a.get("from", "")), String(a.get("to", ""))]
        var b_key = "%s>%s" % [String(b.get("from", "")), String(b.get("to", ""))]
        return a_key < b_key
    )

    var result = {
        "schema_version": 1,
        "source_tiles": sources,
        "segments": segments,
        "water_tiles": water_tiles,
        "total_flow_index": total_flow,
        "flow_map_schema_version": int(flow_map.get("schema_version", 1)),
        "springs": springs,
        "water_table": water_table,
    }
    _refresh_compute_backend_from_snapshots({"tile_index": by_tile}, result)
    return result
