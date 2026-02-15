@tool
extends SceneTree

const WorldGeneratorScript = preload("res://addons/local_agents/simulation/WorldGenerator.gd")
const WorldGenConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")
const EnvironmentControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/EnvironmentController.gd")

var _mode: String = "both"
var _iterations: int = 3
var _ticks: int = 96
var _gpu_frames: int = 120
var _width: int = 64
var _height: int = 64
var _world_height: int = 40
var _seed_text: String = "voxel_benchmark"

func _init() -> void:
	_parse_args()
	call_deferred("_run")

func _run() -> void:
	var results: Dictionary = {
		"mode": _mode,
		"iterations": _iterations,
		"ticks": _ticks,
		"gpu_frames": _gpu_frames,
		"size": {"width": _width, "height": _height, "world_height": _world_height},
	}
	if _mode in ["cpu", "both"]:
		results["cpu"] = _run_cpu_benchmark()
	if _mode in ["gpu", "both"]:
		results["gpu"] = await _run_gpu_benchmark()
	print(JSON.stringify(results, "", false, true))
	quit(0)

func _run_cpu_benchmark() -> Dictionary:
	var durations_ms: Array = []
	for i in range(_iterations):
		var seed = int(hash("%s_cpu_%d" % [_seed_text, i]))
		var config = _build_config()
		var world_generator = WorldGeneratorScript.new()
		var t0 = Time.get_ticks_usec()
		world_generator.generate(seed, config)
		var transform_state = _initial_transform_state(seed)
		for tick in range(1, _ticks + 1):
			transform_state = _advance_transform_state(transform_state, tick)
		var t1 = Time.get_ticks_usec()
		durations_ms.append(float(t1 - t0) / 1000.0)
	return _stats(durations_ms)

func _run_gpu_benchmark() -> Dictionary:
	var durations_ms: Array = []
	var upload_ms: Array = []
	var per_frame_ms: Array = []
	for i in range(_iterations):
		var seed = int(hash("%s_gpu_%d" % [_seed_text, i]))
		var config = _build_config()
		var world_generator = WorldGeneratorScript.new()
		var world = world_generator.generate(seed, config)
		var transform_state = _initial_transform_state(seed)
		var root = Node3D.new()
		var env = EnvironmentControllerScript.new()
		var terrain_root = Node3D.new()
		terrain_root.name = "TerrainRoot"
		var water_root = Node3D.new()
		water_root.name = "WaterRoot"
		env.add_child(terrain_root)
		env.add_child(water_root)
		root.add_child(env)
		get_root().add_child(root)
		await process_frame

		var up0 = Time.get_ticks_usec()
		env.apply_generation_data(world, {"stage": "voxel_transform_step", "water_tiles": {}})
		env.set_transform_stage_a_state(transform_state.get("transform_stage_a_state", {}))
		env.set_transform_stage_d_state(transform_state.get("exposure_state_snapshot", {}))
		var up1 = Time.get_ticks_usec()
		upload_ms.append(float(up1 - up0) / 1000.0)

		var t0 = Time.get_ticks_usec()
		var frame_time_accum = 0.0
		for tick in range(1, _gpu_frames + 1):
			var f0 = Time.get_ticks_usec()
			transform_state = _advance_transform_state(transform_state, tick)
			env.set_transform_stage_a_state(transform_state.get("transform_stage_a_state", {}))
			env.set_transform_stage_d_state(transform_state.get("exposure_state_snapshot", {}))
			await process_frame
			var f1 = Time.get_ticks_usec()
			frame_time_accum += float(f1 - f0) / 1000.0
		var t1 = Time.get_ticks_usec()
		durations_ms.append(float(t1 - t0) / 1000.0)
		per_frame_ms.append(frame_time_accum / float(maxi(1, _gpu_frames)))

		root.queue_free()
		await process_frame

	return {
		"total": _stats(durations_ms),
		"upload": _stats(upload_ms),
		"avg_frame": _stats(per_frame_ms),
		"notes": [
			"gpu benchmark measures render-path upload/update loop with shaders active",
			"terrain noise generation itself is CPU in current implementation",
		],
	}

func _build_config():
	var config = WorldGenConfigResourceScript.new()
	config.map_width = _width
	config.map_height = _height
	config.voxel_world_height = _world_height
	config.voxel_sea_level = maxi(1, int(float(_world_height) * 0.28))
	config.voxel_surface_height_base = maxi(2, int(float(_world_height) * 0.22))
	config.voxel_surface_height_range = maxi(4, int(float(_world_height) * 0.36))
	return config

func _stats(values: Array) -> Dictionary:
	if values.is_empty():
		return {"samples": 0, "min_ms": 0.0, "max_ms": 0.0, "mean_ms": 0.0}
	var min_v = float(values[0])
	var max_v = float(values[0])
	var sum = 0.0
	for v_variant in values:
		var v = float(v_variant)
		min_v = minf(min_v, v)
		max_v = maxf(max_v, v)
		sum += v
	return {
		"samples": values.size(),
		"min_ms": min_v,
		"max_ms": max_v,
		"mean_ms": sum / float(values.size()),
	}

func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="):
			_mode = arg.trim_prefix("--mode=").to_lower().strip_edges()
		elif arg.begins_with("--iterations="):
			_iterations = maxi(1, int(arg.trim_prefix("--iterations=")))
		elif arg.begins_with("--ticks="):
			_ticks = maxi(1, int(arg.trim_prefix("--ticks=")))
		elif arg.begins_with("--gpu-frames="):
			_gpu_frames = maxi(1, int(arg.trim_prefix("--gpu-frames=")))
		elif arg.begins_with("--width="):
			_width = maxi(8, int(arg.trim_prefix("--width=")))
		elif arg.begins_with("--height="):
			_height = maxi(8, int(arg.trim_prefix("--height=")))
		elif arg.begins_with("--world-height="):
			_world_height = maxi(8, int(arg.trim_prefix("--world-height=")))
		elif arg.begins_with("--seed="):
			_seed_text = arg.trim_prefix("--seed=").strip_edges()
	if not _mode in ["cpu", "gpu", "both"]:
		_mode = "both"

func _initial_transform_state(seed: int) -> Dictionary:
	return {
		"replacement_stage": "voxel_transform_step",
		"tick": 0,
		"seed": seed,
		"diagnostics": {
			"avg_activity": 0.0,
			"avg_energy": 0.0,
			"avg_moisture": 0.0,
		},
		"transform_stage_a_state": {
			"replacement_stage": "voxel_transform_step",
			"avg_rain_intensity": 0.0,
			"avg_cloud_cover": 0.0,
			"avg_humidity": 0.35,
		},
		"exposure_state_snapshot": {
			"replacement_stage": "voxel_transform_step",
			"sun_altitude": 0.5,
			"global_irradiance": 0.65,
		},
	}

func _advance_transform_state(state: Dictionary, tick: int) -> Dictionary:
	var phase = float(tick % 96) / 96.0
	var rain = clampf(0.5 + sin(phase * TAU) * 0.18, 0.0, 1.0)
	var cloud = clampf(0.45 + cos(phase * TAU) * 0.2, 0.0, 1.0)
	var humidity = clampf(0.38 + rain * 0.4, 0.0, 1.0)
	var irradiance = clampf(0.55 + sin((phase - 0.25) * TAU) * 0.35, 0.0, 1.0)
	return {
		"replacement_stage": "voxel_transform_step",
		"tick": tick,
		"seed": int(state.get("seed", 0)),
		"diagnostics": {
			"avg_activity": rain,
			"avg_energy": irradiance,
			"avg_moisture": humidity,
		},
		"transform_stage_a_state": {
			"replacement_stage": "voxel_transform_step",
			"avg_rain_intensity": rain,
			"avg_cloud_cover": cloud,
			"avg_humidity": humidity,
		},
		"exposure_state_snapshot": {
			"replacement_stage": "voxel_transform_step",
			"sun_altitude": clampf(0.2 + irradiance * 0.7, 0.0, 1.0),
			"global_irradiance": irradiance,
		},
	}
