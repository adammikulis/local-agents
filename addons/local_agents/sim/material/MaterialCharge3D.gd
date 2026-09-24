class_name LAMaterialCharge3D
extends RefCounted

## A DETECTOR. flux.glsl marches the column once for its own conductivity and publishes the field,
## the threshold comparison and the strike; nothing here re-derives any of it.

var _f = null
var _bolts: int = 0                                      # flashes since the run began


func setup(field) -> void:
	_f = field


## Run once per step after the readback. Reads only; it must never write the field or wake a channel.
func post_step() -> void:
	var struck: int = _f._queries.row_n("bolt_cells")
	if struck <= 0:
		return
	_bolts += struck
	if _f.struck.get_connections().is_empty():
		return
	for c in _f._gpu.list_indices("strike"):
		_f.struck.emit(_f.cell_world_pos_linear(int(c)))


func bolts_fired() -> int:
	return _bolts
