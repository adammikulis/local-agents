class_name LACreatureAffiliation
extends RefCounted

## WHO I RUN WITH, kept separate from WHO I DESCEND FROM.
##
## Lineage is immutable for life by design (LAKinshipGraph's components only grow and its labels never
## change, which is what keeps the per-frame kin check a cached integer compare). Affiliation is not, so it
## is a separate label:
##   * LINEAGE  — `family_id`, owned by LAKinshipGraph, immutable, and what the kin-weighted social
##                learning reads (LACognition.observe, LocalAgentCreature.hear_call). A juvenile follows
##                its PARENT through it (LACreatureLeadership.elect).
##   * BAND     — `band_id`, owned here, changes freely. What a lost herd animal regroups toward
##                (LACreatureFlocking._band_regroup), and what the dated MEMBER_OF records in the backstory
##                store describe (LABandChronicle).
##
## A BAND IS NOT STAMPED AT SPAWN. A warren is not something you are born holding — it is what you get when animals
## persistently ASSOCIATE, so that is literally what this computes, from ONE local rule with no species
## branch and no per-case code:
##
##   1. FORGET   every remembered bond fades at a fixed rate, whoever it is with.
##   2. COMPANY  the nearest few same-species animals actually beside me right now gain bond.
##   3. LEAVE    if nobody left in my band is still company, I am back to a band of one.
##   4. JOIN     otherwise, if my strongest companion outside my band has passed the join threshold and
##               their band is older than mine, I adopt it.
##
## Splinter groups fall out of that rule with nothing written for them: a sub-group that drifts away keeps
## its mutual bonds and loses the rest, so step 3 empties it out of the old band and step 4 re-converges it
## onto one new label.
##
## WHAT THIS RULE CANNOT EXPRESS: bands never mix lineages. Step 2 queries only `"species_" + c.species`,
## and `EcologySpawner._spawn_clustered_founders` starts families as spatial clusters, so a creature's
## same-species neighbours are its relatives and a band is a strictly FINER partition of a family, never a
## crossing one. Rival packs and cross-family adoption need something that mixes lineages in space first
## (migration, or a founder scatter that interleaves families); no tuning of this rule reaches them.
##
## BAND LABELS ARE MINTED IN ORDER, and step 4 only ever adopts a SMALLER (older) label. That is what makes
## label propagation converge instead of two animals swapping labels forever, and it means a newcomer joins
## the established band rather than renaming it. Every creature mints one permanent solo label at setup and
## returns to exactly that label on step 3, so leaving a band cannot mint labels without bound.
##
## Step 4 deliberately does NOT also require the outside bond to beat the strongest bond inside my own band.
## That reads like the right test — "the pull out must exceed the pull in" — and it is the right test for a
## DEFECTION, but adopting an older label is a MERGE, not a defection: nobody leaves anyone. Requiring it
## stalls every merge at the first animal whose closest companion is already a band-mate, which is almost all
## of them.
##
## COMPLEXITY. Per creature, once per ASSOC_PERIOD (not per frame): one bounded query against the spatial
## hash LACreatureSenses already rebuilds at most once per group per frame, a linear pass over its
## candidates keeping the nearest NEIGHBOUR_CAP, and a pass over at most MAX_ASSOC remembered bonds. So
## O(1) amortised per creature per second and O(n) for the population — no pairwise scan, no per-frame
## work, and no new index. The per-frame hot path never touches any of it: it reads the cached `band_id`
## integer through the accessors at the bottom of this file.
## (Explicit types only, no ':=' inferred typing.)

## Seconds between association samples. The rule runs on this coarse cadence, never per frame.
const ASSOC_PERIOD: float = 0.5
## Bond gained per second of company, and lost per second apart. Company is worth about three times what
## absence costs, so a band forms in a couple of seconds and takes several to dissolve — groups are sticky
## without being permanent.
const BOND_GAIN: float = 1.0
const BOND_DECAY: float = 0.35
const BOND_MAX: float = 4.0
## Bond at which I will adopt a companion's band, and the bond below which a band-mate no longer counts as
## company at all. JOIN above KEEP so the two thresholds cannot chatter against each other.
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


## Give `c` its starting affiliation state: a band of one, and a staggered first sample so the population
## does not run its association tick on the same frame. Called from LACreatureSetup.
##
## The stagger comes from the band label, NOT from LASimRng, and that is deliberate on both counts. Drawing
## here would consume one number from the seeded stream per creature and shift every later draw — vegetation
## scatter, sex, lifespan jitter — so two runs of the same seed would no longer be the same world.
##
## And the label rather than the instance id, because the label is a plain counter and so is uniform mod
## STAGGER_SLOTS by construction. Instance ids advance by however many objects a creature's construction
## happens to allocate, which can be a constant stride — and a stride sharing a factor with the slot count
## collapses the whole population onto a couple of phases, which is a thundering herd, not a stagger.
const STAGGER_SLOTS: int = 16

static func setup(c) -> void:
	c._band_solo = mint_label()
	c.band_id = c._band_solo
	c._assoc = {}
	c._assoc_cd = ASSOC_PERIOD * float(c._band_solo % STAGGER_SLOTS) / float(STAGGER_SLOTS)


## The whole rule, run on the coarse cadence. Called once per physics tick from the creature; returns
## immediately on all but roughly one tick in thirty.
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


## 2. COMPANY. Credit the nearest NEIGHBOUR_CAP same-species creatures inside my flocking radius — the
## animals I am demonstrably with. One bounded spatial-hash query (the shared frame-stamped index, so the
## rebuild is already paid for by the sense/leadership queries), then a linear pass keeping the nearest few.
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
	# JOIN: my strongest companion outside my band has passed the threshold and their band is older than
	# mine. Older-wins is what makes this converge; see the header for why there is no also-beats-my-own-band
	# test here, which stalls merges rather than preventing churn.
	if best_bond >= JOIN_BOND and best_band > 0 and best_band < my_band:
		_set_band(c, best_band)


static func _set_band(c, band: int) -> void:
	if int(c.band_id) == band:
		return
	c.band_id = band
	LASimReport.event("band_change", {"species": String(c.species)})


# --- The read seam -------------------------------------------------------------------------------------
# Every per-frame reader of either meaning goes through these four functions, so "affiliation" and
# "lineage" are two named things a reader picks between rather than one integer whose meaning depends on
# the caller. All four are a single cached property read: the durable dated record in the backstory store
# is consulted only on membership EVENTS by LABandChronicle, never from here.

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
