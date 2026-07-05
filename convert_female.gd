extends SceneTree

## One-off asset build: convert the Kenney female character (FBX mesh) + its shared-skeleton Idle
## animation into a single clean, upright .glb using Godot's own GLTFDocument exporter. Godot's runtime
## renders skinned .glb reliably (skinned .fbx via ufbx did NOT show in a SubViewport), so we convert
## once at author time and ship the .glb. Run: godot --headless --path . --script res://convert_female.gd

const SRC: String = "res://addons/local_agents/assets/models/people/female_src/"
const OUT: String = "res://addons/local_agents/assets/models/people/character_female.glb"

func _initialize() -> void:
	var mesh_scene: PackedScene = load(SRC + "characterLargeFemale.fbx")
	var anim_scene: PackedScene = load(SRC + "idle.fbx")
	if mesh_scene == null or anim_scene == null:
		print("CONVERT_FAIL missing source")
		quit()
		return

	var root: Node3D = mesh_scene.instantiate()

	# NOTE: the FBX's lying-down look is baked into the skeleton rest during glTF export, so the
	# exported mesh is already upright in local space — do NOT add a rotation here (that tips it over).

	# Pull the "Root|Idle" clip off idle.fbx (same 58-bone rig) and embed it as "Idle".
	var anim_inst: Node = anim_scene.instantiate()
	var src_ap: AnimationPlayer = _find_anim(anim_inst)
	if src_ap != null and src_ap.has_animation("Root|Idle"):
		var clip: Animation = src_ap.get_animation("Root|Idle")
		var ap: AnimationPlayer = AnimationPlayer.new()
		ap.name = "AnimationPlayer"
		var lib: AnimationLibrary = AnimationLibrary.new()
		lib.add_animation("Idle", clip)
		ap.add_animation_library("", lib)
		root.add_child(ap)
	else:
		print("CONVERT_WARN no Root|Idle animation found")

	var doc: GLTFDocument = GLTFDocument.new()
	var state: GLTFState = GLTFState.new()
	var err: int = doc.append_from_scene(root, state)
	if err != OK:
		print("CONVERT_FAIL append err=", err)
		quit()
		return
	err = doc.write_to_filesystem(state, OUT)
	print("CONVERT_DONE err=%d -> %s" % [err, OUT])
	quit()

func _find_anim(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for c in node.get_children():
		var f: AnimationPlayer = _find_anim(c)
		if f != null:
			return f
	return null
