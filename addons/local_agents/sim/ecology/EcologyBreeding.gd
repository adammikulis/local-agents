class_name LAEcologyBreeding
extends RefCounted


const AQUATIC_BREED_FRACTION: float = 0.12    # fraction of mature adults that may spawn young each aquatic tick
const AQUATIC_BREED_MAX_PER_TICK: int = 4     # per-species per-tick bound (keeps the surge + work bounded)
const GRAZE_BIOMASS_FULL: float = 0.05        # biomass at/above which a grazer breeds at full rate (algae-rich water)
const GRAZE_BIOMASS_FLOOR: float = 0.30       # survival birth-rate multiplier in barren water (never a hard 0 → no collapse)
const GRAZE_BIOMASS_SAMPLES: int = 6          # adults sampled for the school's mean biomass (O(k), not O(adults))

const SPAWN_ENERGY_FRAC: float = 0.15
const SPAWN_ENERGY_FLOOR: float = 0.45

var _eco: LAEcologyService = null

var _cap_frame: Dictionary = {}


func setup(eco: LAEcologyService) -> void:
	_eco = eco


func species_below_cap(kind: String) -> bool:
	var frame: int = int(Engine.get_physics_frames())
	var cached: Variant = _cap_frame.get(kind)
	if cached != null and int((cached as Array)[0]) == frame:
		return bool((cached as Array)[1])
	var cfg: Dictionary = _eco._species_config(kind)
	var cap: int = int(round(float(cfg.get("pop_cap", 20)) * LAAblate.spawn_scale()))
	var members: Array = _eco.get_tree().get_nodes_in_group("species_%s" % kind)
	var below: bool = members.size() < cap
	_cap_frame[kind] = [frame, below]
	return below


func birth_child(kind: String, pa: Node3D, pb: Node3D) -> Node:
	if pa == null or not is_instance_valid(pa):
		return null
	# Breed AT the bearer's nest if it has one — young are born at home and inherit the site.
	var base_pos: Vector3 = pa.global_position
	if bool(pa.get("has_nest")) and not is_inf(float((pa.get("nest_pos") as Vector3).x)):
		base_pos = pa.get("nest_pos")
	var placed = _eco._place_on_surface(_eco._tangent_offset_point(base_pos, LASimRng.for_domain("life").randf_range(-2.0, 2.0), LASimRng.for_domain("life").randf_range(-2.0, 2.0)))
	if placed == null:
		return null
	var mate: Node3D = pb if (pb != null and is_instance_valid(pb)) else pa
	var child = _eco._instance_actor(kind, placed, _breed_genome(pa, mate))
	_inherit_nest(pa, child)
	# Record the permanent lineage in the kinship graph: the child joins its parent's family component
	# (its family_id, inherited via the genome, is that same component's label) and the mate pair bond
	# is stored. Bonds are added once here and never rewritten.
	if child != null and is_instance_valid(child):
		_eco.kinship().add_offspring(int(pa.get_instance_id()), int(child.get_instance_id()))
		if mate != pa:
			_eco.kinship().add_bond(int(pa.get_instance_id()), int(mate.get_instance_id()))
	return child


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
	# All heredity stochastics (crossover points, point mutations, indel) draw from the ONE seeded sim RNG so
	# an evolutionary run reproduces from its seed — never a bare randf().
	var rng: LASimRng = LASimRng.for_domain("life")
	var child = LADNA.crossover(ga, gb, rng)
	child.mutate(rng)
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


func _spawn_cost(pa: Node3D) -> float:
	if not ("energy" in pa) or not ("max_energy" in pa):
		return 0.0
	var maxe: float = float(pa.get("max_energy"))
	var have: float = float(pa.get("energy"))
	if maxe <= 0.0 or have < maxe * SPAWN_ENERGY_FLOOR:
		return 0.0
	var cost: float = maxe * SPAWN_ENERGY_FRAC
	pa.set("energy", maxf(0.0, have - cost))
	return cost


func _graze_food_mult(adults: Array) -> float:
	if adults.is_empty():
		return GRAZE_BIOMASS_FLOOR
	var sum_b: float = 0.0
	var n: int = mini(adults.size(), GRAZE_BIOMASS_SAMPLES)
	for i in range(n):
		var a: Node3D = adults[LASimRng.for_domain("life").randi_range(0, adults.size() - 1)] as Node3D
		if a != null and is_instance_valid(a):
			sum_b += _eco._biomass_at(a.global_position)
	var mean_b: float = sum_b / float(maxi(n, 1))
	return clampf(mean_b / GRAZE_BIOMASS_FULL, GRAZE_BIOMASS_FLOOR, 1.0)


# Produce ONE aquatic offspring for `kind`: born beside a random mature parent (nudged in the water so schools
# stay together), falling back to a valid point in the species' salinity/depth band if the parent drifted to the
# waterline. The water gate in _instance_actor rejects any point that isn't inside the sea shell.
func _birth_aquatic_one(kind: String, adults: Array, cfg: Dictionary) -> void:
	var pa: Node3D = adults[LASimRng.for_domain("life").randi_range(0, adults.size() - 1)] as Node3D
	# THE BEARER PAYS FIRST, or there is no young. Nothing else in this function ever asked where the new body
	# came from; a school could double while every one of its members was starving.
	if pa != null and is_instance_valid(pa) and _spawn_cost(pa) <= 0.0:
		return
	if pa != null and is_instance_valid(pa):
		var jitter: Vector3 = LASimRng.for_domain("life").rand_dir() * LASimRng.for_domain("life").randf_range(0.5, 2.5)
		var near: Vector3 = pa.global_position + jitter
		if _eco._is_water_pos(near):
			_eco._instance_actor(kind, near)
			return
	var wet: Vector3 = _eco._random_aquatic_point(cfg)
	if not is_nan(wet.x):
		_eco._instance_actor(kind, wet)
