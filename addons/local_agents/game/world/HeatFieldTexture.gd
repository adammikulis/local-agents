class_name LAHeatFieldTexture
extends Node

## Terrain-glow instrument: the field's per-cell temperature °C uploaded as an R-float 3D texture over
## the field box, and the terrain shader pointed at it. Reads the field's public climate snapshot and
## writes shader uniforms only.

const UPDATE_EVERY: int = 3        # render frames between uploads

var _field = null
var _terrain = null
var _tex: ImageTexture3D = null
var _slices: Array[Image] = []
var _nx: int = 0
var _ny: int = 0
var _nz: int = 0
var _tick: int = 0


func setup(field, terrain) -> void:
	if field == null or terrain == null or not terrain.has_method("set_shader_param"):
		return
	var grid: LAVoxelGrid = field._grid
	if grid == null or grid.cell_count <= 0:
		return
	_field = field
	_terrain = terrain
	_nx = grid.nx
	_ny = grid.ny
	_nz = grid.nz
	_slices = []
	for z in _nz:
		_slices.append(Image.create(_nx, _ny, false, Image.FORMAT_RF))
	_tex = ImageTexture3D.new()
	_tex.create(Image.FORMAT_RF, _nx, _ny, _nz, false, _slices)
	terrain.set_shader_param("heat_tex", _tex)
	terrain.set_shader_param("heat_box_min", grid.origin)
	terrain.set_shader_param("heat_box_size", Vector3(float(_nx), float(_ny), float(_nz)) * grid.cell_size)


func _process(_delta: float) -> void:
	if _tex == null:
		return
	_tick += 1
	if _tick < UPDATE_EVERY:
		return
	_tick = 0
	var snap: Dictionary = _field.climate_snapshot()
	if snap.is_empty():
		return
	var temp: PackedFloat32Array = snap["temp"]
	if temp.size() != _nx * _ny * _nz:
		return
	# Grid index is x + nx * (y + ny * z), so slice z is one row-major nx*ny image.
	var bytes: PackedByteArray = temp.to_byte_array()
	var stride: int = _nx * _ny * 4
	for z in _nz:
		_slices[z].set_data(_nx, _ny, false, Image.FORMAT_RF, bytes.slice(z * stride, (z + 1) * stride))
	_tex.update(_slices)
