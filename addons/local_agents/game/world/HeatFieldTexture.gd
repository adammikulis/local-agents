class_name LAHeatFieldTexture
extends Node

## The terrain shader's window onto the field: per-cell temperature °C, water, and the share of it that
## is frozen, each uploaded as an R-float 3D texture over the field box. Reads the field's public climate
## snapshot and writes shader uniforms only. The mirrors go up as they lie in memory — no per-cell walk.

const UPDATE_EVERY: int = 3        # render frames between uploads
## The snapshot key each texture carries, and the shader uniform it lands on.
const CHANNELS: Dictionary = {"temp": "heat_tex", "h2o": "h2o_tex", "h2o_solid": "h2o_solid_tex"}

var _field = null
var _terrain = null
var _tex: Dictionary = {}          # snapshot key -> ImageTexture3D
var _slices: Dictionary = {}       # snapshot key -> Array[Image]
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
	for key in CHANNELS:
		var slices: Array[Image] = []
		for z in _nz:
			slices.append(Image.create(_nx, _ny, false, Image.FORMAT_RF))
		var tex: ImageTexture3D = ImageTexture3D.new()
		tex.create(Image.FORMAT_RF, _nx, _ny, _nz, false, slices)
		_slices[key] = slices
		_tex[key] = tex
		terrain.set_shader_param(String(CHANNELS[key]), tex)
	terrain.set_shader_param("heat_box_min", grid.origin)
	terrain.set_shader_param("heat_box_size", Vector3(float(_nx), float(_ny), float(_nz)) * grid.cell_size)
	terrain.set_shader_param("snow_present", LAMaterialField3D.SNOW_PRESENT)
	terrain.set_shader_param("ice_depth", LAMaterialField3D.ICE_DEPTH)


func _process(_delta: float) -> void:
	if _tex.is_empty():
		return
	_tick += 1
	if _tick < UPDATE_EVERY:
		return
	_tick = 0
	var snap: Dictionary = _field.climate_snapshot()
	if snap.is_empty():
		return
	for key in CHANNELS:
		_upload(String(key), snap.get(key, PackedFloat32Array()))


## One mirror to one 3D texture. Grid index is x + nx * (y + ny * z), so slice z is one row-major
## nx*ny image and the whole upload is a byte-range copy.
func _upload(key: String, values: PackedFloat32Array) -> void:
	if values.size() != _nx * _ny * _nz:
		return
	var slices: Array[Image] = _slices[key]
	var bytes: PackedByteArray = values.to_byte_array()
	var stride: int = _nx * _ny * 4
	for z in _nz:
		slices[z].set_data(_nx, _ny, false, Image.FORMAT_RF, bytes.slice(z * stride, (z + 1) * stride))
	_tex[key].update(slices)
