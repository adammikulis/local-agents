class_name LAVoxelHarness
extends RefCounted

# Headless run-frames reporter for the voxel world, factored out of the root's _process so VoxelWorld
# stays a thin composition root. Reads live world state at the end of a `-- --run-frames=N` run, prints
# the SMOKE_SUMMARY (and optional cognition stats) the harness scrapes, then quits. Dependency-free of
# the LAVoxelWorld type (dynamic access, no cyclic class reference). (Explicit types only — no ':=' .)


# Emit the end-of-run diagnostics for the given world `w` and quit the tree. Called once, at
# _frame == _run_frames, from LAVoxelWorld._process.
static func emit_smoke_summary(w) -> void:
	var n_sel: int = w.get_tree().get_nodes_in_group("selectable").size()
	var n_act: int = w._actors_root.get_child_count()
	# Live-world diagnostics: verify the wired subsystems are actually doing something.
	var wet: int = 0
	if w._material != null and w._material.has_method("wet_cell_count"):
		wet = w._material.wet_cell_count()
	var heat_peak: float = 0.0
	var heat_cells: int = 0
	var lava_cells: int = 0
	if w._material != null and w._material.has_method("peak_heat"):
		heat_peak = w._material.peak_heat()
		heat_cells = w._material.hot_cell_count()
		if w._material.has_method("lava_peak"):
			lava_cells = w._material.lava_peak()
	var slump_cells: int = 0
	if w._material != null and w._material.has_method("slump_count"):
		slump_cells = w._material.slump_count()
	var cloud_cells: int = 0
	var cloud_cover: float = 0.0
	var fog_cover: float = 0.0
	if w._material != null and w._material.has_method("cloud_cell_count"):
		cloud_cells = w._material.cloud_cell_count()
		cloud_cover = w._material.avg_cloud_cover()
		fog_cover = w._material.avg_fog_cover()
	var wind_mag: float = 0.0
	if w._material != null and w._material.has_method("wind"):
		wind_mag = w._material.wind().length()
	var scent_cells: int = 0
	var fertility_peak: float = 0.0
	if w._material != null and w._material.has_method("scent_cell_count"):
		scent_cells = w._material.scent_cell_count()
		fertility_peak = w._material.fertility_peak()
	var n_fish: int = w.get_tree().get_nodes_in_group("species_fish").size()
	var n_fire: int = 0
	if w._ecology != null and w._ecology.has_method("fire_system"):
		var fsys = w._ecology.fire_system()
		if fsys != null and fsys.has_method("active_fire_count"):
			n_fire = fsys.active_fire_count()
	var creatures: Array = w.get_tree().get_nodes_in_group("creature")
	var min_hyd: int = 100
	var drinkers: int = 0
	var circling: int = 0        # vultures over a carcass (or soaring): the visible signal
	var investigating: int = 0   # ground scavengers reading a carrion cue ("watch the vultures")
	var sleeping: int = 0        # animals resting at their nest during their off-hours
	for c in creatures:
		if is_instance_valid(c) and "hydration" in c and "max_hydration" in c:
			var h: int = int(round(100.0 * float(c.hydration) / maxf(1.0, float(c.max_hydration))))
			min_hyd = mini(min_hyd, h)
			var st: String = String(c.get("state"))
			if st == "drink":
				drinkers += 1
			elif st == "circle" or st == "soar":
				circling += 1
			elif st == "investigate":
				investigating += 1
			elif st == "sleep" or st == "roost":
				sleeping += 1
	var n_nest: int = w.get_tree().get_nodes_in_group("nest").size()
	# Cognition/genetics aggregates: prove the fast/slow brain + evolution are actually running.
	var habits: int = 0
	var asked: int = 0
	var learned_socially: int = 0
	var max_gen: int = 0
	var minds: int = 0
	var cues_learned: int = 0
	for c in creatures:
		if not is_instance_valid(c) or not c.has_method("get_cognition"):
			continue
		var cog = c.get_cognition()
		if cog == null:
			continue
		minds += 1
		habits += cog.policy_size()
		asked += cog.escalations
		learned_socially += cog.lessons
		for cv in cog.cue_values.values():
			if float(cv) >= 0.6:
				cues_learned += 1
		if c.has_method("get_genome") and c.get_genome() != null:
			max_gen = maxi(max_gen, int(c.get_genome().generation))
	var sched_calls: int = 0
	if w._ecology != null and w._ecology.has_method("cognition_scheduler"):
		var sc = w._ecology.cognition_scheduler()
		if sc != null and sc.has_method("total_calls"):
			sched_calls = sc.total_calls()
	print("SMOKE_SUMMARY={\"frames\":%d,\"spawned_initial\":%s,\"ready\":%s,\"selectable\":%d,\"actors\":%d,\"wet_cells\":%d,\"heat_peak\":%.2f,\"heat_cells\":%d,\"lava_cells\":%d,\"slump_cells\":%d,\"peak_slump\":%d,\"cloud_cells\":%d,\"cloud_cover\":%.3f,\"fog_cover\":%.3f,\"wind\":%.2f,\"scent_cells\":%d,\"fertility_peak\":%.2f,\"fish\":%d,\"fires\":%d,\"min_hydration\":%d,\"drinking\":%d,\"time_of_day\":%.2f,\"minds\":%d,\"habits\":%d,\"escalations\":%d,\"social_lessons\":%d,\"max_generation\":%d,\"slow_brain_calls\":%d,\"nests\":%d,\"circling\":%d,\"investigating\":%d,\"sleeping\":%d,\"cues_learned\":%d}" % [
		w._frame, str(w._spawned_initial).to_lower(), str(w._terrain.is_ready_at(Vector3.ZERO)).to_lower(), n_sel, n_act, wet, heat_peak, heat_cells, lava_cells, slump_cells, w._peak_slump, cloud_cells, cloud_cover, fog_cover, wind_mag, scent_cells, fertility_peak, n_fish, n_fire, min_hyd, drinkers, (w._sky.time_of_day() if w._sky != null else w._time_of_day), minds, habits, asked, learned_socially, max_gen, sched_calls, n_nest, circling, investigating, sleeping, cues_learned])
	if w._cognition_stats:
		var avg_habits: float = (float(habits) / float(minds)) if minds > 0 else 0.0
		print("COGNITION_SUMMARY minds=%d avg_habits=%.2f escalations=%d social_lessons=%d max_generation=%d slow_brain_calls=%d nests=%d circling=%d investigating=%d sleeping=%d cues_learned=%d" % [
			minds, avg_habits, asked, learned_socially, max_gen, sched_calls, n_nest, circling, investigating, sleeping, cues_learned])
		print("BEHAVIOUR_PEAKS peak_circling=%d peak_investigating=%d peak_sleeping=%d cues_learned=%d" % [
			w._peak_circling, w._peak_investigating, w._peak_sleeping, cues_learned])
	w.get_tree().quit(0)
