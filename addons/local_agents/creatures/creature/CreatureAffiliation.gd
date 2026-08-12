class_name LACreatureAffiliation
extends RefCounted


const ASSOC_PERIOD: float = 0.5
const BOND_GAIN: float = 1.0
const BOND_DECAY: float = 0.35
const BOND_MAX: float = 4.0
const JOIN_BOND: float = 1.5
const KEEP_BOND: float = 0.5
## How many of the nearest companions a single sample credits, and how many bonds a creature remembers.
## Both small on purpose: an animal in the middle of a herd is with the few beside it, not with all 200.
const NEIGHBOUR_CAP: int = 4
const MAX_ASSOC: int = 6

## Band-label sequence. Monotonic, so a smaller label is an OLDER band — see the join rule above.
static var _seq: int = 0


## Mint the next band label. Every creature takes one at setup as its permanent band-of-one identity.
static func mint_label() -> int:
	_seq += 1
	return _seq


const STAGGER_SLOTS: int = 16

static func setup(c) -> void:
	c._band_solo = mint_label()
	c.band_id = c._band_solo
	c._assoc = {}
	c._assoc_cd = ASSOC_PERIOD * float(c._band_solo % STAGGER_SLOTS) / float(STAGGER_SLOTS)


static func tick(c, pos: Vector3, delta: float) -> void:
	c._assoc_cd -= delta
	if c._assoc_cd > 0.0:
		return
	c._assoc_cd = ASSOC_PERIOD
	var assoc: Dictionary = c._assoc
	_forget(assoc)
	_keep_company(c, pos, assoc)
	_decide(c, assoc)


## 1. FORGET. Every bond fades at the same rate whoever it is with, and a bond to a creature that has died
## or been removed is dropped outright (that is the whole death handling — no hook, no cleanup pass).
static func _forget(assoc: Dictionary) -> void:
	for k in assoc.keys():
		var kid: int = int(k)
		if not is_instance_id_valid(kid):
			assoc.erase(k)
			continue
		var v: float = float(assoc[k]) - BOND_DECAY * ASSOC_PERIOD
		if v <= 0.0:
			assoc.erase(k)
		else:
			assoc[k] = v


static func _keep_company(c, pos: Vector3, assoc: Dictionary) -> void:
	var radius: float = maxf(float(c.flock_radius), 1.0)
	var r2: float = radius * radius
	var near_d2: Array[float] = []
	var near_id: Array[int] = []
	for m in LACreatureSenses._fresh_index(c, ["species_" + String(c.species)]).query("species_" + String(c.species), pos, radius):
		if m == c or not is_instance_valid(m):
			continue
		# Company means a live, free animal beside me — a carcass or a creature in the player's hand is not
		# keeping me company. Mirrors the skip the leadership queries use, so the two agree on who is present.
		if m.get("_carcass") or m.get("_dead") or m.get("_held") or m.get("_dying"):
			continue
		var d2: float = pos.distance_squared_to((m as Node3D).global_position)
		if d2 > r2:
			continue
		_insert_nearest(near_d2, near_id, d2, int(m.get_instance_id()))
	var gain: float = BOND_GAIN * ASSOC_PERIOD
	for i in range(near_id.size()):
		var kid: int = near_id[i]
		assoc[kid] = minf(float(assoc.get(kid, 0.0)) + gain, BOND_MAX)
	_cap(assoc)


## Insertion into a fixed NEIGHBOUR_CAP-long nearest list — O(NEIGHBOUR_CAP) per candidate and no sort, so
## a dense herd costs a linear pass rather than an n log n one.
static func _insert_nearest(near_d2: Array[float], near_id: Array[int], d2: float, id: int) -> void:
	var at: int = near_d2.size()
	while at > 0 and near_d2[at - 1] > d2:
		at -= 1
	if at >= NEIGHBOUR_CAP:
		return
	near_d2.insert(at, d2)
	near_id.insert(at, id)
	if near_d2.size() > NEIGHBOUR_CAP:
		near_d2.resize(NEIGHBOUR_CAP)
		near_id.resize(NEIGHBOUR_CAP)


## Remember only the strongest MAX_ASSOC bonds, so the dictionary cannot grow with the population.
static func _cap(assoc: Dictionary) -> void:
	if assoc.size() <= MAX_ASSOC:
		return
	var keys: Array = assoc.keys()
	keys.sort_custom(func(a, b): return float(assoc[a]) > float(assoc[b]))
	for i in range(MAX_ASSOC, keys.size()):
		assoc.erase(keys[i])


## 3 + 4. LEAVE, then JOIN. Reads at most MAX_ASSOC bonds.
static func _decide(c, assoc: Dictionary) -> void:
	var my_band: int = int(c.band_id)
	var own_bond: float = 0.0     # strongest bond to someone already in my band
	var best_bond: float = 0.0    # strongest bond to someone outside it
	var best_band: int = 0
	for k in assoc.keys():
		var other: Object = instance_from_id(int(k))
		if other == null:
			continue
		var ob: Variant = other.get("band_id")
		if ob == null:
			continue
		var b: float = float(assoc[k])
		if int(ob) == my_band:
			own_bond = maxf(own_bond, b)
		elif b > best_bond:
			best_bond = b
			best_band = int(ob)
	# LEAVE: nobody left in my band is still company, so I am a band of one again — my own permanent label,
	# never a freshly minted one, so exile and re-exile cannot inflate the label space.
	if my_band != c._band_solo and own_bond < KEEP_BOND:
		_set_band(c, int(c._band_solo))
		return
	if best_bond >= JOIN_BOND and best_band > 0 and best_band < my_band:
		_set_band(c, best_band)


static func _set_band(c, band: int) -> void:
	if int(c.band_id) == band:
		return
	c.band_id = band
	LASimReport.event("band_change", {"species": String(c.species)})


## The band `c` currently runs with. Changes over a life.
static func band_of(c) -> int:
	return int(c.band_id)


## Neighbour `m`'s band. Tolerant `.get()` read so a non-creature node sharing a scene group never
## hard-errors — matches how LACognizerAdapter reads a neighbour's lineage.
static func neighbour_band(m) -> int:
	return int(m.get("band_id"))


## The bloodline `c` descends from. Fixed for life (LAKinshipGraph labels are immutable by design).
static func lineage_of(c) -> int:
	return int(c.family_id)


static func neighbour_lineage(m) -> int:
	return int(m.get("family_id"))
