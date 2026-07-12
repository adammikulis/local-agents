class_name LAWorldSaveState
extends RefCounted

## LAWorldSaveState — gathers the LIVING WORLD into a plain-data Dictionary a save can persist, and applies
## such a Dictionary back onto a freshly-booted world. It owns the per-actor + kinship + progression
## serialization; the heavy FIELD blob is delegated to LAMaterialFieldSnapshot3D and the disk I/O to
## LAGameSave. Kept out of the extract-only VoxelWorld/MaterialField hubs (a focused module the save
## controller calls).
##
## WHAT A SAVE HOLDS:
##   * field       — every GPU field channel (water/heat/moisture/rock_fill/lava/o2/co2/biomass/snow/…).
##   * creatures   — species, transform, age, energy/hydration/health/breath, family_id, leadership role,
##                   llm_enabled, the heritable genome (LADNA strand + base_config/instincts/generation), and the
##                   LEARNED cognition (policy + cue_values) so a reloaded animal keeps what it learned.
##   * fish        — species, transform, age, health, breath (aquatic actors have no cognition/kinship).
##   * vegetation  — plant/tree/rock kind + transform (ambient scatter; re-instanced in place).
##   * kinship     — each creature's family GROUP + the directed lineage edges, remapped to stable save
##                   indices so the graph rebuilds correctly under the new instance ids a reload assigns.
##   * progression — LAGameProgression.serialize() (mode/stage/unlocks/zoom ceiling).
##
## RESTORE rebuilds deterministically: instance each actor at its saved transform (bypassing surface
## projection), re-apply scalar state + cognition, then reconstruct kinship by grouping creatures by their
## saved family and replaying the directed edges through a save-index→live-cid map. (Explicit types — no ':=' .)

const DNAScript: GDScript = preload("res://addons/local_agents/creatures/cognition/DNA.gd")
const FieldSnapshotScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialFieldSnapshot3D.gd")


# --- CAPTURE ------------------------------------------------------------------------------------------------

## Gather the whole world into a save dict. `field` may be a not-yet-ready field (its block comes back empty
## and restore simply keeps the booted field). Cheap-ish: a few group scans + one GPU field readback.
static func capture(world) -> Dictionary:
	var ecology = world._ecology
	var field = world._material
	var tree: SceneTree = world.get_tree()

	var creatures: Array = []
	var cid_to_index: Dictionary = {}      # live instance_id -> save index (for kinship remap)
	for c in tree.get_nodes_in_group("creature"):
		if not is_instance_valid(c):
			continue
		cid_to_index[int(c.get_instance_id())] = creatures.size()
		creatures.append(_capture_creature(c, ecology))

	var fish: Array = []
	for f in tree.get_nodes_in_group("fish"):
		if is_instance_valid(f):
			fish.append(_capture_fish(f))

	var vegetation: Array = []
	for grp in ["plant", "tree", "rock"]:
		for v in tree.get_nodes_in_group(grp):
			if is_instance_valid(v) and v is Node3D:
				vegetation.append({"kind": grp, "xform": (v as Node3D).global_transform})

	var progression: Dictionary = {}
	if world._progression != null and world._progression.has_method("serialize"):
		progression = world._progression.serialize()

	return {
		"field": FieldSnapshotScript.capture(field),
		"creatures": creatures,
		"fish": fish,
		"vegetation": vegetation,
		"kinship": _capture_kinship(ecology, cid_to_index),
		"progression": progression,
	}


static func _capture_creature(c, ecology) -> Dictionary:
	var d: Dictionary = {
		"species": String(c.species),
		"xform": (c as Node3D).global_transform,
		"age": float(c.age),
		"energy": float(c.energy),
		"hydration": float(c.hydration),
		"health": float(c.health),
		"breath": float(c._breath),
		"state": String(c.state),
		"llm_enabled": bool(c.llm_enabled),
		"is_leader": bool(c._is_leader),
		"leader_loyalty": float(c.leader_loyalty),
		"family_group": _family_group(ecology, int(c.get_instance_id())),
		"family_registered": _family_registered(ecology, int(c.get_instance_id())),
	}
	var genome = c.get_genome() if c.has_method("get_genome") else null
	if genome != null:
		d["genome"] = genome.snapshot()
	var cog = c.get_cognition() if c.has_method("get_cognition") else null
	if cog != null:
		d["cognition"] = {
			"policy": cog.policy.duplicate(true),
			"cue_values": cog.cue_values.duplicate(true),
			"escalations": int(cog.escalations),
			"decisions": int(cog.decisions),
			"lessons": int(cog.lessons),
			"vetoes": int(cog.vetoes),
		}
	return d


static func _capture_fish(f) -> Dictionary:
	return {
		"species": String(f.species),
		"xform": (f as Node3D).global_transform,
		"age": float(f.age),
		"health": float(f.health),
		"breath": float(f._breath),
	}


# The stable family label of a creature (its kinship connected-component root) — the group key that survives a
# reload. Solitary/unregistered creatures resolve to their own (per-run) id; grouping treats those as singletons.
static func _family_group(ecology, cid: int) -> int:
	var graph = ecology.kinship() if ecology != null and ecology.has_method("kinship") else null
	return graph.family_of(cid) if graph != null else cid


# True when the creature is a REGISTERED member of the kinship graph (a founder-cluster member or a bred
# offspring), i.e. its family label differs from its own id. An unregistered solitary creature resolves to its
# own id. This lets restore reproduce family_count() exactly: a registered family with a single living member is
# still one component, so it must be re-registered even though its group has size 1.
static func _family_registered(ecology, cid: int) -> bool:
	var graph = ecology.kinship() if ecology != null and ecology.has_method("kinship") else null
	return graph != null and graph.family_of(cid) != cid


# Remap the directed lineage edges (kept keyed by live cid) to save indices, dropping any endpoint that is not
# a currently-living saved creature (a forgotten/dead ancestor). Stored as { children, parents, mates }, each
# save_index -> Array[int] save_index.
static func _capture_kinship(ecology, cid_to_index: Dictionary) -> Dictionary:
	var graph = ecology.kinship() if ecology != null and ecology.has_method("kinship") else null
	if graph == null or not graph.has_method("directed_edges"):
		return {"children": {}, "parents": {}, "mates": {}}
	var edges: Dictionary = graph.directed_edges()
	return {
		"children": _remap_edge_dict(edges.get("children", {}), cid_to_index),
		"parents": _remap_edge_dict(edges.get("parents", {}), cid_to_index),
		"mates": _remap_edge_dict(edges.get("mates", {}), cid_to_index),
	}


static func _remap_edge_dict(src: Dictionary, cid_to_index: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in src.keys():
		if not cid_to_index.has(int(k)):
			continue
		var mapped: Array = []
		for v in (src[k] as Array):
			if cid_to_index.has(int(v)):
				mapped.append(int(cid_to_index[int(v)]))
		if not mapped.is_empty():
			out[int(cid_to_index[int(k)])] = mapped
	return out


# --- APPLY --------------------------------------------------------------------------------------------------

## Re-instance every saved actor and rebuild kinship. Progression is applied separately (before this, by the
## controller) since it does not depend on the field/actors being up. Returns the number of creatures restored.
static func apply_actors(world, data: Dictionary) -> int:
	var ecology = world._ecology
	if ecology == null:
		return 0

	# Vegetation + fish first (order-independent), then creatures (their index order backs the kinship remap).
	for veg in data.get("vegetation", []):
		var vd: Dictionary = veg
		ecology.restore_actor(String(vd.get("kind", "rock")), vd.get("xform", Transform3D.IDENTITY))
	for fdat in data.get("fish", []):
		_apply_fish(ecology, fdat)

	var creatures: Array = data.get("creatures", [])
	var index_to_cid: Dictionary = {}      # save index -> live instance_id
	var nodes: Array = []
	for i in range(creatures.size()):
		var cd: Dictionary = creatures[i]
		var node = _apply_creature(ecology, cd)
		nodes.append(node)
		if node != null and is_instance_valid(node):
			index_to_cid[i] = int(node.get_instance_id())

	_rebuild_kinship(ecology, creatures, nodes, index_to_cid, data.get("kinship", {}))
	return creatures.size()


static func _apply_creature(ecology, cd: Dictionary):
	var genome = null
	if cd.has("genome"):
		var gd: Dictionary = cd["genome"]
		genome = DNAScript.restore(gd)
	var node = ecology.restore_actor(String(cd.get("species", "creature")), cd.get("xform", Transform3D.IDENTITY), genome, -1)
	if node == null or not is_instance_valid(node):
		return null
	# Override the setup() defaults with the saved living state (setup reset energy/health to max).
	node.age = float(cd.get("age", 0.0))
	node.energy = float(cd.get("energy", node.energy))
	node.hydration = float(cd.get("hydration", node.hydration))
	node.health = float(cd.get("health", node.health))
	node._breath = float(cd.get("breath", node._breath))
	node.state = String(cd.get("state", node.state))
	node.llm_enabled = bool(cd.get("llm_enabled", true))
	node._is_leader = bool(cd.get("is_leader", true))
	if cd.has("cognition"):
		_apply_cognition(node.get_cognition(), cd["cognition"])
	return node


static func _apply_cognition(cog, cogd: Dictionary) -> void:
	if cog == null:
		return
	cog.policy = (cogd.get("policy", {}) as Dictionary).duplicate(true)
	cog.cue_values = (cogd.get("cue_values", {}) as Dictionary).duplicate(true)
	cog.escalations = int(cogd.get("escalations", 0))
	cog.decisions = int(cogd.get("decisions", 0))
	cog.lessons = int(cogd.get("lessons", 0))
	cog.vetoes = int(cogd.get("vetoes", 0))


static func _apply_fish(ecology, fdat: Dictionary) -> void:
	var fd: Dictionary = fdat
	var node = ecology.restore_actor(String(fd.get("species", "fish")), fd.get("xform", Transform3D.IDENTITY))
	if node != null and is_instance_valid(node):
		node.age = float(fd.get("age", 0.0))
		node.health = float(fd.get("health", node.health))
		node._breath = float(fd.get("breath", node._breath))


# Reconstruct the kinship graph under the new instance ids: group saved creatures by their saved family label,
# mint a fresh family per multi-member group and register its members (single-member groups stay unregistered,
# exactly like a solitary creature), set each creature's family_id, then replant the directed lineage edges.
static func _rebuild_kinship(ecology, creatures: Array, nodes: Array, index_to_cid: Dictionary, kinship: Dictionary) -> void:
	var graph = ecology.kinship() if ecology != null and ecology.has_method("kinship") else null
	if graph == null:
		return

	# Bucket save indices by their saved family group, tracking whether the group was a REGISTERED family.
	var groups: Dictionary = {}            # family_group -> Array[int] save indices
	var registered: Dictionary = {}        # family_group -> bool (any member was graph-registered)
	for i in range(creatures.size()):
		if not index_to_cid.has(i):
			continue
		var fg: int = int((creatures[i] as Dictionary).get("family_group", -1))
		if not groups.has(fg):
			groups[fg] = []
			registered[fg] = false
		(groups[fg] as Array).append(i)
		if bool((creatures[i] as Dictionary).get("family_registered", false)):
			registered[fg] = true

	for fg in groups.keys():
		var members: Array = groups[fg]
		# Re-register a group that was a real family (multi-member OR a registered singleton whose kin have
		# since died) so family_count() reproduces exactly; leave a genuinely solitary creature unregistered.
		if graph.has_method("new_family") and (members.size() >= 2 or bool(registered[fg])):
			var label: int = graph.new_family()
			for idx in members:
				var cid: int = int(index_to_cid[idx])
				graph.add_member(label, cid)
				_set_family_id(nodes[idx], label)
		else:
			# Solitary: its own new instance id is its family (unregistered, matching a fresh solitary spawn).
			var idx0: int = int(members[0])
			_set_family_id(nodes[idx0], int(index_to_cid[idx0]))

	# Replant the directed lineage skeleton (remap save index -> live cid) for the family-tree inspector.
	if graph.has_method("restore_directed"):
		graph.restore_directed(
			_remap_to_cid(kinship.get("children", {}), index_to_cid),
			_remap_to_cid(kinship.get("parents", {}), index_to_cid),
			_remap_to_cid(kinship.get("mates", {}), index_to_cid))


static func _set_family_id(node, fid: int) -> void:
	if node != null and is_instance_valid(node) and "family_id" in node:
		node.set("family_id", fid)


static func _remap_to_cid(src: Dictionary, index_to_cid: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in src.keys():
		if not index_to_cid.has(int(k)):
			continue
		var mapped: Array = []
		for v in (src[k] as Array):
			if index_to_cid.has(int(v)):
				mapped.append(int(index_to_cid[int(v)]))
		if not mapped.is_empty():
			out[int(index_to_cid[int(k)])] = mapped
	return out
