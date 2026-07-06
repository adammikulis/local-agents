class_name LAMaterialHeatTexture3D
extends RefCounted

## LAMaterialHeatTexture3D — the terrain-glow heat texture of the dense 3D MaterialField3D, factored out
## so the field node stays under the file-size gate. It projects the HOTTEST cell in each XZ column into
## an R-float texture (dim_x × dim_z) the terrain shader samples for incandescent glow — so a lava tube,
## a buried hot cell, or a spreading fire still lights the ground above it. Same interface the 2.5D field
## exposed (heat_texture / heat_world_min / heat_world_size). Holds its own Image/Texture (render-support
## state, not simulation state) and reaches into the owning LAMaterialField3D (`_f`) for the shared temp
## array + geometry, exactly as the query/render/inject modules do.
## (Explicit types only — no ':=' inferred typing.)

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _img: Image = null
var _tex: ImageTexture = null
var _col: PackedFloat32Array = PackedFloat32Array()


func setup(field) -> void:
	_f = field


## Allocate the R-float texture (idempotent). Called early in the field's setup() so consumers can wire
## heat_texture() immediately, even while the field is still lazily sampling solidity.
func build() -> void:
	if _tex != null:
		return
	_col = PackedFloat32Array()
	_col.resize(_f._dim_x * _f._dim_z)
	_col.fill(_f.INITIAL_TEMP)
	_img = Image.create_from_data(_f._dim_x, _f._dim_z, false, Image.FORMAT_RF, _col.to_byte_array())
	_tex = ImageTexture.create_from_image(_img)


## Project the hottest cell in each column into the R-float texture the terrain shader reads.
func update() -> void:
	if _tex == null:
		return
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var temp: PackedFloat32Array = _f._temp
	for iz in range(dz):
		for ix in range(dx):
			var hottest: float = -1000.0
			var base: int = iz * dx + ix
			for iy in range(_f._dim_y):
				var t: float = temp[iy * layer + base]
				if t > hottest:
					hottest = t
			_col[base] = hottest
	_img.set_data(dx, dz, false, Image.FORMAT_RF, _col.to_byte_array())
	_tex.update(_img)


## The live terrain-glow texture (R = hottest °C per column). Wire once into the terrain shader.
func texture() -> Texture2D:
	return _tex


func world_min() -> Vector2:
	return Vector2(-_f._half_extent, -_f._half_extent)


func world_size() -> Vector2:
	return Vector2(2.0 * _f._half_extent, 2.0 * _f._half_extent)
