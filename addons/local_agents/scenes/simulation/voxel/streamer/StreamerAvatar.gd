class_name LAStreamerAvatar
extends Node

## The streamer's face-cam. Owns a persistent SubViewport that renders a rigged character live, so the
## overlay can show it as a moving portrait via a ViewportTexture (kept alive with UPDATE_ALWAYS).
## The model loops an idle clip; while the voice speaks we layer a bob + sway on the holder so it reads
## as "talking". Head accessories (cap / headphones / hair) ride a pivot synced to the model each frame.
##
## Two swappable flavors:
##   "male"   — Quaternius villager.glb (embedded Idle) + red Kenney cap.
##   "female" — Kenney characterLargeFemale mesh with the shared-skeleton Idle animation stitched on
##              from idle.fbx, a female skin, a ponytail, and procedural headphones.
## (Explicit types only — project rule: no ':=' inferred typing.)

const RENDER_SIZE: Vector2i = Vector2i(240, 300)

const HAT_SCENE_PATH: String = "res://addons/local_agents/assets/models/people/accessories/cap.fbx"

var _sv: SubViewport = null
var _model: Node3D = null
var _accessory: Node3D = null    # head-mounted extras (cap / headphones); parented to the head bone
var _head_attach: BoneAttachment3D = null   # Godot node that tracks the skeleton's head bone
var _skel: Skeleton3D = null
var _anim: AnimationPlayer = null
var _idle_clip: String = ""
var _flavor: String = ""

const AVATAR_RENDER_EVERY: int = 3     # re-render the face-cam every N frames (portrait ~20fps, not 60)
var _render_ctr: int = 0
var _talking: bool = false
var _t: float = 0.0
var _base_pos: Vector3 = Vector3.ZERO
var _base_rot: Vector3 = Vector3.ZERO
var _talk_blend: float = 0.0

# Gaze: rests dead-ahead, then occasionally flicks up-and-to-the-left and eases back.
const GLANCE_PITCH_UP: float = -0.20
const GLANCE_YAW_LEFT: float = 0.34
var _glance_blend: float = 0.0
var _glancing: bool = false
var _glance_hold: float = 0.0
var _next_glance: float = 4.0


func setup(flavor: String = "male") -> void:
	if DisplayServer.get_name() == "headless":
		return   # nothing to render in headless

	_sv = SubViewport.new()
	_sv.name = "AvatarViewport"
	_sv.size = RENDER_SIZE
	_sv.transparent_bg = true
	_sv.own_world_3d = true
	_sv.msaa_3d = Viewport.MSAA_4X
	# Render the face-cam every AVATAR_RENDER_EVERY frames (a portrait doesn't need a full own-World3D
	# scene re-rendered at 60fps) — re-armed to UPDATE_ONCE in _process.
	_sv.render_target_update_mode = SubViewport.UPDATE_ONCE

	var cam: Camera3D = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 1.15
	cam.position = Vector3(0.0, 1.42, -1.95)   # straight in front; models face -Z
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.64, 0.66, 0.72)
	env.ambient_light_energy = 1.0
	cam.environment = env
	_sv.add_child(cam)

	var light: DirectionalLight3D = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35.0, 35.0, 0.0)
	light.light_energy = 1.3
	_sv.add_child(light)

	add_child(_sv)
	cam.look_at(Vector3(0.0, 1.34, 0.0), Vector3.UP)

	_build_flavor(flavor)


## Swap the streamer's body live (male <-> female). Rebuilds the model + accessories.
func set_flavor(flavor: String) -> void:
	if flavor == _flavor or _sv == null:
		return
	# Accessories hang under the head bone (inside _model) — freeing _model frees them; the fallback
	# world-space accessory is the only one that needs a separate free.
	if _accessory != null and is_instance_valid(_accessory) and _accessory.get_parent() == _sv:
		_accessory.queue_free()
	if _model != null:
		_model.queue_free()
	_model = null
	_accessory = null
	_head_attach = null
	_skel = null
	_anim = null
	_build_flavor(flavor)


const FEMALE_GLB: String = "res://addons/local_agents/assets/models/people/character_female.glb"

func _build_flavor(flavor: String) -> void:
	_flavor = flavor
	_idle_clip = "Idle"
	# Female = the real Kenney characterLargeFemale, converted to glTF by Blender (mesh + idle + skin,
	# upright). Blender's exporter yields a clean glb Godot renders (unlike Godot's own ufbx path, which
	# left the skinned Kenney mesh invisible). Male = Quaternius villager + red cap.
	if flavor == "female":
		# Blender export faces +Z; yaw 180 turns her to face the camera like the other models.
		_model = LAModelVisual.build(FEMALE_GLB, 1.7, "base", 180.0, Color(0, 0, 0, 0))
	else:
		var def: Dictionary = LAActorModels.get_def("streamer")
		_model = LAModelVisual.build(String(def.get("path", "")), 1.7, "base", 0.0, LAActorModels.tint("streamer"))
	if _model == null:
		return
	if flavor != "female":
		LAModelVisual.recolor(_model, LAActorModels.recolor("streamer"))
	_anim = LAModelVisual.find_anim(_model)
	_idle_clip = _resolve_idle_clip(_anim)   # Blender names the clip "Root_001|Root|Idle", not "Idle"

	_sv.add_child(_model)
	_base_pos = _model.position
	_base_rot = _model.rotation
	if _anim != null and _idle_clip != "" and _anim.has_animation(_idle_clip):
		var clip: Animation = _anim.get_animation(_idle_clip)
		if clip != null:
			clip.loop_mode = Animation.LOOP_LINEAR   # keep the idle looping, not one-shot to T-pose
		_anim.play(_idle_clip)

	# Head accessories are PARENTED to the head bone via BoneAttachment3D (Godot's node for exactly this),
	# so they track the skeletal idle + glance automatically through the scene tree — no per-frame sync.
	# Offsets below are head-local (origin ≈ the head bone).
	_accessory = Node3D.new()
	_accessory.name = "HeadAccessories"
	if flavor == "female":
		_build_headphones()             # head-local offsets
		_attach_to_head()               # parent under the head bone (auto-follows idle + glance)
	else:
		_mount_asset(HAT_SCENE_PATH, 0.36, Vector3(0.0, 1.63, 0.0), Color(0.72, 0.18, 0.20))
		_sv.add_child(_accessory)       # world-space; synced to the model in _process


# Parent the accessory holder under a BoneAttachment3D bound to the skeleton's head bone. A scale-cancel
# holder keeps the accessory meshes world-sized despite the bone's (model-scaled) local units.
func _attach_to_head() -> void:
	_skel = _find_skeleton(_model)
	var head_name: String = _find_head_bone(_skel)
	if _skel == null or head_name == "":
		_sv.add_child(_accessory)   # fallback: world-space (kept static)
		return
	_head_attach = BoneAttachment3D.new()
	_head_attach.bone_name = head_name
	_skel.add_child(_head_attach)
	var holder: Node3D = Node3D.new()
	var inv: float = 1.0 / maxf(0.0001, _model.scale.x)
	holder.scale = Vector3(inv, inv, inv)
	_head_attach.add_child(holder)
	holder.add_child(_accessory)


static func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for c in node.get_children():
		var f: Skeleton3D = _find_skeleton(c)
		if f != null:
			return f
	return null


static func _find_head_bone(skel: Skeleton3D) -> String:
	if skel == null:
		return ""
	for i in range(skel.get_bone_count()):
		if skel.get_bone_name(i).to_lower().find("head") != -1:
			return skel.get_bone_name(i)
	return ""


# --- head accessories (positions are head-local; the BoneAttachment carries them onto the head) -----

func _mount_asset(scene_path: String, target_width: float, pos: Vector3, tint: Color) -> void:
	var scene: Resource = load(scene_path)
	if not (scene is PackedScene):
		return
	var asset: Node3D = (scene as PackedScene).instantiate() as Node3D
	if asset == null:
		return
	var mount: Node3D = Node3D.new()
	mount.add_child(asset)
	var ab: AABB = LAModelVisual._model_aabb(mount)
	var span: float = maxf(ab.size.x, maxf(ab.size.y, ab.size.z))
	if span > 0.0001:
		var s: float = target_width / span
		mount.scale = Vector3(s, s, s)
	asset.position -= ab.get_center()
	for mi in _mesh_instances(mount):
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = tint
		mat.roughness = 0.85
		(mi as MeshInstance3D).material_override = mat
	mount.position = pos
	_accessory.add_child(mount)


# Simple over-ear headphones (no CC0 headset exists in the Kenney packs): a band arcing ear-to-ear
# over the head plus two ear cups. Built in world units and placed at head height.
func _build_headphones() -> void:
	var shell: StandardMaterial3D = StandardMaterial3D.new()
	shell.albedo_color = Color(0.10, 0.10, 0.12)
	shell.roughness = 0.6
	var accent: StandardMaterial3D = StandardMaterial3D.new()
	accent.albedo_color = Color(0.75, 0.18, 0.55)   # pink accent
	accent.roughness = 0.5

	# Headband: a torus rotated 90° about X so the ring arcs left-ear → over-top → right-ear.
	var band: MeshInstance3D = MeshInstance3D.new()
	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = 0.125
	torus.outer_radius = 0.155
	band.mesh = torus
	band.material_override = shell
	band.rotation.x = deg_to_rad(90.0)
	band.position = Vector3(0.0, 0.09, 0.0)   # head-local (BoneAttachment carries it onto the head)
	_accessory.add_child(band)

	# Ear cups on both sides (cylinders laid along X).
	for sign in [-1.0, 1.0]:
		var cup: MeshInstance3D = MeshInstance3D.new()
		var cyl: CylinderMesh = CylinderMesh.new()
		cyl.top_radius = 0.055
		cyl.bottom_radius = 0.055
		cyl.height = 0.04
		cup.mesh = cyl
		cup.material_override = accent
		cup.rotation.z = deg_to_rad(90.0)
		cup.position = Vector3(0.135 * sign, 0.01, 0.0)
		_accessory.add_child(cup)


# --- shared -------------------------------------------------------------------------------------

static func _mesh_instances(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_mesh_instances(child))
	return out


# Pick the idle clip by name (Blender exports compound names like "Root_001|Root|Idle"); prefer one
# containing "idle", else the first available clip.
func _resolve_idle_clip(anim: AnimationPlayer) -> String:
	if anim == null:
		return ""
	var list: PackedStringArray = anim.get_animation_list()
	for a in list:
		if String(a).to_lower().find("idle") != -1:
			return String(a)
	return String(list[0]) if list.size() > 0 else ""


func get_texture() -> Texture2D:
	if _sv == null:
		return null
	return _sv.get_texture()


func set_talking(on: bool) -> void:
	_talking = on


func _process(delta: float) -> void:
	if _model == null:
		return
	# Re-arm the face-cam render on a cadence (portrait ~20fps at 60fps game) instead of every frame.
	_render_ctr += 1
	if _sv != null and _render_ctr % AVATAR_RENDER_EVERY == 0:
		_sv.render_target_update_mode = SubViewport.UPDATE_ONCE
	_t += delta

	var talk_target: float = 1.0 if _talking else 0.0
	_talk_blend = lerpf(_talk_blend, talk_target, clampf(delta * 8.0, 0.0, 1.0))
	var bob: float = sin(_t * 9.0) * 0.03 * _talk_blend

	if _glancing:
		_glance_hold -= delta
		if _glance_hold <= 0.0:
			_glancing = false
			_next_glance = randf_range(5.0, 10.0)
	else:
		_next_glance -= delta
		if _next_glance <= 0.0:
			_glancing = true
			_glance_hold = randf_range(1.1, 1.9)
	var glance_target: float = 1.0 if _glancing else 0.0
	_glance_blend = lerpf(_glance_blend, glance_target, clampf(delta * 6.0, 0.0, 1.0))

	_model.position = _base_pos + Vector3(0.0, bob, 0.0)
	_model.rotation = _base_rot + Vector3(GLANCE_PITCH_UP * _glance_blend, GLANCE_YAW_LEFT * _glance_blend, 0.0)

	# Bone-attached accessories (female headphones) follow the head bone automatically. World-space
	# accessories (male cap) are synced to the model here.
	if _accessory != null and _head_attach == null:
		_accessory.position = _model.position
		_accessory.rotation = _model.rotation
