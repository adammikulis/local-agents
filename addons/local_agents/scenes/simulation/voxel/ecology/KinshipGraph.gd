class_name LAKinshipGraph
extends RefCounted

## Permanent KINSHIP GRAPH backing every creature's family_id (owned by LAEcologyService — kept out of the
## extract-only field/world hubs). A FAMILY is a connected component; family_id is that component's stable
## label. Relationships are recorded as EDGES once and never rewritten: founder-cluster siblings link to their
## cluster anchor at spawn, parent→offspring links at birth. A creature's family label is assigned once and
## never changes for life — components only GROW as offspring join their parent's family, and distinct founder
## families are never merged, so labels stay immutable (kin is fixed for life).
##
## Kin recognition / regroup reads the cheap family_id equality (an omnidirectional smell/sound RANGE sense,
## see LACreatureLeadership.nearest_family_adult), NOT this graph, so the graph never sits on the per-frame
## path: it is touched only on the founding / birth / death EVENTS. Union-find find() is ~O(1) amortised
## (path-compressed); death cleanup is O(degree). No per-frame rebuild, no O(n²). (Explicit types — no ':=' .)

var _parent: Dictionary = {}      # union-find: node/label id → parent id (a component's root IS its family label)
var _adj: Dictionary = {}         # relationship record: node id → Array[int] of kin node ids (undirected edges)
var _anchor: Dictionary = {}      # family label → its first-registered member (siblings link to this anchor)
var _seq: int = 0                 # family-label sequence — small positive ids (creature instance ids are large)

# DIRECTED / TYPED lineage records, kept alongside the undirected _adj so a reader (the family-tree inspector)
# can tell a parent from a child from a mate — _adj alone loses that. Populated from the SAME founding / birth /
# bond events as _adj (no change to when edges are recorded, or to the union-find family labels). These are the
# permanent SKELETON of the lineage: forget() (death cleanup) intentionally does NOT prune them, so a family tree
# still shows a dead/removed ancestor's place in the line — the reader resolves each id to decide alive vs dead.
var _children: Dictionary = {}    # parent cid → Array[int] child cids (directed, from add_offspring)
var _parents: Dictionary = {}     # child cid → Array[int] parent cids (directed, from add_offspring)
var _mates: Dictionary = {}       # cid → Array[int] mate cids (undirected pair bond, from add_bond)


## Allocate a fresh family label: a new connected component with no members yet. Founder clusters call this
## once; the returned label becomes the shared family_id of that cluster's members (and of their descendants).
func new_family() -> int:
	_seq += 1
	_parent[_seq] = _seq          # a self-rooted (empty) component
	return _seq


## Union-find root of `x` with path compression. An id the graph has never seen resolves to itself — so a
## solitary creature (family_id defaulted to its own instance id) is simply its own one-member family, and
## family_of() stays correct for everyone without having to register the unclustered.
func find(x: int) -> int:
	var root: int = x
	while _parent.has(root) and int(_parent[root]) != root:
		root = int(_parent[root])
	var n: int = x
	while _parent.has(n) and int(_parent[n]) != root:
		var nxt: int = int(_parent[n])
		_parent[n] = root
		n = nxt
	return root


## The family label of creature `cid` — its connected component's root, the authoritative source for
## family_id. Equal to the id it was assigned at birth, since components never merge.
func family_of(cid: int) -> int:
	return find(cid)


## Register `cid` as a member of family `label` (a founder-cluster member — the direct spawn or its later
## pending retry). Links a sibling edge to the cluster's anchor so the record is a real connected graph, not
## just a shared scalar. Idempotent per creature.
func add_member(label: int, cid: int) -> void:
	if not _parent.has(label):
		_parent[label] = label
	_parent[cid] = find(label)
	if _anchor.has(int(label)):
		_link(cid, int(_anchor[int(label)]))
	else:
		_anchor[int(label)] = cid


## Record a parent→offspring bond at birth: the child joins the parent's existing family (no existing member
## is relabelled) and the lineage edge is stored. Returns the child's family label.
func add_offspring(parent_cid: int, child_cid: int) -> int:
	var label: int = find(parent_cid)
	if not _parent.has(label):
		_parent[label] = label
	_parent[child_cid] = label
	_link(parent_cid, child_cid)
	_append_unique(_children, parent_cid, child_cid)
	_append_unique(_parents, child_cid, parent_cid)
	return label


## Record a mate / pair bond as a relationship edge WITHOUT merging the two families: labels are immutable, so
## a cross-family pairing is kept in the edge record while each partner keeps its birth family label.
func add_bond(a_cid: int, b_cid: int) -> void:
	_link(a_cid, b_cid)
	if a_cid != b_cid:
		_append_unique(_mates, a_cid, b_cid)
		_append_unique(_mates, b_cid, a_cid)


func _append_unique(store: Dictionary, key: int, value: int) -> void:
	if not store.has(key):
		store[key] = []
	var arr: Array = store[key]
	if not arr.has(value):
		arr.append(value)


func _link(a: int, b: int) -> void:
	if a == b:
		return
	if not _adj.has(a):
		_adj[a] = []
	if not _adj.has(b):
		_adj[b] = []
	var la: Array = _adj[a]
	var lb: Array = _adj[b]
	if not la.has(b):
		la.append(b)
	if not lb.has(a):
		lb.append(a)


## Death cleanup: forget a creature, removing its union-find entry and its kin edges (O(degree)). Family
## LABELS are never forgotten, so surviving relatives keep resolving to the same family for life.
func forget(cid: int) -> void:
	if _adj.has(cid):
		for other in (_adj[cid] as Array):
			if _adj.has(other):
				(_adj[other] as Array).erase(cid)
		_adj.erase(cid)
	_parent.erase(cid)


## Number of distinct living families (components that still hold at least one creature member). Cheap enough
## for an occasional report gauge; never called per frame. Creature ids are large (> _seq), bare labels small.
func family_count() -> int:
	var seen: Dictionary = {}
	for k in _parent.keys():
		if int(k) > _seq:
			seen[find(int(k))] = true
	return seen.size()


# --- Read-only lineage accessors (for the family-tree inspector) --------------------------------------------
# Pure reads over the stored typed edges — they never mutate the graph. Each returns a fresh copy so a caller
# can't alias the internal arrays. O(degree), safe to call on selection (never per frame).

## Direct parents of `cid` (usually 1-2). Empty for a founder (no recorded parent).
func parents_of(cid: int) -> Array:
	return (_parents[cid] as Array).duplicate() if _parents.has(cid) else []


## Direct offspring of `cid`. Empty for a creature that never bred.
func children_of(cid: int) -> Array:
	return (_children[cid] as Array).duplicate() if _children.has(cid) else []


## Mate / pair-bond partners of `cid` (the other parent(s) of its offspring). Empty if unpaired.
func mates_of(cid: int) -> Array:
	return (_mates[cid] as Array).duplicate() if _mates.has(cid) else []


## Every LIVING id currently sharing `cid`'s family label (its connected component). Founder siblings included.
## Union-find scan over the registered nodes — O(registered), only called on selection. Dead/forgotten ids drop
## out here (their _parent entry is gone), but they persist in the directed edges above so the tree still draws
## their place in the line.
func members_of_component(cid: int) -> Array:
	var root: int = find(cid)
	var out: Array = []
	for k in _parent.keys():
		var ki: int = int(k)
		if ki > _seq and find(ki) == root:
			out.append(ki)
	return out
