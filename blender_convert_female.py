# Headless Blender: convert the Kenney female character (FBX mesh) + its separate idle-animation FBX
# into one clean, upright, textured, animated .glb that Godot renders reliably.
# Run: /Applications/Blender.app/Contents/MacOS/Blender --background --python blender_convert_female.py
import bpy, os

ROOT = "/Users/adammikulis/Documents/repos/godot/local-agents-female2/addons/local_agents/assets/models/people/"
SRC = ROOT + "female_src/"
OUT = ROOT + "character_female.glb"
SKIN = SRC + "casualFemaleB.png"

# Empty scene.
bpy.ops.wm.read_factory_settings(use_empty=True)

# --- import the character mesh (mesh + armature, bind pose) ---
bpy.ops.import_scene.fbx(filepath=SRC + "characterLargeFemale.fbx")
char_objs = list(bpy.context.selected_objects)
char_arm = next((o for o in char_objs if o.type == "ARMATURE"), None)
char_mesh = next((o for o in char_objs if o.type == "MESH"), None)
print("CHAR arm=%s mesh=%s" % (char_arm, char_mesh))

# --- import the idle animation (same rig, carries the action) ---
bpy.ops.import_scene.fbx(filepath=SRC + "idle.fbx")
idle_objs = list(bpy.context.selected_objects)
idle_arm = next((o for o in idle_objs if o.type == "ARMATURE"), None)

# idle.fbx ships TWO actions ("...|0_Targeting Pose" and "...|Idle"); pick the real Idle, not the aim
# pose (the active action after import is often the targeting pose, which raises the arms).
action = None
for a in bpy.data.actions:
    nm = a.name.lower()
    if "idle" in nm and "target" not in nm:
        action = a
        break
if action is None and idle_arm and idle_arm.animation_data:
    action = idle_arm.animation_data.action
if action and idle_arm:
    if not idle_arm.animation_data:
        idle_arm.animation_data_create()
    idle_arm.animation_data.action = action
    action.name = "Idle"
print("IDLE action=%s arm=%s all=%s" % (action, idle_arm, [a.name for a in bpy.data.actions]))

# Re-bind the mesh to the IDLE armature rather than cross-assigning the action (which breaks when the
# two armatures' rest poses differ). The mesh's vertex groups are bone names shared by both rigs, so it
# deforms correctly under the idle skeleton — which already owns a consistent rest pose + Idle action.
if char_mesh and idle_arm:
    for m in char_mesh.modifiers:
        if m.type == "ARMATURE":
            m.object = idle_arm
    mworld = char_mesh.matrix_world.copy()
    char_mesh.parent = idle_arm
    char_mesh.matrix_world = mworld

# Drop the character's now-unused armature; keep idle_arm (animated) + the mesh.
if char_arm:
    bpy.data.objects.remove(char_arm, do_unlink=True)
char_arm = idle_arm

# --- paint the Kenney female skin onto the mesh material ---
if char_mesh and os.path.exists(SKIN):
    img = bpy.data.images.load(SKIN)
    mat = bpy.data.materials.new("FemaleSkin")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    tex.interpolation = "Closest"
    if bsdf is not None:
        nt.links.new(bsdf.inputs["Base Color"], tex.outputs["Color"])
    char_mesh.data.materials.clear()
    char_mesh.data.materials.append(mat)

# --- export selection to glb (Y-up so Godot gets it upright) ---
bpy.ops.object.select_all(action="DESELECT")
if char_arm:
    char_arm.select_set(True)
if char_mesh:
    char_mesh.select_set(True)

bpy.ops.export_scene.gltf(
    filepath=OUT,
    export_format="GLB",
    use_selection=True,
    export_animations=True,
    export_yup=True,
    export_apply=True,
)
print("BLENDER_CONVERT_DONE ->", OUT)
