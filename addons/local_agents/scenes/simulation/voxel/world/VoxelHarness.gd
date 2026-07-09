class_name LAVoxelHarness
extends RefCounted

# Headless run-frames reporter for the voxel world, factored out of the root's _process so VoxelWorld
# stays a thin composition root. Reads live world state at the end of a `-- --run-frames=N` run, prints
# the SMOKE_SUMMARY (and optional cognition stats) the harness scrapes, then quits. Dependency-free of
# the LAVoxelWorld type (dynamic access, no cyclic class reference). (Explicit types only — no ':=' .)


# Emit the end-of-run diagnostics for the given world `w` and quit the tree. Called once, at
# _frame == _run_frames, from LAVoxelWorld._process.
static func _count_meshes(n: Node) -> int:
	var c: int = 0
	if n is MeshInstance3D and (n as MeshInstance3D).visible and (n as MeshInstance3D).mesh != null:
		c += maxi(1, (n as MeshInstance3D).mesh.get_surface_count())
	for ch in n.get_children():
		c += _count_meshes(ch)
	return c


# Compact population + mortality trajectory sample, printed periodically through a long run-frames run so the
# population arc (and WHY it moves — which death causes dominate) is visible over time, not just at the end.
# One line the balance harness scrapes: POP_TRACE={frame, per-species counts, plants/trees, temp, deaths-so-far}.
static func emit_population_trace(w, frame: int) -> void:
	var tree: SceneTree = w.get_tree()
	var counts: Dictionary = {}
	for sp in ["rabbit", "fox", "bird", "villager", "vulture", "fish"]:
		counts[sp] = tree.get_nodes_in_group("species_%s" % sp).size()
	counts["creatures"] = tree.get_nodes_in_group("creature").size()
	counts["plants"] = tree.get_nodes_in_group("plant").size()
	counts["trees"] = tree.get_nodes_in_group("tree").size()
	var deaths: Dictionary = {}
	var snap: Dictionary = LASimReport.snapshot()
	var ev = snap.get("events", {})
	if ev is Dictionary:
		for k in ev:
			if String(k).begins_with("death/"):
				deaths[String(k).substr(6)] = ev[k]
	var temp_mean: float = float(snap.get("temp_mean", 0.0))
	# Sample the temperature creatures ACTUALLY stand in: read the field at living surface actors (trees/plants).
	var surf_sum: float = 0.0
	var surf_max: float = -1.0e9
	var surf_n: int = 0
	var mat = w._material if "_material" in w else null
	if mat != null and mat.has_method("temp_at"):
		var probes: Array = tree.get_nodes_in_group("tree")
		if probes.size() < 8:
			probes = tree.get_nodes_in_group("plant")
		for i in range(mini(probes.size(), 40)):
			var p = probes[i]
			if is_instance_valid(p) and p is Node3D:
				var t: float = float(mat.temp_at((p as Node3D).global_position + Vector3(0.0, 2.0, 0.0)))
				surf_sum += t
				surf_max = maxf(surf_max, t)
				surf_n += 1
	var surf_mean: float = surf_sum / float(surf_n) if surf_n > 0 else 0.0
	print("POP_TRACE={\"frame\":%d,\"counts\":%s,\"temp_mean\":%.1f,\"surf_mean\":%.1f,\"surf_max\":%.1f,\"deaths\":%s}" % [frame, JSON.stringify(counts), temp_mean, surf_mean, surf_max, JSON.stringify(deaths)])


static func emit_smoke_summary(w) -> void:
	# Draw-call source breakdown (mesh surfaces per actor group) — instancing target, only under LA_PROFILE.
	if OS.has_environment("LA_PROFILE"):
		var parts: PackedStringArray = PackedStringArray()
		for g in ["creature", "fish", "plant", "tree", "rock", "nest", "villager"]:
			var nodes: Array = w.get_tree().get_nodes_in_group(g)
			var m: int = 0
			for nd in nodes:
				m += _count_meshes(nd)
			parts.append("%s:n=%d,surf=%d" % [g, nodes.size(), m])
		print("DRAW_SOURCES={%s}" % ", ".join(parts))
	# Field, population + cognition all flow from their registered LASimReport providers; deaths are events;
	# behaviour peaks are gauges (VoxelWorld._sample_behaviour_peaks). Feed the last few run-scalars + the
	# ground-truth perf monitors, then emit the ONE SIM_REPORT snapshot and quit. (SMOKE_SUMMARY retired.)
	LASimReport.gauge("frames", float(w._frame))
	LASimReport.gauge("time_of_day", w._sky_ctrl.time_of_day() if w._sky_ctrl != null else 0.30)
	LASimReport.gauge("peak_slump", float(w._peak_slump))
	LASimReport.gauge("fps", Performance.get_monitor(Performance.TIME_FPS))
	LASimReport.gauge("process_ms", Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	LASimReport.gauge("physics_ms", Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	LASimReport.gauge("nodes", Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	LASimReport.gauge("draw_calls", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	LASimReport.gauge("prims_M", Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1.0e6)
	LASimReport.gauge("video_mem_MB", Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1.048576e6)
	LASimReport.emit()
	LAAppExit.request(w, 0)
