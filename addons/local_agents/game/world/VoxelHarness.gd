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
	# Storm life-cycle telemetry: charge_peak (should rise then discharge in a sawtooth, not pin at breakdown)
	# and cumulative bolts (their per-window delta shows lightning clustered in storm episodes, not constant).
	var charge_peak: float = float(snap.get("charge_peak", 0.0))
	var bolts: int = int(snap.get("bolts", 0))
	var rain: float = float(snap.get("moisture_total", 0.0))
	var clouds: int = int(snap.get("cloud_cells", 0))
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
	# CLIMATE STRUCTURE readout — snow/ice cover + cold-pole proof, so a long run shows the thermal STRUCTURE
	# (not just a mean) settling: snow_cells + sea_ice persist at the poles while the habitable band stays temperate.
	# LATITUDE-FIXED ground truth: sample the field temp at fixed equatorial + polar surface points (independent of
	# where trees happen to be), so a real climate STRUCTURE (warm equator, cold pole) is visible and can't be
	# confused with a moving tree-probe. Surface radius is read from a live tree's distance to the planet centre.
	var t_eq: float = 0.0
	var t_pole: float = 0.0
	if mat != null and mat.has_method("temp_at") and w._body != null:
		var ctr: Vector3 = w._body.center()
		var axis: Vector3 = Vector3(0.40, 0.92, 0.0).normalized()   # PLANET_SPIN_AXIS
		var surf_r: float = 250.0
		var trees0: Array = tree.get_nodes_in_group("tree")
		if trees0.size() > 0 and is_instance_valid(trees0[0]) and trees0[0] is Node3D:
			surf_r = ((trees0[0] as Node3D).global_position - ctr).length()
		var eq_dir: Vector3 = axis.cross(Vector3(1, 0, 0)).normalized()
		if eq_dir.length() < 0.1:
			eq_dir = axis.cross(Vector3(0, 0, 1)).normalized()
		t_eq = float(mat.temp_at(ctr + eq_dir * (surf_r + 2.0)))
		t_pole = float(mat.temp_at(ctr + axis * (surf_r + 2.0)))
	# HERBIVORE FEEDING telemetry: for living rabbits, average energy%, gut-fill%, and the grazable groundcover
	# biomass at their feet — so a starvation collapse tells us WHETHER they can find food (biomass≈0 = no food
	# reachable) or are simply outbred/predated (energy low but biomass present). Decisive for the food question.
	var rab_e: float = 0.0
	var rab_g: float = 0.0
	var rab_b: float = 0.0
	var rab_n: int = 0
	if mat != null and mat.has_method("biomass_at"):
		var rabs: Array = tree.get_nodes_in_group("species_rabbit")
		for i in range(mini(rabs.size(), 30)):
			var rb = rabs[i]
			if is_instance_valid(rb) and rb is Node3D:
				rab_e += float(rb.energy) / maxf(float(rb.max_energy), 1.0)
				rab_g += float(rb.gut) / maxf(float(rb.gut_capacity), 1.0)
				var rp: Vector3 = (rb as Node3D).global_position
				var upv: Vector3 = rb.terrain.up_at(rp) if (rb.terrain != null and rb.terrain.has_method("up_at")) else Vector3.UP
				var feet: Vector3 = rp + upv * maxf(float(rb.size), 0.8)
				rab_b += float(mat.temp_at(feet))   # ground-temp at the grazer's feet = the new groundcover food signal
				rab_n += 1
	if rab_n > 0:
		rab_e /= float(rab_n)
		rab_g /= float(rab_n)
		rab_b /= float(rab_n)
	var t_min: float = float(snap.get("temp_min", 0.0))
	var t_max: float = float(snap.get("temp_max", 0.0))
	var snow_c: int = int(snap.get("snow_cells", 0))
	var ice_c: int = int(snap.get("ice_cells", 0))
	var sea_ice: int = int(snap.get("sea_ice_cells", 0))
	var cloud_cover: float = float(snap.get("cloud_cover", 0.0))
	var open_sea_t: float = float(snap.get("open_sea_temp", 0.0))
	print("POP_TRACE={\"frame\":%d,\"counts\":%s,\"temp_mean\":%.1f,\"surf_mean\":%.1f,\"surf_max\":%.1f,\"t_eq\":%.1f,\"t_pole\":%.1f,\"rab_e\":%.2f,\"rab_gut\":%.2f,\"rab_bio\":%.4f,\"t_min\":%.1f,\"t_max\":%.1f,\"snow\":%d,\"ice\":%d,\"sea_ice\":%d,\"cloud_cover\":%.3f,\"sea_t\":%.1f,\"charge_peak\":%.2f,\"bolts\":%d,\"moisture\":%.0f,\"cloud_cells\":%d,\"deaths\":%s}" % [frame, JSON.stringify(counts), temp_mean, surf_mean, surf_max, t_eq, t_pole, rab_e, rab_g, rab_b, t_min, t_max, snow_c, ice_c, sea_ice, cloud_cover, open_sea_t, charge_peak, bolts, rain, clouds, JSON.stringify(deaths)])


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
	var _cam: Camera3D = w.get_viewport().get_camera_3d() if w.get_viewport() != null else null
	if _cam != null:
		LASimReport.gauge("camera_far", _cam.far)   # proof the draw-distance knob bites
	LASimReport.emit()
	LAAppExit.request(w, 0)
