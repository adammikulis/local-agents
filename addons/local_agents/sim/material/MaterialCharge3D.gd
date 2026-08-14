class_name LAMaterialCharge3D
extends RefCounted

## A DETECTOR. transport.glsl marches the column once for its own conductivity and publishes the field,
## the threshold comparison and the strike; nothing here re-derives any of it.

var _f = null
var _visual: Callable = Callable()
var _bolts: int = 0                                      # flashes since the run began


func setup(field) -> void:
	_f = field


func set_visual(cb: Callable) -> void:
	_visual = cb


## Run once per step after the readback. Reads only; it must never write the field or wake a channel.
func post_step() -> void:
	var struck: int = _f._queries.row_n("bolt_cells")
	if struck <= 0:
		return
	_bolts += struck
	if not _visual.is_valid():
		return
	for c in _f._gpu.list_indices("strike"):
		_visual.call(_f.cell_world_pos_linear(int(c)))


func bolts_fired() -> int:
	return _bolts
