@tool
class_name LACycloneView
extends LAEventView

## A closed low drawn as a ring of cloud spiralling in about the local vertical, clear at its eye.

@export_group("Ring")
## Height of the ring above the low, in edges of the cell the low was named in.
@export var aloft_cells: float = 6.0


## `observation` carries "pos" and "cell_m", the edge of the cell the detector named. The ring's
## particles are authored in cell edges, so the system is scaled by that edge.
func show_event(observation: Dictionary) -> void:
	var cell_m: float = float(observation["cell_m"])
	if not (cell_m > 0.0) or stand_at(observation["pos"]) == Vector3.ZERO:
		finish()
		return
	particles.scale = Vector3.ONE * cell_m
	particles.position = Vector3(0.0, aloft_cells * cell_m, 0.0)


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = super()
	var particles_node: GPUParticles3D = get_node_or_null("Particles") as GPUParticles3D
	if particles_node != null and not particles_node.local_coords:
		out.append("Particles must use Local Coords: the ring is authored in cell edges and scaled by one.")
	return out
