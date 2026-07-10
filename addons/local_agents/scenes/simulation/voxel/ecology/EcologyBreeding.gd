class_name LAEcologyBreeding
extends RefCounted

## Reproduction / population dynamics for the living world — the parent-based breeding that keeps every
## land herd and aquatic school recovering toward its carrying capacity. Land breeding (_tick_breeding →
## _birth_one) and aquatic breeding (_tick_aquatic → _birth_aquatic_one, with the biomass food gate) both
## live here: births scale with the mature-breeder pool, are bounded by the room left under the per-species
## pop_cap, and each young inherits a crossover+mutation genome, its parent's natal nest, and its family
## line in the kinship graph. No individual appears without living parents.
##
## Owned by LAEcologyService, whose _physics_process forwards its breed/aquatic-breed ticks here. This
## module reaches back into the service for the shared state that stays on the hub — the species/land/
## aquatic rosters, get_tree, the surface + tangent placement helpers, the actor instancer, biomass reads,
## the water gate, the aquatic-point sampler and the kinship graph — so there is exactly one owner of each.
## Kept isolated because phase 2 (W-REPRO) will later dissolve _tick_breeding/_tick_aquatic wholesale.
## Explicit types only (project rule: no ':=').

# A herd that has lost members REBUILDS — births each tick scale with the number of mature breeders, so a
# thinned population recovers toward its carrying capacity (the pop_cap) instead of the old flat one-birth-
# per-species-per-tick that could never replace predation + starvation + old-age losses. Vigorous breeding
# is safe because the cap is the hard ceiling: births stop at cap, so this refills toward equilibrium but
# never explodes past it. Rates are config/const (BREED_* + per-species pop_cap), never scripted counts.
const BREED_FRACTION_PER_TICK: float = 0.16   # fraction of mature adults that may produce young each breed tick
const BREED_MAX_PER_TICK: int = 8             # bound per species per tick (keeps the work + the surge bounded)

# AQUATIC BREEDING — the de-hack that retires the old `restock` spawn-from-nowhere crutch. Every aquatic
# species now recovers the SAME way the land herds do (see _tick_breeding): parent-based reproduction bounded
# by pop_cap, so no individual appears without living parents. Young are born beside a mature parent (same
# school). GRAZERS (config diet:"grazer" / grazes_biomass:true — the web BASE, bugs+shrimp) additionally have
# their birth rate MODULATED by the BIOMASS/algae base they graze: births scale with the mean field biomass at
# the school's surface column, so the food-web bottom TRACKS primary production (algae-rich water multiplies the
# base; barren water only trickles) while the fish/birds keep foraging them. The per-species pop_cap stays the
# hard ceiling; grazes_biomass is the food gate. No per-species code — the flag + pop_cap drive it. Initial
# founding stock is seeded once by stock_initial_aquatic(); this refills toward equilibrium, never past cap.
const AQUATIC_BREED_FRACTION: float = 0.12    # fraction of mature adults that may spawn young each aquatic tick
const AQUATIC_BREED_MAX_PER_TICK: int = 4     # per-species per-tick bound (keeps the surge + work bounded)
const GRAZE_BIOMASS_FULL: float = 0.05        # biomass at/above which a grazer breeds at full rate (algae-rich water)
const GRAZE_BIOMASS_FLOOR: float = 0.30       # survival birth-rate multiplier in barren water (never a hard 0 → no collapse)
const GRAZE_BIOMASS_SAMPLES: int = 6          # adults sampled for the school's mean biomass (O(k), not O(adults))

var _eco: LAEcologyService = null


func setup(eco: LAEcologyService) -> void:
	_eco = eco


func _tick_breeding() -> void:
	for kind in _eco._land_kinds():
		var cfg: Dictionary = _eco._species_config(kind)
		var cap: int = int(round(float(cfg.get("pop_cap", 20)) * LAAblate.spawn_scale()))   # LA_SPAWN_SCALE benchmark knob (1.0 unless set)
		var group: String = "species_%s" % kind
		var members: Array = _eco.get_tree().get_nodes_in_group(group)
		var deficit: int = cap - members.size()
		if members.size() < 2 or deficit <= 0:
			continue
		# count mature adults
		var adults: Array = []
		for m in members:
			if is_instance_valid(m) and m.has_method("is_mature") and m.is_mature():
				adults.append(m)
		if adults.size() < 2:
			continue
		# Births this tick scale with the breeder pool, bounded by the room left under the cap and a hard
		# per-tick ceiling — so a depleted herd rebuilds quickly while a full one stops breeding entirely.
		var births: int = clampi(int(ceil(float(adults.size()) * BREED_FRACTION_PER_TICK)), 1, mini(deficit, BREED_MAX_PER_TICK))
		for i in range(births):
			_birth_one(kind, adults)


# Produce ONE offspring for `kind` from two random mature parents in `adults`: crossover genome + mutation,
# born at a parent's nest (natal philopatry) and recorded in the kinship graph. Factored out of the breed
# loop so a recovering herd can birth several young per tick through the same evolution + lineage path.
func _birth_one(kind: String, adults: Array) -> void:
	var pa: Node3D = adults[randi() % adults.size()] as Node3D
	var pb: Node3D = adults[randi() % adults.size()] as Node3D
	var guard: int = 0
	while pb == pa and guard < 4:
		pb = adults[randi() % adults.size()] as Node3D
		guard += 1
	# Breed AT a parent's nest if it has one — young are born at home and inherit the site.
	var base_pos: Vector3 = pa.global_position
	if bool(pa.get("has_nest")) and not is_inf(float((pa.get("nest_pos") as Vector3).x)):
		base_pos = pa.get("nest_pos")
	var placed = _eco._place_on_surface(_eco._tangent_offset_point(base_pos, randf_range(-2.0, 2.0), randf_range(-2.0, 2.0)))
	if placed == null:
		return
	var child = _eco._instance_actor(kind, placed, _breed_genome(pa, pb))
	_inherit_nest(pa, child)
	# Record the permanent lineage in the kinship graph: the child joins its parent's family component
	# (its family_id, inherited via the genome, is that same component's label) and the mate pair bond
	# is stored. Bonds are added once here and never rewritten.
	if child != null and is_instance_valid(child):
		_eco.kinship().add_offspring(int(pa.get_instance_id()), int(child.get_instance_id()))
		_eco.kinship().add_bond(int(pa.get_instance_id()), int(pb.get_instance_id()))


# Natal philopatry: the offspring adopts a parent's home site, so kin CLUSTER in space over
# generations — which makes vision/sound social learning spread fastest among relatives (culture).
func _inherit_nest(parent, child) -> void:
	if child == null or not is_instance_valid(child):
		return
	if not bool(parent.get("has_nest")):
		return
	var np: Vector3 = parent.get("nest_pos")
	if is_inf(np.x):
		return
	child.set("nest_pos", np)
	child.set("has_nest", true)
	var nn = parent.get("_nest_node")
	if nn != null and is_instance_valid(nn) and nn.has_method("register_young"):
		nn.register_young()


# Build a child genome from two parents: rare Baldwin canalization of each parent's deepest lifelong
# habits into the germline, then crossover + mutation. The child inherits one parent's family line so
# kin preferentially learn from each other. Returns null (→ ancestral genome) if parents lack genomes.
func _breed_genome(pa, pb):
	var ga = pa.get_genome() if pa.has_method("get_genome") else null
	var gb = pb.get_genome() if pb.has_method("get_genome") else null
	if ga == null or gb == null:
		return null
	if pa.has_method("get_cognition") and pa.get_cognition() != null:
		ga.maybe_canalize(pa.get_cognition().policy)
	if pb.has_method("get_cognition") and pb.get_cognition() != null:
		gb.maybe_canalize(pb.get_cognition().policy)
	var child = LAGenome.crossover(ga, gb)
	child.mutate()
	# The child's family_id is its parent's connected-component label, sourced from the kinship graph (which
	# equals pa's stable family_id, since components never merge). The parent→child edge itself is recorded at
	# the breeding call site once the child node exists.
	child.base_config["family_id"] = _eco.kinship().family_of(int(pa.get_instance_id()))
	return child


func _tick_aquatic() -> void:
	for kind in _eco._aquatic_kinds():
		var cfg: Dictionary = _eco._species_config(String(kind))
		var cap: int = int(round(float(cfg.get("pop_cap", 12)) * LAEcologyService.AQUATIC_STOCK_MULT * LAAblate.spawn_scale()))
		var members: Array = _eco.get_tree().get_nodes_in_group("species_%s" % String(kind))
		var deficit: int = cap - members.size()
		if members.size() < 2 or deficit <= 0:
			continue
		var adults: Array = []
		for m in members:
			if is_instance_valid(m) and m.has_method("is_mature") and m.is_mature():
				adults.append(m)
		if adults.size() < 2:
			continue
		# Food gate: a grazer's birth rate rides the biomass base it grazes (mean over a cheap sample of the school).
		var food_mult: float = 1.0
		if bool(cfg.get("grazes_biomass", false)):
			food_mult = _graze_food_mult(adults)
		var births: int = clampi(int(ceil(float(adults.size()) * AQUATIC_BREED_FRACTION * food_mult)), 1, mini(deficit, AQUATIC_BREED_MAX_PER_TICK))
		for i in range(births):
			_birth_aquatic_one(String(kind), adults, cfg)


# Birth-rate multiplier (∈ [GRAZE_BIOMASS_FLOOR, 1]) for a grazer school from the biomass base it feeds on —
# the mean surface biomass at a cheap random sample of its adults. Rich algae water → full rate; barren water →
# the survival floor (so the base tracks primary production without ever collapsing to zero and starving the web).
func _graze_food_mult(adults: Array) -> float:
	if adults.is_empty():
		return GRAZE_BIOMASS_FLOOR
	var sum_b: float = 0.0
	var n: int = mini(adults.size(), GRAZE_BIOMASS_SAMPLES)
	for i in range(n):
		var a: Node3D = adults[randi() % adults.size()] as Node3D
		if a != null and is_instance_valid(a):
			sum_b += _eco._biomass_at(a.global_position)
	var mean_b: float = sum_b / float(maxi(n, 1))
	return clampf(mean_b / GRAZE_BIOMASS_FULL, GRAZE_BIOMASS_FLOOR, 1.0)


# Produce ONE aquatic offspring for `kind`: born beside a random mature parent (nudged in the water so schools
# stay together), falling back to a valid point in the species' salinity/depth band if the parent drifted to the
# waterline. The water gate in _instance_actor rejects any point that isn't inside the sea shell.
func _birth_aquatic_one(kind: String, adults: Array, cfg: Dictionary) -> void:
	var pa: Node3D = adults[randi() % adults.size()] as Node3D
	if pa != null and is_instance_valid(pa):
		var jitter: Vector3 = Vector3(randf() * 2.0 - 1.0, randf() * 2.0 - 1.0, randf() * 2.0 - 1.0) * randf_range(0.5, 2.5)
		var near: Vector3 = pa.global_position + jitter
		if _eco._is_water_pos(near):
			_eco._instance_actor(kind, near)
			return
	var wet: Vector3 = _eco._random_aquatic_point(cfg)
	if not is_nan(wet.x):
		_eco._instance_actor(kind, wet)
