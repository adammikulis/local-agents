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
	LASimReport.gauge("time_of_day", w._sky.time_of_day() if w._sky != null else w._time_of_day)
	LASimReport.gauge("peak_slump", float(w._peak_slump))
	LASimReport.gauge("fps", Performance.get_monitor(Performance.TIME_FPS))
	LASimReport.gauge("process_ms", Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	LASimReport.gauge("physics_ms", Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	LASimReport.gauge("nodes", Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	LASimReport.gauge("draw_calls", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	LASimReport.gauge("prims_M", Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1.0e6)
	LASimReport.gauge("video_mem_MB", Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1.048576e6)
	LASimReport.emit()
	w.get_tree().quit(0)
