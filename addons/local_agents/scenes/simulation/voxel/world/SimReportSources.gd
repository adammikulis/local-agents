class_name LASimReportSources
extends RefCounted

## Telemetry providers for LASimReport — pull population + cognition aggregates from the live tree at snapshot
## time (registered once in VoxelWorld, so these scans run only when a report is taken, not per frame). Static
## + dependency-free of the concrete node types (dynamic access). This is where the old hand-synced
## SMOKE_SUMMARY computation moved to — each subsystem owns its slice of SIM_REPORT. (Explicit types only.)


## Live population / hydration snapshot.
static func population(w) -> Dictionary:
	var tree: SceneTree = w.get_tree()
	var creatures: Array = tree.get_nodes_in_group("creature")
	var min_hyd: int = 100
	var drinkers: int = 0
	for c in creatures:
		if not is_instance_valid(c):
			continue
		if "hydration" in c and "max_hydration" in c:
			var h: int = int(round(100.0 * float(c.hydration) / maxf(1.0, float(c.max_hydration))))
			min_hyd = mini(min_hyd, h)
		if String(c.get("state")) == "drink":
			drinkers += 1
	var n_fire: int = 0
	if w._ecology != null and w._ecology.has_method("fire_system"):
		var fsys = w._ecology.fire_system()
		if fsys != null and fsys.has_method("active_fire_count"):
			n_fire = fsys.active_fire_count()
	return {
		"fires": n_fire,
		"selectable": tree.get_nodes_in_group("selectable").size(),
		"actors": w._actors_root.get_child_count() if w._actors_root != null else 0,
		"creatures": creatures.size(),
		"rabbit": tree.get_nodes_in_group("species_rabbit").size(),
		"fox": tree.get_nodes_in_group("species_fox").size(),
		"bird": tree.get_nodes_in_group("species_bird").size(),
		"villager": tree.get_nodes_in_group("species_villager").size(),
		"vulture": tree.get_nodes_in_group("species_vulture").size(),
		"fish": tree.get_nodes_in_group("species_fish").size(),
		"plants": tree.get_nodes_in_group("plant").size(),
		"trees": tree.get_nodes_in_group("tree").size(),
		"nests": tree.get_nodes_in_group("nest").size(),
		"min_hydration": min_hyd,
		"drinking": drinkers,
	}


## Live cognition / genetics snapshot (proof the fast/slow brain + evolution are running).
static func cognition(w) -> Dictionary:
	var creatures: Array = w.get_tree().get_nodes_in_group("creature")
	var minds: int = 0
	var habits: int = 0
	var asked: int = 0
	var learned: int = 0
	var max_gen: int = 0
	var cues: int = 0
	var vetoed: int = 0
	for c in creatures:
		if not is_instance_valid(c) or not c.has_method("get_cognition"):
			continue
		var cog = c.get_cognition()
		if cog == null:
			continue
		minds += 1
		habits += cog.policy_size()
		asked += cog.escalations
		learned += cog.lessons
		vetoed += cog.vetoes
		for cv in cog.cue_values.values():
			if float(cv) >= 0.6:
				cues += 1
		if c.has_method("get_genome") and c.get_genome() != null:
			max_gen = maxi(max_gen, int(c.get_genome().generation))
	var sched: int = 0
	if w._ecology != null and w._ecology.has_method("cognition_scheduler"):
		var sc = w._ecology.cognition_scheduler()
		if sc != null and sc.has_method("total_calls"):
			sched = sc.total_calls()
	return {
		"minds": minds, "habits": habits, "escalations": asked, "social_lessons": learned,
		"max_generation": max_gen, "slow_brain_calls": sched, "cues_learned": cues, "vetoes": vetoed,
	}
