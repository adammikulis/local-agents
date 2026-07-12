class_name LAEcologyPlants
extends RefCounted

## Vegetation seeding for the living world — the per-tick spread of plants (generic plant, flowers, shrubs)
## and forest succession (trees). Seed-ready plants sow their own kind into their neighbourhood bounded by
## that kind's pop_cap; existing trees standing on biomass-rich ground drop seedlings so groves densify on
## the warm fertile continents the photosynthesis chemistry made most productive. Every germination passes
## the emergent treeline gate (warm, snow-free ground) so cold/polar/coastal margins stay bare — vegetation
## is a consequence of the climate + chemistry, not a placement table.
##
## Owned by LAEcologyService, whose _physics_process forwards its plant/tree seeding ticks here. This module
## reaches back into the service for the shared state that stays on the hub — get_tree, the veg config, the
## surface + tangent placement helpers, the germination gate, the actor instancer, biomass reads and the
## water gate — so there is exactly one owner of each. Explicit types only (project rule: no ':=').

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
		if LASimRng.shared().randf() > 0.7:
			continue                                # most seed-ready plants spread each tick → pasture densifies
		var placed = _eco._place_on_surface(_eco._tangent_offset_point((p as Node3D).global_position, LASimRng.shared().randf_range(-3.5, 3.5), LASimRng.shared().randf_range(-3.5, 3.5)))
		if placed != null and _eco._can_grow_here(placed):
			_eco._instance_actor(kind, placed)      # seed only takes on warm, snow-free ground (emergent treeline)
		if p.has_method("consume"):
			p.consume()


# FOREST SUCCESSION — the emergent grove-builder. Each tick a few existing trees standing on biomass-rich
# ground drop a seedling into their tangent neighbourhood, but ONLY where the local biomass the photosynthesis
# chemistry has fixed clears an adaptive threshold (a fraction of the richest grove's biomass). So forests
# THICKEN on the warm fertile continents that grew the most biomass, spread out from existing trees (groves,
# not scatter), and stall at cold/snowy/coastal margins where biomass never crosses the bar or the treeline
# gate blocks germination. Forests are a consequence of the chemistry, not a placement table.
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
		var parent: Node3D = trees[LASimRng.shared().randi_range(0, trees.size() - 1)] as Node3D
		if not is_instance_valid(parent) or _eco._biomass_at(parent.global_position) < thresh:
			continue                                # parent isn't on rich enough ground to spread a grove
		seeded += 1
		var placed = _eco._place_on_surface(_eco._tangent_offset_point(parent.global_position, LASimRng.shared().randf_range(-TREE_SEED_SPREAD, TREE_SEED_SPREAD), LASimRng.shared().randf_range(-TREE_SEED_SPREAD, TREE_SEED_SPREAD)))
		if placed == null or _eco._is_water_pos(placed) or not _eco._can_grow_here(placed):
			continue                                # off the treeline / into the sea — the grove's edge
		if _eco._biomass_at(placed) < thresh:
			continue                                # seedling site not fertile enough — keeps groves dense, not scattered
		_eco._instance_actor("tree", placed)
		if _eco.get_tree().get_nodes_in_group("tree").size() >= TREE_POP_CAP:
			return
