@tool
class_name LAEruptionView
extends LAEventView

## Melt standing in the open, drawn as the glow it throws over the cells around it.

@export_group("Glow")
## Reach of the glow, in edges of the cell the melt was seen in.
@export var reach_cells: float = 5.0


## `observation` carries "pos" and "cell_m", the edge of the cell the detector named.
func show_event(observation: Dictionary) -> void:
	if stand_at(observation["pos"]) == Vector3.ZERO:
		finish()
		return
	light.omni_range = reach_cells * float(observation["cell_m"])


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = super()
	if reach_cells <= 0.0:
		out.append("Reach Cells must be above 0: the glow would light nothing.")
	return out
