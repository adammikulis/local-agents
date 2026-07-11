class_name LAPopulationGovernor
extends Node

## The population governor — the "smite" cap that keeps the living world inside the frame-rate budget.
## Too many minds is too much compute (every creature thinks, senses, digests), so when the animal count
## climbs past a ceiling the governor seeds an emergent culling FLOOD at the DENSEST cluster of animals.
##
## It does NOT kill anyone directly. It pours water where life is thickest; drowning (non-flyers caught in
## deep water), panic, and dispersal to high ground all EMERGE from the flood's own water CA — the same seed
## the player's flood brush uses. Old-testament by design: when the world overflows its budget, the waters
## rise over the crowded lowlands and thin the herd back to a playable number, while birds and animals on
## high ground survive. No per-species logic, no scripted deaths — one ceiling, one seed, physics does the rest.
##
## Config over cases (project rule): a single ceiling + hysteresis band drives it; a denser cluster floods a
## wider footprint because that is where the cull is needed. Big-O: the census + density peak are one O(n)
## bucket pass on a slow cadence, never per-frame per-pair. Owned by VoxelWorld (a one-line add_child); it
## self-ticks and reaches the ecology service for the flood seed. Explicit types only (no ':=').

const FloodScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Flood.gd")

# The ceiling is the compute budget expressed as a head-count. Above ABS_FLOOR the world is genuinely
# crowded (frame-rate territory); a world that FOUNDED large (sandbox) tolerates growth to CEILING_MULT of
# its founding population before the waters come. The effective ceiling is the max of the two, so campaign
# (12 founders, the player nurturing growth) is never smited until the count is genuinely large, while a
# teeming sandbox smites proportional to what it started with. Override with LA_POP_CEILING for tuning/tests.
const ABS_FLOOR: int = 350
const CEILING_MULT: float = 1.6
# Hysteresis: once smited, hold off until the count falls back under ceiling*RELIEF before considering another
# — so one flood is given time to work instead of re-flooding every cadence while the water is still rising.
const RELIEF: float = 0.85
const CHECK_PERIOD: float = 2.0          # seconds between censuses (cheap, but no need to run per-frame)
const COOLDOWN: float = 9.0              # seconds after a smite before the next can fire (let the flood act)
# Density bucketing + flood sizing. Creatures are hashed into BUCKET_CELL-sized cells; the fullest cell is
# the smite target. The flood footprint grows with how many crowd that cell (a bigger mob → a bigger deluge).
const BUCKET_CELL: float = 28.0
const FLOOD_MIN_RADIUS: float = 10.0
const FLOOD_PER_HEAD: float = 0.9        # footprint radius added per animal in the target cell

var _ecology = null                      # LAEcologyService — Flood.setup(terrain, ecology); provides scare/field
var _terrain = null
var _actors_root: Node3D = null

var _baseline: int = -1                  # founding animal count, latched on the first census (auto-scales the cap)
var _ceiling: int = ABS_FLOOR
var _check_cd: float = 0.0
var _cooldown: float = 0.0
var _armed: bool = true                  # false after a smite until the count relieves back under ceiling*RELIEF
var _enabled: bool = true


func setup(ecology, terrain, actors_root: Node3D) -> void:
	_ecology = ecology
	_terrain = terrain
	_actors_root = actors_root
	# Opt-out for headless perf tests / a player who wants an uncapped sandbox.
	_enabled = OS.get_environment("LA_NO_SMITE") == ""
	var env_ceiling: String = OS.get_environment("LA_POP_CEILING")
	if env_ceiling != "":
		_ceiling = maxi(1, int(env_ceiling))
		_baseline = _ceiling                 # an explicit ceiling overrides the auto-baseline entirely


func _process(delta: float) -> void:
	if not _enabled:
		return
	if _cooldown > 0.0:
		_cooldown -= delta
	_check_cd -= delta
	if _check_cd > 0.0:
		return
	_check_cd = CHECK_PERIOD
	var animals: Array = get_tree().get_nodes_in_group("creature")
	var count: int = animals.size()
	# Latch the founding population once the world has actually spawned, so the auto-ceiling scales to it.
	if _baseline < 0 and count > 0 and OS.get_environment("LA_POP_CEILING") == "":
		_baseline = count
		_ceiling = maxi(ABS_FLOOR, int(round(float(_baseline) * CEILING_MULT)))
	# Re-arm once the herd has been thinned back under the relief line (hysteresis).
	if not _armed and count < int(float(_ceiling) * RELIEF):
		_armed = true
	if not _armed or _cooldown > 0.0 or count <= _ceiling:
		return
	_smite(count)


# Seed a culling CLOUDBURST at the densest cluster. Grid-buckets the animals (O(n)) to find the fullest cell,
# then seeds a flood there sized to that crowd. The flood conjures no water — it is an intense rain event; the
# downpour runs off, pools, and the current sweeps the mob (drowning, dispersal, uprooting all emerge).
func _smite(count: int) -> void:
	var mob: int = 0
	if not _densest_cluster():
		return
	mob = _last_mob
	var radius: float = FLOOD_MIN_RADIUS + FLOOD_PER_HEAD * float(mob)
	var flood: Node3D = FloodScript.new()
	_actors_root.add_child(flood)
	flood.setup(_terrain, _ecology)
	flood.surge(_cluster_center, radius)
	_armed = false
	_cooldown = COOLDOWN
	print("SMITE={pop:%d, ceiling:%d, mob:%d, radius:%.1f}" % [count, _ceiling, mob, radius])


var _last_mob: int = 0
var _cluster_center: Vector3 = Vector3.ZERO

# Find the fullest BUCKET_CELL-sized cell of animals; stash its centroid in `_cluster_center` and its head
# count in `_last_mob`. Returns false if there are no animals. One O(n) pass: hash each animal to a cell,
# accumulate a running centroid + count per cell, keep the fullest. No pairwise distances — the grid IS the
# neighbour structure (Big-O mandate: linear, not the quadratic all-pairs density it replaces).
func _densest_cluster() -> bool:
	var animals: Array = get_tree().get_nodes_in_group("creature")
	var sums: Dictionary = {}     # cell_key -> Vector3 position sum
	var counts: Dictionary = {}   # cell_key -> int
	var best_key: Vector3i = Vector3i(0, 0, 0)
	var best_n: int = 0
	var any: bool = false
	for a in animals:
		if not is_instance_valid(a) or not (a is Node3D):
			continue
		any = true
		var p: Vector3 = (a as Node3D).global_position
		var key: Vector3i = Vector3i(int(floor(p.x / BUCKET_CELL)), int(floor(p.y / BUCKET_CELL)), int(floor(p.z / BUCKET_CELL)))
		var n: int = int(counts.get(key, 0)) + 1
		counts[key] = n
		sums[key] = (sums.get(key, Vector3.ZERO) as Vector3) + p
		if n > best_n:
			best_n = n
			best_key = key
	if not any:
		return false
	_last_mob = best_n
	_cluster_center = (sums[best_key] as Vector3) / float(best_n)
	return true
