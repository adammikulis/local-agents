class_name LAModelVisual
extends RefCounted

## Shared helper that turns a model file (imported glTF/GLB -> PackedScene) into a live child
## Node3D for any actor: instanced, uniformly scaled to a target height, optionally flat-tinted,
## and — when the model ships a rig — animated by movement. Rigless models get a lightweight
## procedural bob so they still read as alive. Nothing here branches on species; callers pass a
## row from LAActorModels, keeping the visual path config-driven per the emergent-everything rule.

# Loaded PackedScenes are cached so spawning 100 rabbits parses the GLB once.
static var _scene_cache: Dictionary = {}


static func _load_scene(path: String) -> PackedScene:
	if path.is_empty():
		return null
	if _scene_cache.has(path):
		return _scene_cache[path]
	var res: Resource = load(path)
	var ps: PackedScene = res as PackedScene
	_scene_cache[path] = ps
	return ps


## Instance `model_path`, scale it so its height == `target_height`, anchor it vertically
## ("center" like a capsule, or "base" so its feet sit at the node origin), rotate by `yaw_deg`
## to correct the model's forward, and flat-tint it if `tint.a > 0`. Returns the model root
## (ready to add_child), or null if the model can't be loaded.
static func build(model_path: String, target_height: float, anchor: String, yaw_deg: float, tint: Color) -> Node3D:
	var scene: PackedScene = _load_scene(model_path)
	if scene == null:
		return null
	var inst: Node = scene.instantiate()
	if inst == null:
		return null
	# Always wrap in a holder we own, so the model's own imported root transform is preserved
	# and we only ever touch the holder's scale / offset / yaw.
	var root: Node3D = Node3D.new()
	root.name = "Model"
	root.add_child(inst)

	# Measure the raw model (in holder space), then scale the holder to the requested height.
	var ab: AABB = _model_aabb(root)
	var s: float = 1.0
	if target_height > 0.0 and ab.size.y > 0.0001:
		s = target_height / ab.size.y
	root.scale = Vector3(s, s, s)

	# Vertical anchor: center the AABB on the origin (creatures/fish, matching the old capsule),
	# or put the model's base at the origin (trees/plants that grow up from the ground).
	if anchor == "base":
		root.position.y = -ab.position.y * s
	else:
		root.position.y = -(ab.position.y + ab.size.y * 0.5) * s

	if yaw_deg != 0.0:
		root.rotate_y(deg_to_rad(yaw_deg))
	if tint.a > 0.0:
		_apply_tint(root, tint)

	# Bob baseline + amplitude for the rigless procedural path (see animate()).
	root.set_meta("base_y", root.position.y)
	root.set_meta("bob_amp", maxf(target_height * 0.05, 0.02))
	return root


## Drive a built model's motion each frame. Rigged models play idle/move/run by `speed` (m/s);
## rigless models bob vertically while moving. `t` is an accumulating time, `delta` the frame step.
static func animate(model: Node3D, anim: AnimationPlayer, anims: Dictionary, speed: float, run_speed: float, t: float, delta: float) -> void:
	if model == null:
		return
	if anim != null and not anims.is_empty():
		var key: String = "idle"
		if run_speed > 0.0 and speed >= run_speed:
			key = "run"
		elif speed > 0.06:
			key = "move"
		var clip: String = String(anims.get(key, anims.get("move", anims.get("idle", ""))))
		if not clip.is_empty() and anim.has_animation(clip) and anim.current_animation != clip:
			anim.play(clip)
		return
	# Rigless: a small vertical bob while moving, easing back to rest when still.
	var base_y: float = float(model.get_meta("base_y", model.position.y))
	var amp: float = float(model.get_meta("bob_amp", 0.05))
	if speed > 0.06:
		model.position.y = base_y + absf(sin(t * 9.0)) * amp
	else:
		model.position.y = lerpf(model.position.y, base_y, clampf(delta * 8.0, 0.0, 1.0))


## First AnimationPlayer anywhere under `root` (imported glTF nests it beside the Skeleton3D).
static func find_anim(root: Node) -> AnimationPlayer:
	if root == null:
		return null
	if root is AnimationPlayer:
		return root as AnimationPlayer
	for child in root.get_children():
		var found: AnimationPlayer = find_anim(child)
		if found != null:
			return found
	return null


# Union of every MeshInstance3D's AABB, expressed in `root`'s local space. Uses LOCAL transform
# composition (not global_transform) so it is valid while the model is still out of the tree.
static func _model_aabb(root: Node3D) -> AABB:
	var out: AABB = AABB()
	var have: bool = false
	for mi in _mesh_instances(root):
		var local: AABB = _relative_xform(root, mi) * (mi as MeshInstance3D).get_aabb()
		if not have:
			out = local
			have = true
		else:
			out = out.merge(local)
	if not have:
		return AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1.0, 1.0, 1.0))
	return out


# Transform of `node` relative to `root`, by multiplying local transforms up the chain.
static func _relative_xform(root: Node3D, node: Node3D) -> Transform3D:
	var t: Transform3D = Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t


static func _mesh_instances(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_mesh_instances(child))
	return out


# Flatten every surface to one albedo (used only for the vulture recolour of the parrot mesh).
static func _apply_tint(root: Node, tint: Color) -> void:
	for mi in _mesh_instances(root):
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = tint
		mat.roughness = 0.85
		(mi as MeshInstance3D).material_override = mat
