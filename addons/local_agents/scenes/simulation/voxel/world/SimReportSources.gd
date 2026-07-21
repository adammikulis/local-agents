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
		# Aquatic web BASE (grazers) — should persist by grazing biomass now, not by restock.
		"bug": tree.get_nodes_in_group("species_bug").size(),
		"shrimp": tree.get_nodes_in_group("species_shrimp").size(),
		# Land invertebrate base + pollinators.
		"beetle": tree.get_nodes_in_group("species_beetle").size(),
		"ant": tree.get_nodes_in_group("species_ant").size(),
		"grasshopper": tree.get_nodes_in_group("species_grasshopper").size(),
		"butterfly": tree.get_nodes_in_group("species_butterfly").size(),
		"fly": tree.get_nodes_in_group("species_fly").size(),
		"bee": tree.get_nodes_in_group("species_bee").size(),
		# Flowers + a running count of pollination visits (bee-activity proxy) — flower spread should track it.
		"flowers": tree.get_nodes_in_group("species_flower_daisy").size() + tree.get_nodes_in_group("species_flower_clover").size(),
		"pollinations": LAPlant.pollination_events,
		"min_hydration": min_hyd,
		"drinking": drinkers,
	}


## Live DISEASE / immune snapshot (proof outbreaks spread, cull, and leave immune survivors). One O(N) scan at
## report time: how many creatures carry an active infection, how many are symptomatic, how many hold acquired
## immunity, and the total pathogen burden — plus a per-strain infected count so a specific plague is visible.
static func disease(w) -> Dictionary:
	var creatures: Array = w.get_tree().get_nodes_in_group("creature")
	var infected: int = 0
	var sick: int = 0
	var immune: int = 0
	var burden: float = 0.0
	var per_strain: Dictionary = {}
	for c in creatures:
		if not is_instance_valid(c) or c.get("disease") == null:
			continue
		var dz = c.disease
		if not dz.immunity.is_empty():
			immune += 1
		if dz.loads.is_empty():
			continue
		infected += 1
		if dz.infectiousness() > 0.0:
			sick += 1
		for sid in dz.loads.keys():
			burden += float((dz.loads[sid] as Dictionary)["load"])
			per_strain[sid] = int(per_strain.get(sid, 0)) + 1
	return {
		"infected": infected, "sick": sick, "immune": immune,
		"pathogen_burden": snappedf(burden, 0.01), "strains": per_strain,
	}


## Live cognition / genetics snapshot (proof the fast/slow brain + evolution are running).
static func cognition(w) -> Dictionary:
	var creatures: Array = w.get_tree().get_nodes_in_group("creature")
	var minds: int = 0
	var males: int = 0
	var bird_display_sum: float = 0.0
	var bird_n: int = 0
	var habits: int = 0
	var asked: int = 0
	var learned: int = 0
	var max_gen: int = 0
	var cues: int = 0
	var aversions: int = 0    # learned AVERSIONS: cue values driven to/below the food-avoid threshold (toxin/danger
	                          # learning, which cues_learned's positive-only count can't see). Proves affinity's aversive half.
	var vetoed: int = 0
	var learners: int = 0     # creatures with >=1 learned policy OR cue entry (learning-spread numerator)
	# Population gene means — the evolvable loci whose drift makes SELECTION observable (a toxin-heavy pasture
	# should push neophobia up over generations, predation should push speed up, etc.). Accumulated in THIS same
	# O(N) pass — no second population scan (big-O discipline). decode_gene() is the raw locus value.
	const REPORTED_GENES: Array = ["size", "speed", "metabolism", "carnivory", "neophobia", "boldness", "scent_acuity", "taste_sensitivity", "constitution", "display"]
	var gene_sum: Dictionary = {}
	for gk in REPORTED_GENES:
		gene_sum[gk] = 0.0
	var gene_pop: int = 0
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
		if cog.policy_size() > 0 or cog.cue_values.size() > 0:
			learners += 1
		for cv in cog.cue_values.values():
			if float(cv) >= 0.6:
				cues += 1
			elif float(cv) <= -0.4:
				aversions += 1
		if bool(c.get("is_male")):
			males += 1
		# Bird-only display mean: birds court on ornament (dominance_traits.display), so if sexual selection is
		# working this rises over generations while the population-wide display mean (diluted by the other
		# species, which do not weight display) stays flat. A cheap, targeted read of the selection signal.
		if String(c.get("species")) == "bird" and c.has_method("get_genome") and c.get_genome() != null:
			var bg = c.get_genome()
			if bg.has_method("decode_gene"):
				bird_display_sum += bg.decode_gene("display")
				bird_n += 1
		if c.has_method("get_genome") and c.get_genome() != null:
			var gen = c.get_genome()
			max_gen = maxi(max_gen, int(gen.generation))
			if gen.has_method("decode_gene"):
				gene_pop += 1
				for gk in REPORTED_GENES:
					gene_sum[gk] += gen.decode_gene(gk)
	var genes: Dictionary = {}
	if gene_pop > 0:
		for gk in REPORTED_GENES:
			genes[gk] = snappedf(gene_sum[gk] / float(gene_pop), 0.001)
	var sched: int = 0
	if w._ecology != null and w._ecology.has_method("cognition_scheduler"):
		var sc = w._ecology.cognition_scheduler()
		if sc != null and sc.has_method("total_calls"):
			sched = sc.total_calls()
	return {
		"minds": minds, "habits": habits, "escalations": asked, "social_lessons": learned,
		"max_generation": max_gen, "slow_brain_calls": sched, "cues_learned": cues, "vetoes": vetoed,
		"aversions": aversions, "learners": learners,
		"genes": genes, "gene_pop": gene_pop, "males": males,
		"bird_display": snappedf(bird_display_sum / float(maxi(bird_n, 1)), 0.001),
	}
