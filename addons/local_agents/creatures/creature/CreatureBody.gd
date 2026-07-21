class_name LACreatureBody
extends RefCounted

## Body/model construction for LACreature, factored out of the main brain. Builds the display model
## (glTF via LAModelVisual) when the species has one, else a procedural capsule, plus the collision
## shape and the thrower's carried-rock visual. Static + dynamic access on the passed creature so there
## is no cyclic class reference. (Explicit types only — project rule: no ':=' inferred typing.)


## Build the creature's visual body: a display model if the species has one, otherwise a procedural
## capsule; then the collision shape and (for throwers) the carried-rock mesh.
static func build_body(c) -> void:
	# Prefer a display model for this species (LAActorModels); fall back to the primitive capsule.
	build_model(c)
	if c._model_root == null:
		var mesh: MeshInstance3D = MeshInstance3D.new()
		if c.can_fly:
			var cap: CapsuleMesh = CapsuleMesh.new()
			cap.radius = c.size * 0.5
			cap.height = maxf(c.size * 1.4, c.size)
			mesh.mesh = cap
		else:
			var body: CapsuleMesh = CapsuleMesh.new()
			body.radius = c.size * 0.6
			body.height = maxf(c.size * 2.0, c.size * 1.2)
			mesh.mesh = body
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = c.color
		mat.roughness = 0.85
		mesh.material_override = mat
		c.add_child(mesh)
		c._mesh = mesh

	var shape: CollisionShape3D = CollisionShape3D.new()
	var cyl: CapsuleShape3D = CapsuleShape3D.new()
	cyl.radius = maxf(c.size * 0.6, 0.1)
	cyl.height = maxf(c.size * 2.0, 0.4)
	shape.shape = cyl
	c.add_child(shape)

	# Throwers (humans) carry a visible rock when armed.
	if c.throws:
		c._rock_visual = MeshInstance3D.new()
		c._rock_visual.mesh = LARockMesh.make(maxf(c.size * 0.32, 0.18), 4242, 0.45)
		c._rock_visual.material_override = LARockMesh.material()
		c._rock_visual.position = Vector3(c.size * 0.55, c.size * 0.7, c.size * 0.35)
		c._rock_visual.visible = false
		c.add_child(c._rock_visual)


## Try to build a display model for this species. Sets _model_root/_model_anim on success, leaves them
## null (caller builds the capsule) if the species has no model or it fails to load.
static func build_model(c) -> void:
	var def: Dictionary = LAActorModels.get_def(c.species)
	var model_path: String = String(c.config.get("model", def.get("path", "")))
	if model_path.is_empty():
		return
	var target_h: float = maxf(c.size * 2.0, c.size * 1.2) * float(c.config.get("model_scale", 1.0))
	var yaw: float = float(c.config.get("model_yaw", def.get("yaw", 0.0)))
	var model: Node3D = LAModelVisual.build(model_path, target_h, "center", yaw, LAActorModels.tint(c.species))
	if model == null:
		return
	c.add_child(model)
	c._model_root = model
	c._model_anim = LAModelVisual.find_anim(model)
	if c._model_anim != null:
		# MANUAL process: the creature drives the mixer itself via advance() on a distance-scaled cadence
		# (animation-framerate LOD in LACreature._process), instead of Godot auto-sampling every skeleton every
		# frame. This is what lets a distant creature's skeleton update a few times a second instead of 60.
		c._model_anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	c._model_anims = def.get("anims", {})
	c._model_run_speed = float(def.get("run", 999.0))
	c._vis_prev_pos = c.global_position
