class_name LACreatureTint
extends RefCounted


static var _tints: Dictionary = {}


static func set_highlight(category: String, col: Color, on: bool) -> void:
	if on:
		_tints[category] = col
	else:
		_tints.erase(category)


## Map a raw think/state string (LACreatureThink) to a debug highlight CATEGORY. Idle/wander/cruise/soar/
## circle/migrate/investigate have no category ("") — they are the un-tinted default.
static func state_category(s: String) -> String:
	match s:
		"eat":
			return "foraging"
		"chase", "stalk", "track", "throw":
			return "hunting"
		"flee", "panic":
			return "fleeing"
		"drink", "seek":
			return "drinking"
		"rest", "sleep", "roost":
			return "sleeping"
		"nesting":
			return "nesting"
		_:
			return ""


## Re-evaluate this creature's tint against the current enabled set (paint/clear only if the category
## changed). Cheap: an O(1) category lookup, does real material work solely on a change.
static func update(c) -> void:
	if _tints.is_empty():
		if c._tint_category != "":
			c._tint_category = ""
			_apply_overlay(c, Color.WHITE, false)
		return
	# The LLM slow-brain highlight (thinking/queued) takes priority over the behavior-state tint so a live
	# model consult is always the visible dye; falls back to the behavior-state category otherwise.
	var cat: String = _cognition_highlight_category(c)
	if cat == "":
		cat = state_category(c.state)
	var want: String = cat if _tints.has(cat) else ""
	if want == c._tint_category:
		return
	c._tint_category = want
	if want == "":
		_apply_overlay(c, Color.WHITE, false)
	else:
		_apply_overlay(c, _tints[want], true)


## Force a fresh tint evaluation (VoxelDebugWiring calls this on a checkbox toggle so live creatures
## update at once rather than waiting for their next state change).
static func refresh(c) -> void:
	c._tint_category = "__force__"               # impossible category → forces update() to reapply
	update(c)


## The LLM slow-brain highlight category for this creature ("llm_thinking"/"llm_queued"/""), asked only
## when that highlight is enabled. Reads the shared scheduler through this creature's cognition — O(1)
## scheduler lookups, no per-frame scan (and a no-op early-out when neither highlight is registered).
static func _cognition_highlight_category(c) -> String:
	if c._cognition == null:
		return ""
	var want_thinking: bool = _tints.has(LALLMControl.HL_THINKING)
	var want_queued: bool = _tints.has(LALLMControl.HL_QUEUED)
	if not (want_thinking or want_queued):
		return ""
	var sched = c._cognition.scheduler()
	if sched == null:
		return ""
	if want_thinking and sched.is_thinking(c):
		return LALLMControl.HL_THINKING
	if want_queued and sched.is_queued(c):
		return LALLMControl.HL_QUEUED
	return ""


# Paint (or clear) the emissive tint overlay on every visual mesh of this creature. Uses material_overlay
# so it layers over the model/capsule material without mutating the (species-shared) base materials.
static func _apply_overlay(c, col: Color, on: bool) -> void:
	if c._tint_targets.is_empty():
		_collect_targets(c)
	var mat: Material = null
	if on:
		if c._tint_mat == null:
			c._tint_mat = StandardMaterial3D.new()
			c._tint_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			c._tint_mat.emission_enabled = true
		c._tint_mat.albedo_color = Color(col.r, col.g, col.b, 0.5)
		c._tint_mat.emission = col
		c._tint_mat.emission_energy_multiplier = 0.9
		mat = c._tint_mat
	for mi in c._tint_targets:
		if is_instance_valid(mi):
			mi.material_overlay = mat


static func _collect_targets(c) -> void:
	c._tint_targets = []
	if c._mesh != null:
		c._tint_targets.append(c._mesh)
	elif c._model_root != null:
		_gather_mesh_instances(c._model_root, c._tint_targets)


static func _gather_mesh_instances(node: Node, out: Array) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		_gather_mesh_instances(child, out)
