class_name LAActorModels
extends RefCounted


const _BASE: String = "res://addons/local_agents/assets/models/"

const TABLE: Dictionary = {
	"fox": {
		"path": _BASE + "fauna/fox.glb",
		"anims": {"idle": "Idle", "move": "Walk", "run": "Gallop"}, "run": 2.2,
	},
	"fish": {
		"path": _BASE + "fauna/fish.glb",
		"anims": {"idle": "Swim", "move": "Swim", "run": "Swim"}, "run": 999.0,
	},
	"villager": {
		"path": _BASE + "people/villager.glb",
		"anims": {"idle": "Idle", "move": "Walk", "run": "Run"}, "run": 3.0,
	},
	# The corner streamer/commentator avatar. Rigged Quaternius humanoid; "talk" is the clip the
	# portrait loops while speaking (Idle here, layered with a procedural bob in StreamerAvatar). Swap
	# `path` for a dedicated character asset and this is the only line that changes.
	"streamer": {
		"path": _BASE + "people/villager.glb",
		"anims": {"idle": "Idle", "move": "Walk", "run": "Run", "talk": "Idle"}, "run": 3.0,
	},
	"rabbit": {"path": _BASE + "fauna/rabbit.glb"},
	# bird.glb exports facing +Z (unlike the other Cube Pets), so it flew tail-first; yaw 180 turns it
	# to face its heading like everything else.
	"bird": {"path": _BASE + "fauna/bird.glb", "yaw": 180.0},
	# Vulture reuses the parrot mesh, flattened to a dark scavenger tint (config, not a new asset).
	"vulture": {"path": _BASE + "fauna/vulture.glb", "tint": [0.30, 0.26, 0.23]},

	"plant": {"path": _BASE + "nature/plant_bushDetailed.glb", "tint": [0.31, 0.55, 0.21]},
	"tree_oak": {
		"path": _BASE + "nature/tree_oak.glb",
		"recolor": {"leafs": [0.21, 0.46, 0.17], "grass": [0.21, 0.46, 0.17],
			"wood": [0.34, 0.23, 0.14], "bark": [0.34, 0.23, 0.14]},
	},
	"tree_pine": {
		"path": _BASE + "nature/tree_pineTallA.glb",
		"recolor": {"leafs": [0.13, 0.34, 0.16], "grass": [0.13, 0.34, 0.16],
			"wood": [0.30, 0.21, 0.13], "bark": [0.30, 0.21, 0.13]},
	},
}


static func recolor(id: String) -> Dictionary:
	return get_def(id).get("recolor", {})


static func get_def(id: String) -> Dictionary:
	return TABLE.get(id, {})


static func path(id: String) -> String:
	return String(get_def(id).get("path", ""))


## Optional flat tint as a Color (transparent = "no tint, keep the model's own materials").
static func tint(id: String) -> Color:
	var arr = get_def(id).get("tint", null)
	if arr is Array and arr.size() >= 3:
		return Color(float(arr[0]), float(arr[1]), float(arr[2]), 1.0)
	return Color(0, 0, 0, 0)
