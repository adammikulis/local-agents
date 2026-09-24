@tool
class_name LAMeteorImpactView
extends LAEventView

## A rock from space striking the ground: the flash of the strike and its sound, and a hiss where water was.

@export_group("Sound")
## Played where the rock strikes.
@export var impact_sfx: String = "meteor_impact"
## Played where the rock strikes standing water, each once.
@export var water_sfx: PackedStringArray = PackedStringArray(["sizzle", "steam"])


## `observation` carries "pos", where the rock struck, and "into_water", whether it struck standing water.
func show_event(observation: Dictionary) -> void:
	var point: Vector3 = observation["pos"]
	if stand_at(point) == Vector3.ZERO:
		finish()
		return
	var tree: SceneTree = get_tree()
	LAAudioDirector.emit(tree, impact_sfx, point)
	if bool(observation["into_water"]):
		for key: String in water_sfx:
			LAAudioDirector.emit(tree, key, point)


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = super()
	if impact_sfx.is_empty():
		out.append("Impact Sfx is empty: the rock strikes in silence.")
	if lifetime_s <= 0.0:
		out.append("Lifetime S must be above 0: the flash fades over it before the view is freed.")
	return out
