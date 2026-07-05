class_name LAStreamerAvatar
extends Node

## The streamer's face-cam. Owns a persistent SubViewport that renders a rigged character live, so the
## overlay can show it as a moving portrait via a ViewportTexture (the still-capture rig in
## SpawnPaletteHud._render_thumbnail, kept alive with UPDATE_ALWAYS instead of read-back-to-Image).
## The model loops its idle clip; while the voice is speaking we layer a procedural head bob + sway on
## the holder transform so it reads as "talking" even though the base rigs ship no talk clip.
##
## Config-driven: the character + its clip names come from LAActorModels (id "streamer"), never a
## hardcoded path here. (Explicit types only — project rule: no ':=' inferred typing.)

const RENDER_SIZE: Vector2i = Vector2i(240, 300)

var _sv: SubViewport = null
var _model: Node3D = null
var _hat: Node3D = null          # rides above the head, synced to the model's glance/bob each frame
var _anim: AnimationPlayer = null
var _idle_clip: String = ""
var _talk_clip: String = ""

var _talking: bool = false
var _t: float = 0.0
var _base_pos: Vector3 = Vector3.ZERO
var _base_rot: Vector3 = Vector3.ZERO
var _talk_blend: float = 0.0   # eased 0..1 so the bob fades in/out instead of snapping

# Gaze: rests looking dead-ahead, then occasionally flicks up-and-to-the-left (like glancing at a
# second monitor / chat) and eases back. Rotation offsets are applied on the model holder on top of
# the skeletal idle.
const GLANCE_PITCH_UP: float = -0.20    # negative X-rotation tips the -Z-facing head upward
const GLANCE_YAW_LEFT: float = 0.34     # +Y turns the gaze to the viewer's left
var _glance_blend: float = 0.0
var _glancing: bool = false
var _glance_hold: float = 0.0
var _next_glance: float = 4.0


func setup(model_id: String = "streamer") -> void:
	if DisplayServer.get_name() == "headless":
		return   # nothing to render; the overlay shows a static placeholder in headless

	var def: Dictionary = LAActorModels.get_def(model_id)
	var model_path: String = String(def.get("path", ""))
	var anims: Dictionary = def.get("anims", {})
	_idle_clip = String(anims.get("idle", "Idle"))
	_talk_clip = String(anims.get("talk", _idle_clip))

	_sv = SubViewport.new()
	_sv.name = "AvatarViewport"
	_sv.size = RENDER_SIZE
	_sv.transparent_bg = true
	_sv.own_world_3d = true
	_sv.msaa_3d = Viewport.MSAA_4X
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	var cam: Camera3D = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 1.15   # frame head-and-shoulders of a ~1.7m humanoid
	# Models face -Z; sit the camera straight in front so the streamer looks dead-on at the viewer.
	cam.position = Vector3(0.0, 1.42, -1.95)
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

	_model = LAModelVisual.build(model_path, 1.7, "base", float(def.get("yaw", 0.0)), LAActorModels.tint(model_id))
	if _model != null:
		LAModelVisual.recolor(_model, LAActorModels.recolor(model_id))
		_sv.add_child(_model)
		_base_pos = _model.position
		_base_rot = _model.rotation
		_anim = LAModelVisual.find_anim(_model)
		if _anim != null and _anim.has_animation(_idle_clip):
			_anim.play(_idle_clip)
		_build_hat()

	add_child(_sv)
	cam.look_at(Vector3(0.0, 1.34, 0.0), Vector3.UP)


# Kenney "cap" accessory (CC0), imported from FBX by Godot's built-in converter. Sits on a pivot at the
# model's feet holding the cap at head height, so the model's glance/bob rotation (applied to the pivot
# each frame) swings the cap with the head. Auto-scaled by its own AABB so FBX unit scale doesn't matter.
const HAT_SCENE_PATH: String = "res://addons/local_agents/assets/models/people/accessories/cap.fbx"
const HAT_TARGET_WIDTH: float = 0.36   # world width the cap is normalized to (sits over the head)
const HAT_Y: float = 1.63              # head-top height in the model's local space
const HAT_FWD: float = 0.0
const HAT_YAW_DEG: float = 0.0         # flip if the cap's brim faces backward
const HAT_TINT: Color = Color(0.72, 0.18, 0.20)   # a bold streamer red

func _build_hat() -> void:
	var scene: Resource = load(HAT_SCENE_PATH)
	if not (scene is PackedScene):
		return
	var cap: Node3D = (scene as PackedScene).instantiate() as Node3D
	if cap == null:
		return

	_hat = Node3D.new()          # pivot at the feet, synced to the model each frame
	_hat.name = "Hat"
	var mount: Node3D = Node3D.new()   # positions/scales the cap onto the head
	mount.add_child(cap)

	# Normalize size from the cap's own bounds, then recenter it on the mount origin.
	var ab: AABB = LAModelVisual._model_aabb(mount)
	var span: float = maxf(ab.size.x, maxf(ab.size.y, ab.size.z))
	if span > 0.0001:
		var s: float = HAT_TARGET_WIDTH / span
		mount.scale = Vector3(s, s, s)
	cap.position -= ab.get_center()

	_apply_hat_tint(mount)
	mount.position = Vector3(0.0, HAT_Y, HAT_FWD)
	mount.rotation.y = deg_to_rad(HAT_YAW_DEG)
	_hat.add_child(mount)
	_sv.add_child(_hat)


func _apply_hat_tint(root: Node) -> void:
	for child in root.get_children():
		if child is MeshInstance3D:
			var mat: StandardMaterial3D = StandardMaterial3D.new()
			mat.albedo_color = HAT_TINT
			mat.roughness = 0.8
			(child as MeshInstance3D).material_override = mat
		if child is Node:
			_apply_hat_tint(child)


## The live portrait texture for a TextureRect. Null in headless.
func get_texture() -> Texture2D:
	if _sv == null:
		return null
	return _sv.get_texture()


func set_talking(on: bool) -> void:
	_talking = on


func _process(delta: float) -> void:
	if _model == null:
		return
	_t += delta

	# Talk bob: a subtle vertical bounce only while speaking.
	var talk_target: float = 1.0 if _talking else 0.0
	_talk_blend = lerpf(_talk_blend, talk_target, clampf(delta * 8.0, 0.0, 1.0))
	var bob: float = sin(_t * 9.0) * 0.03 * _talk_blend

	# Gaze glance scheduler: rest ahead, then flick up-left and back.
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
	_model.rotation = _base_rot + Vector3(
		GLANCE_PITCH_UP * _glance_blend,
		GLANCE_YAW_LEFT * _glance_blend,
		0.0)

	# Keep the hat riding the head: same pivot (feet), same glance/bob transform as the model holder.
	if _hat != null:
		_hat.position = _model.position
		_hat.rotation = _model.rotation
