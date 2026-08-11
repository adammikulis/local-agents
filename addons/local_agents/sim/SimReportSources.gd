class_name LASimReportSources
extends RefCounted

## Telemetry providers for LASimReport: pull population + cognition aggregates from the live tree at snapshot
## time (registered once in VoxelWorld, so these scans run only when a report is taken, not per frame). Static
## + dependency-free of the concrete node types (dynamic access). This is where the old hand-synced
## SMOKE_SUMMARY computation moved to, so each subsystem owns its slice of SIM_REPORT. (Explicit types only.)


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
		"pollinations": LAVegLedger.of(w._material).pollinations,
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
	var anim_stride_sum: int = 0
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
	const REPORTED_GENES: Array = ["size", "speed", "respiratory_capacity", "thermogenesis", "carnivory", "neophobia", "boldness", "scent_acuity", "taste_sensitivity", "constitution", "display"]
	var gene_sum: Dictionary = {}
	for gk in REPORTED_GENES:
		gene_sum[gk] = 0.0
	var gene_pop: int = 0
	# ALLOMETRY, MEASURED RATHER THAN ASSERTED. Per species: body mass, the REALISED oxidation rate the
	# substrate actually granted (LACreatureRespiration._resp_rate, which is what survived the oxygen Liebig
	# cap and the temperature band), and body temperature.
	#
	# THIS IS AN INSTRUMENT, AND IT IS THE POINT OF THE WHOLE PHYSIOLOGY. Both inputs are things the run did:
	# the mass is the species' MEASURED `mass_kg` and the rate is what each body actually burned this tick.
	# Neither is derived from an exponent, so the slope cannot read back its own assumption. That property is
	# fragile and worth protecting — the alternative physiology this replaced set `basal_rate` to
	# `BASAL_COEFF * mass^KLEIBER_EXPONENT`, and a fit over THAT can only ever return the 0.75 somebody typed
	# in, which is a gauge that cannot fail. If a future change makes this tautological, delete the gauge
	# rather than ship one that measures its own input.
	#
	# WHAT THE NUMBER MEANS. ~0.667 is RUBNER'S SURFACE LAW: it is what pure surface-area-to-volume geometry
	# produces when a body's oxygen has to cross one exchange surface, which is all this substrate has. Real
	# animals measure ~0.75 (Kleiber 1932; Savage et al. 2004 across 600+ species), and the leading explanation
	# is a fractal nutrient-delivery network — space-filling branching vasculature with size-invariant terminal
	# units (West, Brown & Enquist 1997). THIS SUBSTRATE HAS NO VASCULATURE. That is why it reads 2/3, and why
	# typing 3/4 in anywhere would be asserting machinery that does not exist.
	#
	# SO 2/3 IS NOT A DISCREPANCY TO FIX, IT IS A READING TO WATCH. Give creatures a real circulatory system —
	# branching transport, terminal units that do not scale with the body — and this gauge should climb toward
	# 0.75 ON ITS OWN. That climb is the evidence the mechanism is real rather than declared, and it is the
	# only kind of evidence worth having. Measured on the size-derived masses that preceded this: 0.660 /
	# 0.666 / 0.656. The exponent is then fitted across species by
	# ordinary least squares on log(rate) against log(mass) — so the scaling law is an OUTPUT of the run.
	# Nothing anywhere types in 0.75 or 0.667; if the exponent moves, the physics moved.
	# Three is enough for the CAPACITY fit and five was actively harmful: at 600 frames only the five largest-
	# population species clear n>=5, which throws away the whole small end of the roster and cuts the fit's mass
	# lever arm from 420x to 38x. The slope then swings 0.43-0.65 run to run on noise. Capacity is a geometric
	# quantity with little behavioural variance, so a species mean over three individuals is a real measurement.
	const METAB_FIT_MIN_N: int = 3
	# ALLELE SPLIT — does a gene actually DRIVE anything? For each of the two respiratory loci, creatures are
	# bucketed by whether they carry an above- or below-median allele, and each bucket reports the metabolic
	# rate NORMALISED BY mass^(2/3). That normalisation is the point: raw rate is dominated by body size, so
	# dividing by the surface-scaling term leaves the gene's own contribution visible. If a locus is dead —
	# which is exactly what `basal_metabolism` and `active_metabolism` were — its two buckets read the same.
	# The split is the population MEDIAN of each locus, not a fixed constant: a fixed threshold puts the entire
	# population in one bucket whenever the locus has not drifted past it, which reports "no effect" for a gene
	# that simply has not varied yet. Collected here, bucketed after the loop.
	var resp_vals: Array = []
	var thermo_vals: Array = []
	var norm_vals: Array = []
	var btemp_vals: Array = []
	var mass_by_sp: Dictionary = {}
	var rate_by_sp: Dictionary = {}
	var btemp_by_sp: Dictionary = {}
	var cap_by_sp: Dictionary = {}
	var n_by_sp: Dictionary = {}
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
		# Same O(N) pass — no extra population scan (big-O discipline).
		# LAFish shares the cognition stack but is a separate class with its own energy path and no body-temp /
		# respiration state, so it has no `_resp_rate` to report. Skip it rather than fake a zero, which would
		# drag the fitted exponent toward nothing.
		var sp: String = String(c.get("species"))
		if sp != "" and c.get("_resp_rate") != null:
			n_by_sp[sp] = int(n_by_sp.get(sp, 0)) + 1
			mass_by_sp[sp] = float(mass_by_sp.get(sp, 0.0)) + LACreatureRespiration.body_mass(c)
			rate_by_sp[sp] = float(rate_by_sp.get(sp, 0.0)) + float(c.get("_resp_rate"))
			btemp_by_sp[sp] = float(btemp_by_sp.get(sp, 0.0)) + float(c.get("body_temp"))
			cap_by_sp[sp] = float(cap_by_sp.get(sp, 0.0)) + float(c.get("_resp_capacity"))
			# Mass-normalised rate: divide out the surface-scaling term so what remains is the allele's own effect.
			var cm: float = LACreatureRespiration.body_mass(c)
			resp_vals.append(float(c.get("respiratory_capacity")))
			thermo_vals.append(float(c.get("thermogenesis")))
			# Normalise the AEROBIC CAPACITY, not the realised rate. Capacity is what the gene acts on; the
			# realised rate additionally carries whether this particular animal was asleep, fleeing or starving,
			# and that behavioural variance is several times the size of an 8% allele difference — measured, the
			# realised-rate split swung 0.90x to 1.42x run to run on a locus whose true effect is ~1.09x.
			norm_vals.append(float(c.get("_resp_capacity")) / maxf(pow(cm, 2.0 / 3.0), 1e-6))
			btemp_vals.append(float(c.get("body_temp")))
		anim_stride_sum += int(c.get("_anim_stride"))
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
	# Fit log(rate) = a + b*log(mass) across the species present. `b` IS the emergent metabolic scaling
	# exponent: 1.0 would mean rate tracks mass (no allometry at all, which is what this simulation did before
	# — a fox and a mouse burned the same), 2/3 is Rubner's surface law, 3/4 is Kleiber's. Species with a dead
	# or unmeasured rate are skipped so a torpid outlier cannot fake a slope.
	var metab: Dictionary = {}
	var sx: float = 0.0
	var sy: float = 0.0
	var sxx: float = 0.0
	var sxy: float = 0.0
	var sn: int = 0
	for sp in n_by_sp.keys():
		var n: float = float(int(n_by_sp[sp]))
		var m: float = float(mass_by_sp[sp]) / n
		var r: float = float(rate_by_sp[sp]) / n
		metab[sp] = {"n": int(n), "mass": snappedf(m, 0.001), "rate": snappedf(r, 0.0001),
			"cap": snappedf(float(cap_by_sp[sp]) / n, 0.0001),
			# Capacity divided by the surface-scaling term. If metabolic capacity really goes as mass^(2/3),
			# THIS COLUMN IS CONSTANT across the roster — which is a far more legible test of the scaling law
			# than any single fitted slope, because a reader can see it hold species by species.
			"cap_norm": snappedf(float(cap_by_sp[sp]) / n / maxf(pow(m, 2.0 / 3.0), 1e-6), 0.0001),
			"body_c": snappedf(float(btemp_by_sp[sp]) / n, 0.01)}
		# A species down to its last two individuals is a sample, not a measurement: with n=2 a single fleeing
		# animal (exertion 1.6x) or a single starved one (rate 0) moves that species' whole point, and the
		# low-mass end of this roster is exactly where the small populations are. Require a real sample.
		if m > 0.0 and r > 0.0 and n >= float(METAB_FIT_MIN_N):
			var lx: float = log(m)
			var ly: float = log(r)
			sx += lx
			sy += ly
			sxx += lx * lx
			sxy += lx * ly
			sn += 1
	var expo: float = 0.0
	var cap_expo: float = _fit_exponent(n_by_sp, mass_by_sp, cap_by_sp, METAB_FIT_MIN_N)
	if sn >= 2:
		var den: float = float(sn) * sxx - sx * sx
		if absf(den) > 1e-9:
			expo = (float(sn) * sxy - sx * sy) / den
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
		"metab": metab, "metab_exponent": snappedf(expo, 0.001), "metab_species": sn,
		"metab_capacity_exponent": snappedf(cap_expo, 0.001),
		"allele": {
			"resp": _allele_split(resp_vals, norm_vals, btemp_vals),
			"thermo": _allele_split(thermo_vals, norm_vals, btemp_vals),
		},
		"anim_stride_avg": snappedf(float(anim_stride_sum) / float(maxi(minds, 1)), 0.01),
		"bird_display": snappedf(bird_display_sum / float(maxi(bird_n, 1)), 0.001),
	}


## Split the population at a locus's MEDIAN and report what each half's metabolism looks like. Returns the
## two bucket means plus the ratio between them, which is the number that answers "does this gene do
## anything": 1.00 means the locus is inert, anything else means it reaches behaviour.
##
## `norm_rate` is the metabolic rate divided by mass^(2/3) — body size divided out, so what is left is the
## allele's own contribution rather than the fact that big animals burn more. This is the measurement
## `basal_metabolism` and `active_metabolism` would have failed for their entire existence: they were declared,
## encoded, expressed, and read by nothing, so their two halves were bound to be identical.
static func _allele_split(gene: Array, norm: Array, btemp: Array) -> Dictionary:
	var n: int = gene.size()
	if n < 4:
		return {}
	var sorted_g: Array = gene.duplicate()
	sorted_g.sort()
	var median: float = float(sorted_g[n / 2])
	var hi_n: int = 0
	var lo_n: int = 0
	var hi_g: float = 0.0
	var lo_g: float = 0.0
	var hi_r: float = 0.0
	var lo_r: float = 0.0
	var hi_t: float = 0.0
	var lo_t: float = 0.0
	for i in range(n):
		if float(gene[i]) > median:
			hi_n += 1
			hi_g += float(gene[i])
			hi_r += float(norm[i])
			hi_t += float(btemp[i])
		elif float(gene[i]) < median:
			lo_n += 1
			lo_g += float(gene[i])
			lo_r += float(norm[i])
			lo_t += float(btemp[i])
	if hi_n == 0 or lo_n == 0:
		# The locus is monomorphic in the living population — no standing variation to measure, which is a
		# statement about the gene pool and not about whether the gene is read.
		return {"monomorphic": true, "value": snappedf(median, 0.001), "n": n}
	var hr: float = hi_r / float(hi_n)
	var lr: float = lo_r / float(lo_n)
	return {
		"hi_n": hi_n, "lo_n": lo_n,
		"hi_gene": snappedf(hi_g / float(hi_n), 0.001), "lo_gene": snappedf(lo_g / float(lo_n), 0.001),
		"hi_rate": snappedf(hr, 0.0001), "lo_rate": snappedf(lr, 0.0001),
		"rate_ratio": snappedf(hr / lr, 0.001) if lr > 0.0 else 0.0,
		"hi_body_c": snappedf(hi_t / float(hi_n), 0.01), "lo_body_c": snappedf(lo_t / float(lo_n), 0.01),
	}


## Ordinary least squares on log(y) against log(mass), across species with a real sample. Shared by the field
## metabolic rate and the aerobic capacity so both exponents are fitted the same way.
static func _fit_exponent(n_by_sp: Dictionary, mass_by_sp: Dictionary, y_by_sp: Dictionary, min_n: int) -> float:
	var sx: float = 0.0
	var sy: float = 0.0
	var sxx: float = 0.0
	var sxy: float = 0.0
	var k: int = 0
	for sp in n_by_sp.keys():
		var n: float = float(int(n_by_sp[sp]))
		if n < float(min_n):
			continue
		var m: float = float(mass_by_sp[sp]) / n
		var y: float = float(y_by_sp.get(sp, 0.0)) / n
		if m <= 0.0 or y <= 0.0:
			continue
		var lx: float = log(m)
		var ly: float = log(y)
		sx += lx
		sy += ly
		sxx += lx * lx
		sxy += lx * ly
		k += 1
	if k < 2:
		return 0.0
	var den: float = float(k) * sxx - sx * sx
	return (float(k) * sxy - sx * sy) / den if absf(den) > 1e-9 else 0.0
