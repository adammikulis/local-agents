class_name LAEcologyPlants
extends RefCounted


const SEED_RESERVE_COST: float = 1.0
static var seed_cost_total: float = 0.0   # cumulative parent reserve spent on germination (SIM_REPORT)

var _eco: LAEcologyService = null


func setup(eco: LAEcologyService) -> void:
	_eco = eco


func _tick_plant_seeding() -> void:
	var plants: Array = _eco.get_tree().get_nodes_in_group("plant")
	for p in plants:
		if not is_instance_valid(p):
			continue
		if not (p.has_method("has_seed") and p.has_seed()):
			continue
		# A seed-ready plant spreads its OWN kind (generic plant, flower, or shrub) into its neighbourhood,
		# bounded by THAT kind's pop_cap — so flowers beget flowers (only while pollinated, via has_seed) and
		# each vegetation type self-limits. No type-branch: the kind + cap come from the parent + its data file.
		var kind: String = String(p.species) if "species" in p else "plant"
		var cap: int = int(_eco._veg_config(kind).get("pop_cap", 120))
		if _eco.get_tree().get_nodes_in_group("species_%s" % kind).size() >= cap:
			if p.has_method("consume"):
				p.consume()                         # at cap: consume the seed so it re-readies later
			continue
		if LASimRng.for_domain("life").randf() > 0.7:
			continue                                # most seed-ready plants spread each tick → pasture densifies
		var paid: float = 0.0
		if p.has_method("feed"):
			paid = float(p.feed(SEED_RESERVE_COST))
		if paid < SEED_RESERVE_COST:
			if paid > 0.0 and p.has_method("credit_reserve"):
				p.credit_reserve(paid)              # could not afford a whole seed — give the part back
			if p.has_method("consume"):
				p.consume()
			continue
		seed_cost_total += paid * LAPlant.BIOMASS_PER_FOOD   # booked in the FIELD's mass units, like the rest
		var placed = _eco._place_on_surface(_eco._tangent_offset_point((p as Node3D).global_position, LASimRng.for_domain("life").randf_range(-3.5, 3.5), LASimRng.for_domain("life").randf_range(-3.5, 3.5)))
		var child = null
		if placed != null and _eco._can_grow_here(placed):
			child = _eco._instance_actor(kind, placed)  # seed only takes on warm, snow-free ground (emergent treeline)
		if child != null and child.has_method("credit_reserve"):
			child.credit_reserve(paid)              # the seedling IS the mass its parent invested
		elif p.has_method("credit_reserve"):
			p.credit_reserve(paid)                  # nowhere to germinate — the parent keeps its investment
		if p.has_method("consume"):
			p.consume()


const TREE_POP_CAP: int = 400               # forest carrying capacity (well above the initial seed count)
const TREE_SEED_BIOMASS_FRAC: float = 0.35  # seed only onto ground with >= this fraction of the richest grove's biomass
const TREE_SEED_FLOOR: float = 0.04         # absolute biomass floor so bare/cold ground never seeds
const TREE_SEED_SPREAD: float = 8.0         # how far a seedling lands from its parent (grove tightness, metres)
const TREE_SEEDS_PER_TICK: int = 10         # parents that attempt to seed per tick (bounded work — big-O by tick, not grid)
func _tick_tree_seeding() -> void:
	var trees: Array = _eco.get_tree().get_nodes_in_group("tree")
	if trees.is_empty() or trees.size() >= TREE_POP_CAP:
		return
	# The richest grove's biomass sets an ADAPTIVE bar (self-scales to whatever the chemistry produces), so
	# the forest advances onto ground within TREE_SEED_BIOMASS_FRAC of the best fertility.
	var peak: float = 0.0
	for t in trees:
		if is_instance_valid(t):
			peak = maxf(peak, _eco._biomass_at((t as Node3D).global_position))
	var thresh: float = maxf(TREE_SEED_FLOOR, peak * TREE_SEED_BIOMASS_FRAC)
	var seeded: int = 0
	var guard: int = 0
	while seeded < TREE_SEEDS_PER_TICK and guard < TREE_SEEDS_PER_TICK * 4:
		guard += 1
		var parent: Node3D = trees[LASimRng.for_domain("life").randi_range(0, trees.size() - 1)] as Node3D
		if not is_instance_valid(parent) or _eco._biomass_at(parent.global_position) < thresh:
			continue                                # parent isn't on rich enough ground to spread a grove
		seeded += 1
		var placed = _eco._place_on_surface(_eco._tangent_offset_point(parent.global_position, LASimRng.for_domain("life").randf_range(-TREE_SEED_SPREAD, TREE_SEED_SPREAD), LASimRng.for_domain("life").randf_range(-TREE_SEED_SPREAD, TREE_SEED_SPREAD)))
		if placed == null or _eco._is_water_pos(placed) or not _eco._can_grow_here(placed):
			continue                                # off the treeline / into the sea — the grove's edge
		if _eco._biomass_at(placed) < thresh:
			continue                                # seedling site not fertile enough — keeps groves dense, not scattered
		_eco._instance_actor("tree", placed)
		if _eco.get_tree().get_nodes_in_group("tree").size() >= TREE_POP_CAP:
			return
